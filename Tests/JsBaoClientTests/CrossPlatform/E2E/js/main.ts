#!/usr/bin/env vite-node
// JS mini-app CLI for the cross-language E2E parity harness.
// Mirrors `../swift/main.swift`; both speak the same JSON-on-stdin /
// JSON-on-stdout protocol. The XCTest driver
// (E2EQueryParityTests.swift) spawns one of each and asserts that
// the same TOML produces the same query results across the
// language boundary.
//
// Both sides now consume the SAME `schema.toml` through codegen:
//
//   Swift: `swift-bao-codegen` (build-time, via the SwiftPM plugin
//          attached to `E2EMiniApp`) emits one struct per model.
//   JS:    `js-bao-codegen-v2` (run by `codegen.mjs` before this CLI
//          starts) emits `<ClassName>.generated.ts` per model + an
//          `index.ts` barrel that auto-registers every class with
//          js-bao via `attachAndRegisterModel`.
//
// We run under `vite-node` (not plain `node`) because v2's barrel
// uses Vite's `?raw` import to inline `schema.toml` into the bundle.
// That same shape is what real Primitive apps use (sample-app,
// test-app), so this CLI exercises the production import path
// rather than a Node-only shim.
//
// Commands (one JSON object per stdin line):
//
//   {"cmd":"seed","records":[{...}, ...]}
//     → {"doc":"<base64 Y.Doc update bytes>"}
//
//   {"cmd":"query","doc":"<base64>","filter":{...},
//                  "sort":[{"field":"priority","dir":-1}, ...],
//                  "limit":10,"cursor":"..."}
//     → {"results":[{...}, ...]}
//
//   {"cmd":"find","doc":"<base64>","id":"..."}
//     → {"record":{...}|null}
//
//   {"cmd":"inspect","doc":"<base64>","id":"..."}
//     → {"fields":{...}}
//
//   {"cmd":"resolveRelationship","doc":"<base64>","id":"...",
//                                  "relationship":"posts"}
//     → {"results":[...]}

import * as readline from "node:readline";
import * as Y from "yjs";
import {
  type BaseModel as BaseModelType,
  registerFunctionDefault,
  generateULID,
  initJsBao,
} from "js-bao";

// Importing the barrel side-effect-registers every model with js-bao
// via `attachAndRegisterModel`. By the time this import resolves,
// `TaskRecord.query(...)`, `inst.tags.add(...)`, etc. are all wired
// up. No runtime `loadSchemaFromTomlString` call is needed here —
// the barrel does it once for us, with the same TOML the Swift
// codegen consumes.
//
// We import `allModels` (the barrel's exported convenience array) and
// walk it once to build a model-name → class lookup. Each class
// carries `.modelName` (set by `attachSchemaToClass`) tying it back
// to the TOML key, so we don't need to import each `*_modelName`
// constant individually.
import { allModels, TaskRecord } from "./generated";

registerFunctionDefault(generateULID, "generate_ulid");

// ── Schema setup ────────────────────────────────────────────────────

const CLASS_BY_MODEL_NAME: Record<string, typeof BaseModelType> = {};
for (const cls of allModels) {
  const name = (cls as any).modelName;
  if (typeof name !== "string" || !name) {
    process.stderr.write(
      `E2EMiniApp(js): generated class ${(cls as any).name ?? "<anon>"} ` +
      "has no .modelName — barrel registration didn't run?\n"
    );
    process.exit(1);
  }
  CLASS_BY_MODEL_NAME[name] = cls;
}

const MODELS = CLASS_BY_MODEL_NAME;

// `attachAndRegisterModel` (run by the barrel) sets `class.schema`
// to the parsed `DefinedModelSchema`. We read the field/relationship
// metadata back off the class for the introspective JSON walks
// below — same metadata Swift's generated `primitiveSchema` carries.
function schemaFor(modelName: string): any {
  const cls = CLASS_BY_MODEL_NAME[modelName];
  if (!cls) {
    emitError("unknown model: " + modelName);
    throw new Error("unreachable");
  }
  // `(cls as any).schema` is the DefinedModelSchema attached by
  // `attachAndRegisterModel`. We type as `any` because the schema
  // shape isn't part of the public class type — we're treating
  // every codegen'd class uniformly here.
  return (cls as any).schema;
}

// Sanity: every relationship-bearing model must be wired so the
// barrel's registration loop reached it. If the barrel was generated
// from a stale TOML, the import-time check inside the barrel itself
// throws; this guard catches the symmetric case (the TOML lacks a
// model the harness depends on).
for (const name of ["tasks", "everything", "users", "posts", "tags", "post_tag_links"]) {
  if (!CLASS_BY_MODEL_NAME[name] || !schemaFor(name)) {
    emitError(
      "E2EMiniApp(js): missing schema for '" + name +
      "'. Re-run `js-bao-codegen-v2` against schema.toml."
    );
  }
}

// ── js-bao runtime init ─────────────────────────────────────────────
//
// js-bao's BaseModel needs a registered DatabaseEngine + a connected
// Y.Doc before any CRUD/query call. We init lazily because each CLI
// command brings its own doc bytes.

let jsBao: any = null;
let docCounter = 0;

async function ensureInit(): Promise<void> {
  if (jsBao) return;
  jsBao = await initJsBao({
    databaseConfig: { type: "node-sqlite", options: {} },
    models: Object.values(MODELS),
  } as any);
}

/**
 * Connect a brand-new doc id for each command — keeps state isolated
 * between commands so the same CLI can be reused across many
 * (seed → bytes → query) cycles without leaking the prior doc's
 * SQLite mirror.
 */
async function withFreshDoc<T>(
  docB64: string | null,
  fn: (doc: Y.Doc, docId: string) => Promise<T>
): Promise<T> {
  await ensureInit();
  const doc = decodeDoc(docB64);
  const docId = `e2e-${docCounter++}`;
  await jsBao.connectDocument(docId, doc, "read-write");
  jsBao.setDefaultDocumentId(docId);
  try {
    return await fn(doc, docId);
  } finally {
    await jsBao.disconnectDocument(docId);
  }
}

// ── Helpers ─────────────────────────────────────────────────────────

/** Decode base64 Y.Doc update bytes into a fresh `Y.Doc`. */
function decodeDoc(b64: string | null): Y.Doc {
  const doc = new Y.Doc();
  if (b64) {
    Y.applyUpdate(doc, Buffer.from(b64, "base64"));
  }
  return doc;
}

/** Serialize a `Y.Doc` to base64 update bytes. */
function encodeDoc(doc: Y.Doc): string {
  return Buffer.from(Y.encodeStateAsUpdate(doc)).toString("base64");
}

/**
 * Schema-agnostic instance → JSON serializer. Walks the model's
 * declared fields in order, reads each via the BaseModel
 * accessor, normalizes stringsets to sorted arrays.
 *
 * **Stringset workaround:** js-bao's BaseModel-level stringset
 * reader (`getStringSetFromYjs`) calls `Object.keys()` on the Yjs
 * value, which returns Y.Map class internals (`_item`, `_map`, …)
 * rather than the map's keys when the doc was written by another
 * client. We bypass the wrapper and read the nested Y.Map keys
 * directly — same pattern as `reader.cjs`. Switching to v2 codegen
 * doesn't fix this — the bug is in BaseModel runtime, and the
 * codegen-emitted class is just a shell over BaseModelImpl.
 * Tracked as issue #561.
 */
function instanceToJson(inst: any, doc: Y.Doc, schemaName: string): any {
  const schema = schemaFor(schemaName);
  const fields = schema.options?.fields || schema.fields;
  const out: Record<string, any> = { id: inst.id };
  // js-bao's `DefinedModelSchema.fields` is a Map<name, FieldOptions>.
  const entries =
    fields instanceof Map
      ? Array.from(fields.entries())
      : Object.entries(fields);
  for (const [fname, fopts] of entries as Array<[string, any]>) {
    if (fname === "id") continue;
    if (fopts.type === "stringset") {
      const members = readStringsetRaw(doc, schemaName, inst.id, fname);
      if (members !== null) out[fname] = members;
    } else {
      const v = (inst as any)[fname];
      if (v !== undefined && v !== null) out[fname] = v;
    }
  }
  return out;
}

/**
 * Extract a stringset's members directly from the underlying
 * Y.Map, bypassing js-bao's StringSet wrapper. Returns a sorted
 * array of members, or `null` if the field's nested map is absent.
 *
 * See the docblock on `instanceToJson` for why this exists.
 */
function readStringsetRaw(
  doc: Y.Doc,
  modelName: string,
  recordId: string,
  fieldName: string
): string[] | null {
  const modelMap = doc.getMap(modelName);
  const rec = modelMap.get(recordId);
  if (!(rec instanceof Y.Map)) return null;
  const inner = rec.get(fieldName);
  if (inner instanceof Y.Map) {
    return Array.from(inner.keys()).sort();
  }
  // js-bao stores stringsets as a plain object (`{member: true,…}`)
  // — different wire format from Swift's nested Y.Map. See the
  // `_KNOWN_DIVERGENCE` test in E2EQueryParityTests.swift.
  if (inner && typeof inner === "object" && !Array.isArray(inner)) {
    return Object.keys(inner as Record<string, unknown>).sort();
  }
  return null;
}

/** Translate the wire-protocol sort array into the BaseModel sort dict. */
function parseSort(arr: any): Record<string, number> | undefined {
  if (!arr) return undefined;
  const out: Record<string, number> = {};
  for (const entry of arr) {
    if (entry.field && typeof entry.dir === "number") out[entry.field] = entry.dir;
  }
  return out;
}

function stringsetFieldsForSchema(modelName: string): string[] {
  const schemaFields = schemaFor(modelName).fields;
  const entries =
    schemaFields instanceof Map
      ? Array.from(schemaFields.entries())
      : Object.entries(schemaFields);
  return (entries as Array<[string, any]>)
    .filter(([, fopts]) => fopts.type === "stringset")
    .map(([f]) => f);
}

// ── Commands ────────────────────────────────────────────────────────

/**
 * Seed records into a doc. If `existingDoc` is provided, the new
 * records are appended to its existing state — letting callers
 * build a doc up across multiple CLI invocations (Swift seeds A,
 * JS adds B, etc.) to exercise CRDT merge semantics.
 */
async function cmdSeed(
  records: any[],
  existingDocB64: string | null,
  modelName: string
): Promise<void> {
  const ModelCls = (MODELS[modelName] || TaskRecord) as any;
  const out = await withFreshDoc(existingDocB64, async (doc) => {
    for (const r of records) {
      // StringSet fields can't be passed via the constructor —
      // js-bao throws "Cannot directly assign to StringSet field".
      // Pull them out, set scalars via the constructor, then
      // `inst.<field>.add(...)` for each member.
      const stringsetFields = stringsetFieldsForSchema(modelName);
      const stringsetValues: Record<string, string[]> = {};
      for (const sf of stringsetFields) {
        if (Array.isArray(r[sf])) {
          stringsetValues[sf] = r[sf];
        }
      }
      const fields: Record<string, any> = { ...r };
      for (const sf of stringsetFields) delete fields[sf];
      delete fields.id;
      const inst = new ModelCls({ id: r.id, ...fields });
      for (const [sf, members] of Object.entries(stringsetValues)) {
        for (const m of members) inst[sf].add(m);
      }
      await inst.save();
    }
    return encodeDoc(doc);
  });
  emit({ doc: out });
}

async function cmdQuery(
  docB64: string,
  filter: any,
  sort: any,
  limit: any,
  cursor: any,
  modelName: string
): Promise<void> {
  const ModelCls = (MODELS[modelName] || TaskRecord) as any;
  const out = await withFreshDoc(docB64, async (doc) => {
    const opts: Record<string, any> = {};
    const sortDict = parseSort(sort);
    if (sortDict) opts.sort = sortDict;
    if (typeof limit === "number") opts.limit = limit;
    // js-bao calls the cursor `uniqueStartKey`. Same opaque-string
    // contract as Swift's `cursor` field — translate the wire name.
    if (typeof cursor === "string") opts.uniqueStartKey = cursor;
    const result = await ModelCls.query(filter || {}, opts);
    const rows = result.data || [];
    return {
      results: rows.map((t: any) => instanceToJson(t, doc, modelName)),
      nextCursor: result.nextCursor,
    };
  });
  const payload: Record<string, any> = { results: out.results };
  if (out.nextCursor != null) payload.nextCursor = out.nextCursor;
  emit(payload);
}

async function cmdFind(
  docB64: string,
  id: string,
  modelName: string
): Promise<void> {
  const ModelCls = (MODELS[modelName] || TaskRecord) as any;
  const out = await withFreshDoc(docB64, async (doc) => {
    const t = await ModelCls.find(id);
    return t ? instanceToJson(t, doc, modelName) : null;
  });
  emit({ record: out });
}

/**
 * Resolve a relationship by name on the given record. Routes to the
 * auto-attached BaseModel relationship method (e.g. `inst.posts()`
 * for a hasMany named `posts`) and normalizes the result into the
 * harness's `{results: [...]}` shape regardless of whether the
 * relationship returned a single record (refersTo) or an array
 * (hasMany / hasManyThrough / refersToMany).
 *
 * Same protocol as the Swift mini-app's resolveRelationship — both
 * sides must produce identical JSON for the parity tests to be
 * meaningful.
 */
async function cmdResolveRelationship(
  docB64: string,
  modelName: string,
  id: string,
  relationship: string
): Promise<void> {
  const ModelCls = MODELS[modelName] as any;
  if (!ModelCls) emitError("unknown model: " + modelName);

  const sourceSchema = schemaFor(modelName);
  const relsRaw =
    sourceSchema.options?.relationships ?? sourceSchema.relationships;
  const relCfg = relsRaw && relsRaw[relationship];
  if (!relCfg) {
    emitError(
      "unknown relationship '" + relationship + "' on model '" + modelName + "'"
    );
  }
  const targetModelName = relCfg.model;

  const out = await withFreshDoc(docB64, async (doc) => {
    const inst = await ModelCls.find(id);
    if (!inst) return [];
    const accessor = inst[relationship];
    if (typeof accessor !== "function") {
      emitError(
        "relationship accessor '" + relationship +
        "' missing on model '" + modelName + "'"
      );
    }
    const raw = await accessor.call(inst);
    if (raw == null) return [];
    let list: any[];
    if (Array.isArray(raw)) {
      list = raw;
    } else if (raw && Array.isArray(raw.data)) {
      list = raw.data;
    } else {
      list = [raw];
    }
    return list.map((r: any) => instanceToJson(r, doc, targetModelName));
  });
  emit({ results: out });
}

/**
 * Inspect command — wire-byte equality dump. Returns the raw
 * value stored under each declared field of the record's nested
 * Y.Map. Stringset fields dump their nested map's sorted key list.
 * Cross-language byte-equality tests assert against this output.
 */
async function cmdInspect(
  docB64: string,
  id: string,
  modelName: string
): Promise<void> {
  const out = await withFreshDoc(docB64, async (doc) => {
    const modelMap = doc.getMap(modelName);
    const rec = modelMap.get(id);
    if (!(rec instanceof Y.Map)) return null;
    const fields: Record<string, any> = {};
    const schemaFields = schemaFor(modelName).fields;
    const entries =
      schemaFields instanceof Map
        ? Array.from(schemaFields.entries())
        : Object.entries(schemaFields);
    for (const [fname, fopts] of entries as Array<[string, any]>) {
      if (fopts.type === "stringset") {
        const members = readStringsetRaw(doc, modelName, id, fname);
        if (members !== null) fields[fname] = members;
      } else {
        const v = rec.get(fname);
        if (v !== undefined) fields[fname] = v;
      }
    }
    return fields;
  });
  emit({ fields: out });
}

// ── Stdio loop ──────────────────────────────────────────────────────

function emit(obj: any): void {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function emitError(msg: string): never {
  process.stderr.write("E2EMiniApp(js): " + msg + "\n");
  process.exit(1);
}

// Read stdin to completion FIRST, then run commands sequentially.
// `readline` emits `close` as soon as stdin EOFs, which can race
// async command handlers and exit the process before they finish.
// Buffering lines keeps the lifecycle deterministic.

async function main(): Promise<void> {
  const rl = readline.createInterface({ input: process.stdin, terminal: false });
  const lines: string[] = [];
  for await (const line of rl) {
    if (line.trim()) lines.push(line);
  }
  for (const line of lines) {
    let cmd: any;
    try {
      cmd = JSON.parse(line);
    } catch (e) {
      emitError("invalid JSON on stdin: " + line);
    }
    const modelName: string = cmd.model || "tasks";
    try {
      switch (cmd.cmd) {
        case "seed":
          await cmdSeed(cmd.records || [], cmd.doc || null, modelName);
          break;
        case "query":
          if (!cmd.doc) return emitError("query: missing doc");
          await cmdQuery(cmd.doc, cmd.filter, cmd.sort, cmd.limit, cmd.cursor, modelName);
          break;
        case "find":
          if (!cmd.doc || !cmd.id) return emitError("find: missing doc/id");
          await cmdFind(cmd.doc, cmd.id, modelName);
          break;
        case "inspect":
          if (!cmd.doc || !cmd.id) return emitError("inspect: missing doc/id");
          await cmdInspect(cmd.doc, cmd.id, modelName);
          break;
        case "resolveRelationship":
          if (!cmd.doc || !cmd.id || !cmd.relationship) {
            return emitError("resolveRelationship: missing doc/id/relationship");
          }
          await cmdResolveRelationship(
            cmd.doc, modelName, cmd.id, cmd.relationship
          );
          break;
        default:
          emitError("unknown cmd: " + cmd.cmd);
      }
    } catch (e: any) {
      emitError("error in cmd " + cmd.cmd + ": " + (e && e.stack ? e.stack : e));
    }
  }
}

main().then(
  () => process.exit(0),
  (e) => {
    emitError("fatal: " + (e && e.stack ? e.stack : e));
  }
);
