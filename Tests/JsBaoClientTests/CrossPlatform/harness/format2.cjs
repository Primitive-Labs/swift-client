#!/usr/bin/env node
// Format-2 (large document) parity harness for Swift↔TypeScript (#3436).
//
// Criterion 12 of the `large-documents` intent asks that the Swift overlay
// fold give the SAME rows as the TypeScript fold for the same overlay. The
// fold is the one thing in this design that must not drift: the Durable
// Object's authoritative table and every client's merged view are all folded
// by `overlaySql.ts`, and Swift is the third implementation of it. So the
// Swift side never asserts against a transcription of the expected rows — it
// asserts against what the real js-bao code, running here, actually produces.
//
// One JSON request on stdin, one JSON response on stdout:
//
//   {"command":"ddl","docId":"..."}
//     → { tables: {records, stringSetIndex}, statements: [...] }
//   {"command":"encode-mutation","mutation":{...}}
//     → { entries: [[key, value], ...] }
//   {"command":"parse-key","keys":["..."]}
//     → { parsed: [ {recordId, field?, member?, marker?} | null, ... ] }
//   {"command":"group","entries":[[key,value],...]}
//     → { entries: [ {id, fields, stringSets, replace, deleted}, ... ] }
//   {"command":"fold-script","docId":"...","steps":[...]}
//     → the whole store dumped, table by table (see `dumpStore`)
//   {"command":"write-overlay","docId":"...","mutations":[{model,mutation}]}
//     → { update: "<base64 Yjs update>" } — an overlay written by the REAL
//       js-bao encoder, for the Swift observer to fold
//   {"command":"fold-update","docId":"...","update":"<base64>"}
//     → the store dumped after folding that update through js-bao's own
//       observer path
//   {"command":"compare-ids","ids":["..."]}
//     → { sorted: [...] } using js-bao's `compareRecordIds`
//   {"command":"validate-manifest","manifests":[{...}]}
//     → { verdicts: [ {ok:true} | {ok:false, name, code, message}, ... ] }
//   {"command":"encode-chunk","chunks":[{key,path?,ordinal?,model,rows:[...]}]}
//     → { chunks: [ {entry, body:"<base64>"} ] } — bytes the REAL platform
//       encoder wrote, for the Swift chunk reader to verify and decode
//   {"command":"plan-cold-start","cases":[{held,reported,sealed,snapshot}]}
//     → { plans: [ {kind, base?, discontinuities?, reason?}, ... ] }
//   {"command":"classify-adopted","cases":[{overlay:{model:[[k,v]]},ops:[...]}]}
//     → { verdicts: [ [ {kind} | {kind:"fragment",restore,keep} , ... ], ... ] }
//   {"command":"carry","cases":[{overlay,ops,later?,suppressDeletes?}]}
//     → { results: [ {carried:[{model,entry}], written:{model:[[k,v]]}} ] }
//   {"command":"offline-window","cases":[{lastSyncAt?,windowDays?,now}],
//    "configured":[7,...]}
//     → { statuses: [ {writable,lastSyncAt,windowDays,windowMs,overdueMs} ],
//         configured: [ days, ... ] }
//   {"command":"plan-fast-forward","cases":[{current,target,sealed}]}
//     → { plans: [ {kind, reason?, from?, to?, steps?, discontinuities?,
//                   epoch?}, ... ] }
//   {"command":"resolve-offline-replay",
//    "cases":[{ops,epochs,sealTimes,noted,currentEpoch,now,
//              clockOffsetKnown?,ingest?}]}
//     → { plans: [ {ops,narrowed,suppressedDeletes,rebuildRequired,notices} ] }
//
// Requires `js-bao/node` and `better-sqlite3`, both resolved from the repo
// root (proven by this child's step-0b vehicle smoke). `encodeSnapshotChunk`
// is published on the Durable Object entry rather than the Node one — it is
// the BUILDER's half of the chunk format — so it is required from there; that
// entry loads under Node 22 (this child's phase-B vehicle smoke).

const Database = require("better-sqlite3");
const Y = require("yjs");
const {
  Format2RecordStore,
  format2ClientDDL,
  format2TableNames,
  encodeOverlayMutation,
  applyOverlayMutation,
  parseOverlayKey,
  groupOverlayEntries,
  completeOverlayEntries,
  projectOverlayEntry,
  compareRecordIds,
  format2EpochDocName,
  validateSnapshotManifest,
  planColdStart,
  offlineWindowStatus,
  configuredOfflineWindowDays,
  classifyAdoptedOp,
  createRestoreProjection,
  projectRestoredKeys,
  carryUnackedOverlay,
  writeCarriedOverlay,
  suppressSupersededKeys,
  planFastForward,
  OfflineConflictLedger,
  resolveOfflineReplay,
  offlineReplayRecordKey,
  planSnapshotHydration,
  estimateMaterializedBytes,
} = require("js-bao/node");
const { encodeSnapshotChunk } = require("js-bao/cloudflare/do");

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

/**
 * The `OverlaySql` shape `projectOverlayEntry` and `Format2RecordStore` want,
 * over a better-sqlite3 handle. `exec` returns an iterable of rows for a
 * SELECT and an empty array otherwise — which is exactly Cloudflare's
 * `SqlStorage.exec` contract as those modules use it.
 */
function sqlHost(db) {
  return {
    exec(query, ...bindings) {
      const statement = db.prepare(query);
      if (statement.reader) return statement.all(...bindings);
      statement.run(...bindings);
      return [];
    },
  };
}

function openStore(docId, clientId = "harness-client") {
  const db = new Database(":memory:");
  const sql = sqlHost(db);
  const store = new Format2RecordStore(sql, docId, clientId);
  store.init();
  return { db, sql, store };
}

/**
 * Every table of the store, in a deterministic order, so the Swift side can
 * compare them value for value and name the one that differs.
 */
function dumpStore(db, docId) {
  const tables = format2TableNames(docId);
  const all = (query, ...bindings) => db.prepare(query).all(...bindings);
  return {
    tables,
    records: all(
      `SELECT _type, _id, _data FROM ${tables.records} ORDER BY _type, _id`
    ),
    members: all(
      `SELECT _type, _record_id, field, value FROM ${tables.stringSetIndex} ` +
        `ORDER BY _type, _record_id, field, rowid`
    ),
    pending: all(
      "SELECT doc_id, client_id, seq, model, record_id, op, fields, base_epoch, mutation, prior_overlay " +
        "FROM _pending_ops ORDER BY doc_id, client_id, seq"
    ),
    clientAcks: all(
      "SELECT doc_id, client_id, acked_seq FROM _client_acks ORDER BY doc_id, client_id"
    ),
    epoch: all(
      "SELECT doc_id, epoch, acked_seq, last_sync_at, window_days, clock_offset, hydrated_models " +
        "FROM _epoch ORDER BY doc_id"
    ),
    snapshotLoad: all(
      "SELECT doc_id, build_id, ordinal FROM _snapshot_load ORDER BY doc_id, build_id, ordinal"
    ),
    snapshotBase: all(
      "SELECT doc_id, build_id, epoch, complete FROM _snapshot_base ORDER BY doc_id"
    ),
    schema: all(
      "SELECT name, type, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name"
    ),
  };
}

/**
 * Fold a set of overlay entries per model into the store's tables, the way
 * the client observer does: group the touched keys, complete any `_replace`
 * from the WHOLE model map, then project each entry.
 */
function foldEntries(sql, modelMap, modelName, touched, tables) {
  const grouped = groupOverlayEntries(touched);
  completeOverlayEntries(modelMap, grouped);
  for (const entry of grouped.values()) {
    projectOverlayEntry(sql, modelName, entry, tables);
  }
}

/**
 * Run a scripted sequence of overlay mutations against one store, folding
 * each step exactly as an arriving update would be folded. Models live in
 * their own top-level Y.Map, which is the shape the real client writes.
 */
function runFoldScript(docId, steps) {
  const { db, sql, store } = openStore(docId);
  const tables = format2TableNames(docId);
  const doc = new Y.Doc();

  for (const step of steps) {
    if (step.kind === "epoch") {
      store.setEpoch(step.epoch);
      continue;
    }
    if (step.kind === "ack") {
      store.prunePendingOps(step.clientId ?? "harness-client", step.seq);
      continue;
    }
    // A mutation: write it into the model map exactly as the client does,
    // capture the keys it touched, then fold those keys.
    const modelMap = doc.getMap(step.model);
    const touched = [];
    doc.transact(() => {
      applyOverlayMutation(modelMap, step.mutation);
    });
    for (const [key] of encodeOverlayMutation(step.mutation)) {
      touched.push([key, modelMap.get(key)]);
    }
    foldEntries(sql, modelMap, step.model, touched, tables);
  }

  const dump = dumpStore(db, docId);
  dump.epochDocName = format2EpochDocName(docId, 0);
  db.close();
  return dump;
}

/**
 * What the real validator says about one manifest.
 *
 * The VERDICT, not the exception: the Swift side compares "accepted, or
 * refused with this code and this sentence" case by case, and a harness that
 * threw would only ever report the first refusal in a fixture set.
 */
function validateVerdict(manifest) {
  try {
    validateSnapshotManifest(manifest);
    return { ok: true };
  } catch (error) {
    return {
      ok: false,
      name: error.name,
      code: error.code ?? null,
      message: error.message,
    };
  }
}

async function handle(request) {
  switch (request.command) {
    case "ddl": {
      // Both the statements AND what SQLite actually stored for them. The
      // stored form is the one worth comparing: `sqlite_master.sql` drops
      // `IF NOT EXISTS`, so a statement-to-stored comparison fails on every
      // object for a reason that has nothing to do with the schema.
      const { db, store } = openStore(request.docId);
      void store;
      const schema = db
        .prepare(
          "SELECT name, type, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        .all();
      db.close();
      return {
        tables: format2TableNames(request.docId),
        statements: format2ClientDDL(request.docId),
        schema,
      };
    }

    case "encode-mutation":
      return { entries: encodeOverlayMutation(request.mutation) };

    case "parse-key":
      return { parsed: request.keys.map((key) => parseOverlayKey(key)) };

    case "group": {
      const grouped = groupOverlayEntries(request.entries);
      return {
        entries: Array.from(grouped.values()).map((entry) => ({
          id: entry.id,
          fields: entry.fields,
          stringSets: entry.stringSets,
          replace: entry.replace,
          deleted: entry.deleted,
        })),
      };
    }

    case "fold-script":
      return runFoldScript(request.docId, request.steps);

    case "write-overlay": {
      const doc = new Y.Doc();
      doc.transact(() => {
        for (const { model, mutation } of request.mutations) {
          applyOverlayMutation(doc.getMap(model), mutation);
        }
      });
      return {
        update: Buffer.from(Y.encodeStateAsUpdate(doc)).toString("base64"),
      };
    }

    case "fold-update": {
      const { db, sql } = openStore(request.docId);
      const tables = format2TableNames(request.docId);
      const doc = new Y.Doc();
      // The keys the update touches are the keys it carries: apply it to an
      // EMPTY doc and read what landed, which is what an observer sees.
      Y.applyUpdate(doc, Buffer.from(request.update, "base64"));
      for (const model of request.models) {
        const modelMap = doc.getMap(model);
        const touched = Array.from(modelMap.entries());
        if (touched.length === 0) continue;
        foldEntries(sql, modelMap, model, touched, tables);
      }
      const dump = dumpStore(db, request.docId);
      db.close();
      return dump;
    }

    case "compare-ids":
      return { sorted: request.ids.slice().sort(compareRecordIds) };

    case "validate-manifest":
      return { verdicts: request.manifests.map(validateVerdict) };

    case "encode-chunk": {
      const chunks = [];
      for (const input of request.chunks) {
        const encoded = await encodeSnapshotChunk({
          key: input.key,
          ...(input.path !== undefined ? { path: input.path } : {}),
          ...(input.ordinal !== undefined ? { ordinal: input.ordinal } : {}),
          model: input.model,
          rows: input.rows.map((row) => ({
            _type: input.model,
            _id: row.id,
            _data: row.data,
          })),
        });
        chunks.push({
          entry: encoded.entry,
          body: Buffer.from(encoded.body).toString("base64"),
        });
      }
      return { chunks };
    }

    // The window boundary and its clamp, straight off js-bao's own
    // `format2OfflineWindow` (#3437, behavior 1). A window is a number two
    // clients have to agree about to the millisecond: one that goes read-only
    // early refuses writes it could have replayed, one that goes read-only
    // late accepts writes the server cannot place.
    case "offline-window":
      return {
        statuses: (request.cases ?? []).map((each) => {
          const status = offlineWindowStatus({
            lastSyncAt: each.lastSyncAt ?? null,
            windowDays: each.windowDays ?? null,
            now: each.now,
          });
          return { ...status };
        }),
        configured: (request.configured ?? []).map((raw) =>
          configuredOfflineWindowDays(raw)
        ),
      };

    // The adoption classification, straight off js-bao's own
    // `format2PendingRestore` (#3437, behavior 5). One CHAIN per case: the
    // ops are classified in sequence order and each verdict is folded into
    // the projection, so the answers cover finding 3431-R10's carry-forward
    // as well as the per-op rule.
    case "classify-adopted": {
      const verdicts = [];
      for (const each of request.cases ?? []) {
        const doc = new Y.Doc();
        doc.transact(() => {
          for (const [model, entries] of Object.entries(each.overlay ?? {})) {
            const map = doc.getMap(model);
            for (const [key, value] of entries) map.set(key, value);
          }
        });
        const projection = createRestoreProjection();
        const chain = [];
        for (const op of each.ops ?? []) {
          const pending = {
            seq: op.seq,
            model: op.model,
            recordId: op.recordId,
            op: op.op,
            fields: op.fields ?? [],
            baseEpoch: op.baseEpoch ?? 1,
            ts: op.ts ?? 0,
            mutation: op.mutation ?? null,
            priorOverlay: op.priorOverlay ?? null,
          };
          const verdict = classifyAdoptedOp(
            doc,
            pending,
            op.mergedRow === undefined ? null : op.mergedRow,
            projection
          );
          projectRestoredKeys(doc, pending, verdict, projection);
          chain.push(
            typeof verdict === "object"
              ? { kind: "fragment", restore: verdict.restore, keep: verdict.keep ?? [] }
              : { kind: verdict }
          );
        }
        verdicts.push(chain);
      }
      return { verdicts };
    }

    // What a client carries into the next epoch, off js-bao's own
    // `format2EpochHandoff` (#3437, behavior 8). The overlay is the only place
    // an owed write's exact shape survives — an explicit null unset, a member
    // tombstone, and the difference between a patch and a `_replace` create
    // all vanish once a row has been materialized — so the carry reads it
    // rather than the merged view, and this is where Swift's reading of it is
    // held to this one's.
    case "carry": {
      const results = [];
      for (const each of request.cases ?? []) {
        const doc = new Y.Doc();
        doc.transact(() => {
          for (const [model, entries] of Object.entries(each.overlay ?? {})) {
            const map = doc.getMap(model);
            for (const [key, value] of entries) map.set(key, value);
          }
        });
        const readOverlay = (model, recordId) => {
          const map = doc.getMap(model);
          const grouped = groupOverlayEntries(Array.from(map.entries()));
          for (const entry of grouped.values()) {
            if (entry.id === recordId) return entry;
          }
          return {
            id: recordId,
            fields: {},
            stringSets: {},
            replace: false,
            deleted: false,
          };
        };
        const ops = (each.ops ?? []).map((op) => ({
          seq: op.seq,
          model: op.model,
          recordId: op.recordId,
          op: op.op,
          fields: op.fields ?? [],
          baseEpoch: op.baseEpoch ?? 1,
          ts: op.ts ?? 0,
          mutation: op.mutation ?? null,
          priorOverlay: op.priorOverlay ?? null,
        }));
        let carried = carryUnackedOverlay(ops, readOverlay, {
          suppressDeletes: each.suppressDeletes ?? [],
        });
        if (each.later !== undefined) {
          carried = suppressSupersededKeys(
            carried,
            each.later.map((op) => ({
              seq: op.seq,
              model: op.model,
              recordId: op.recordId,
              op: op.op,
              fields: op.fields ?? [],
              baseEpoch: 1,
              ts: 0,
              mutation: null,
              priorOverlay: null,
            }))
          );
        }
        // And what those entries WRITE onto the fresh epoch's document, which
        // is the half a Swift port could get right in the entry and wrong on
        // the wire.
        const fresh = new Y.Doc();
        fresh.transact(() => {
          for (const { model, entry } of carried) {
            writeCarriedOverlay(fresh.getMap(model), entry);
          }
        });
        const written = {};
        for (const { model } of carried) {
          written[model] = Array.from(fresh.getMap(model).entries()).sort(
            (a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)
          );
        }
        results.push({
          carried: carried.map(({ model, entry }) => ({ model, entry })),
          written,
        });
      }
      return { results };
    }

    // The chain planner, straight off js-bao's own `format2FastForward`
    // (#3437, behavior 14). Which chain may be trusted is decided from the
    // handshake alone, before a byte is downloaded, so a disagreement here is
    // a client that converges on a state that never existed.
    case "plan-fast-forward":
      return {
        plans: (request.cases ?? []).map((each) =>
          planFastForward({
            current: each.current,
            target: each.target,
            sealed: each.sealed ?? [],
          })
        ),
      };

    // The recency-aware resolution, straight off js-bao's own
    // `format2OfflineReplay` (#3437, behavior 19). The ledger is built from
    // per-epoch overlay entries plus the seal times, exactly as a catch-up
    // builds it while it folds the chain — an epoch named in `noted` with no
    // entries is one that was applied and touched nothing, which is what
    // makes `covers` true for it.
    case "resolve-offline-replay": {
      const plans = [];
      for (const each of request.cases ?? []) {
        const ledger = new OfflineConflictLedger();
        ledger.noteSealTimes(each.sealTimes ?? []);
        for (const epoch of each.noted ?? []) {
          ledger.noteOverlay(epoch, new Y.Doc());
        }
        for (const group of each.epochs ?? []) {
          for (const entry of group.entries ?? []) {
            ledger.noteEntry(group.epoch, "Note", {
              id: entry.id,
              fields: entry.fields ?? {},
              stringSets: entry.stringSets ?? {},
              replace: entry.replace ?? false,
              deleted: entry.deleted ?? false,
            });
          }
        }
        const ingest = each.ingest
          ? {
              through: each.ingest.through,
              scope: each.ingest.scope,
              records: new Map(
                Object.entries(each.ingest.records ?? {}).map(([key, value]) => [
                  offlineReplayRecordKey(...key.split(" ")),
                  value,
                ])
              ),
            }
          : undefined;
        const plan = resolveOfflineReplay({
          ops: (each.ops ?? []).map((op) => ({
            seq: op.seq,
            model: op.model ?? "Note",
            recordId: op.recordId ?? "r1",
            op: op.op,
            fields: op.fields ?? [],
            baseEpoch: op.baseEpoch ?? 1,
            ts: op.ts ?? 0,
            mutation: op.mutation ?? null,
            priorOverlay: op.priorOverlay ?? null,
          })),
          ledger,
          currentEpoch: each.currentEpoch,
          now: each.now,
          ...(each.clockOffsetKnown === undefined
            ? {}
            : { clockOffsetKnown: each.clockOffsetKnown }),
          ...(ingest ? { ingest } : {}),
        });
        plans.push({
          ops: plan.ops.map((op) => ({ seq: op.seq, fields: op.fields })),
          narrowed: plan.narrowed.map((op) => ({ seq: op.seq, fields: op.fields })),
          suppressedDeletes: plan.suppressedDeletes,
          rebuildRequired: plan.rebuildRequired,
          notices: plan.notices.map((notice) => ({
            model: notice.model,
            recordId: notice.recordId,
            field: notice.field ?? null,
            op: notice.op,
            outcome: notice.outcome,
            reason: notice.reason,
            epoch: notice.epoch,
          })),
        });
      }
      return { plans };
    }

    case "plan-cold-start":
      return {
        plans: request.cases.map((each) =>
          planColdStart({
            held: each.held,
            reported: each.reported,
            sealed: each.sealed ?? [],
            snapshot: each.snapshot ?? null,
          })
        ),
      };

    // What a device should hydrate, and what it refuses (#3437, behavior 32).
    // The refusal is reported rather than thrown so the Swift side can compare
    // BOTH answers of one function over one input.
    case "plan-hydration": {
      try {
        const plan = planSnapshotHydration({
          manifest: request.manifest,
          capability: request.capability,
          models: request.models ?? [],
          completedChunks: request.completedChunks ?? [],
        });
        return {
          kind: plan.kind,
          models: plan.models,
          skipped: plan.skipped,
          bytes: plan.bytes,
          chunkBytes: request.manifest.chunks.map((chunk) =>
            estimateMaterializedBytes(chunk)
          ),
        };
      } catch (error) {
        if (error?.code !== "FORMAT2_STORAGE_UNAVAILABLE") throw error;
        return {
          refused: error.reason,
          requiredBytes: error.requiredBytes,
          availableBytes: error.availableBytes,
          models: error.models,
        };
      }
    }

    // One bulk-load chunk, in the shape the ingest routes take it (#3434):
    // `id\tpatch` lines, gzipped, with the descriptor the upload carries
    // beside the body. A FIXTURE rather than a decision — the server hashes
    // and re-validates every field of it, so a wrong one fails loudly there.
    case "encode-ingest-chunk": {
      const zlib = require("zlib");
      const crypto = require("crypto");
      const text =
        request.lines
          .map((line) => `${line.id}\t${JSON.stringify(line.patch)}`)
          .join("\n") + "\n";
      const raw = Buffer.from(text, "utf8");
      const body = zlib.gzipSync(raw, { level: 9 });
      const ids = request.lines.map((line) => line.id);
      return {
        body: body.toString("base64"),
        descriptor: {
          model: request.model,
          index: request.index ?? 0,
          rows: request.lines.length,
          bytes: body.byteLength,
          rawBytes: raw.byteLength,
          sha256: crypto.createHash("sha256").update(body).digest("hex"),
          firstId: ids[0],
          lastId: ids[ids.length - 1],
        },
      };
    }

    default:
      throw new Error(`unknown command: ${request.command}`);
  }
}

async function main() {
  const raw = await readStdin();
  let request;
  try {
    request = JSON.parse(raw);
  } catch (error) {
    process.stdout.write(
      JSON.stringify({ error: `bad request JSON: ${error.message}` })
    );
    process.exitCode = 1;
    return;
  }
  try {
    process.stdout.write(JSON.stringify(await handle(request)));
  } catch (error) {
    process.stdout.write(
      JSON.stringify({ error: error.message, stack: error.stack })
    );
    process.exitCode = 1;
  }
}

main();
