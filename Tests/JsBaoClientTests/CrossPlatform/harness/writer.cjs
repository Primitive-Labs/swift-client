#!/usr/bin/env node
// Writer harness for cross-platform Swift↔JS round-trip tests.
//
// Reads a JSON spec from stdin describing schemas + records to author
// using js-bao's real `syncModelMeta` + raw Y.Map ops, then writes
// the resulting Y.Doc's update bytes to stdout.
//
// Spec shape:
//   {
//     schemas: [
//       {
//         name: "users",
//         fields: {
//           id:    { type: "id",     autoAssign: true, default: "$generate_ulid" },
//           email: { type: "string", unique: true }
//         },
//         uniqueConstraints: [{ name: "uq_x", fields: ["a","b"] }],
//         relationships:     { posts: { type: "hasMany", model: "posts", relatedIdField: "userId" } }
//       }
//     ],
//     records: {
//       users: {
//         u1: { email: "alice@example.com", tags: { _type: "stringset", entries: ["a","b"] } }
//       }
//     },
//     uniqueIndexes: {
//       // Optional: seed `_uniqueIdx_*` maps explicitly (for tests
//       // that want to assert Swift enforces against a JS-written index).
//       "_uniqueIdx_users_users_email_unique": { "alice@example.com": "u1" }
//     }
//   }

const Y = require("yjs");
const {
  syncModelMeta,
  registerFunctionDefault,
  generateULID,
} = require("js-bao");

registerFunctionDefault(generateULID, "generate_ulid");

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks);
}

/// Decode a `"$name"` default sentinel into the registered function,
/// or pass scalar defaults through unchanged.
function decodeFieldDefault(value) {
  if (typeof value !== "string") return value;
  if (value === "$generate_ulid") return generateULID;
  return value;
}

/// Synthesize a `ModelSchemaRuntimeShape` usable by `syncModelMeta`
/// without spinning up a BaseModel class — `syncModelMeta` only uses
/// `fields`, `resolvedUniqueConstraints`, and `options.relationships`.
function buildRuntimeShape(spec) {
  const fieldsMap = new Map();
  for (const [name, opts] of Object.entries(spec.fields || {})) {
    const copy = { ...opts };
    if (copy.default !== undefined) copy.default = decodeFieldDefault(copy.default);
    fieldsMap.set(name, copy);
  }
  const compound = (spec.uniqueConstraints || []).filter(
    (c) => c.fields.length > 1
  );
  return {
    class: null,
    options: {
      name: spec.name,
      uniqueConstraints: spec.uniqueConstraints,
      relationships: spec.relationships,
    },
    fields: fieldsMap,
    resolvedUniqueConstraints: compound,
  };
}

async function main() {
  const specBytes = await readStdin();
  const spec = JSON.parse(specBytes.toString());

  const doc = new Y.Doc();

  // 1. Schemas → _meta_*
  for (const schemaSpec of spec.schemas || []) {
    const shape = buildRuntimeShape(schemaSpec);
    syncModelMeta(doc, schemaSpec.name, shape);
  }

  // 2. Records → top-level data Y.Maps
  for (const [modelName, records] of Object.entries(spec.records || {})) {
    const modelMap = doc.getMap(modelName);
    for (const [id, fields] of Object.entries(records)) {
      const recMap = new Y.Map();
      modelMap.set(id, recMap);
      recMap.set("id", id);
      for (const [k, v] of Object.entries(fields)) {
        if (v && typeof v === "object" && v._type === "stringset") {
          const ss = new Y.Map();
          recMap.set(k, ss);
          for (const item of v.entries) ss.set(item, item);
        } else {
          recMap.set(k, v);
        }
      }
    }
  }

  // 3. Optional: explicit unique-index seeding.
  for (const [mapName, entries] of Object.entries(spec.uniqueIndexes || {})) {
    const m = doc.getMap(mapName);
    for (const [k, v] of Object.entries(entries)) m.set(k, v);
  }

  const update = Y.encodeStateAsUpdate(doc);
  // Binary passthrough. Make sure stdout is in binary mode.
  process.stdout.write(Buffer.from(update));
}

main().catch((e) => {
  process.stderr.write(`Harness error: ${e.stack || e}\n`);
  process.exit(1);
});
