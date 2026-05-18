#!/usr/bin/env node
// Reader harness for cross-platform Swift↔JS round-trip tests.
//
// Reads raw Yjs update bytes from stdin, applies them to a fresh
// Y.Doc, and dumps a JSON summary that Swift tests assert against.
//
// Commands:
//   discover-schema
//     → runs js-bao's `discoverSchema(yDoc)` and prints the result.
//   read-record <modelName> <recordId>
//     → prints the record's fields. Scalars pass through raw; nested
//       Y.Maps become `{ _type: "stringset", entries: [...] }`.
//   read-unique-index <modelName> <constraintName>
//     → prints the full `_uniqueIdx_{model}_{constraint}` Y.Map.
//   raw-meta <modelName>
//     → prints the `_meta_{model}` Y.Map exactly as js-bao stored it.

const Y = require("yjs");
const { discoverSchema } = require("js-bao");

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks);
}

function materializeYMap(value) {
  if (value instanceof Y.Map) {
    const out = {};
    for (const [k, v] of value.entries()) {
      out[k] = materializeYMap(v);
    }
    return out;
  }
  if (value instanceof Y.Array) {
    return value.toArray().map(materializeYMap);
  }
  return value;
}

async function main() {
  const cmd = process.argv[2];
  const update = await readStdin();

  const doc = new Y.Doc();
  Y.applyUpdate(doc, update);

  let result;
  if (cmd === "discover-schema") {
    result = discoverSchema(doc);
  } else if (cmd === "read-record") {
    const modelName = process.argv[3];
    const recordId = process.argv[4];
    const modelMap = doc.getMap(modelName);
    const rec = modelMap.get(recordId);
    if (!(rec instanceof Y.Map)) {
      result = null;
    } else {
      const out = {};
      for (const [k, v] of rec.entries()) {
        if (v instanceof Y.Map) {
          out[k] = { _type: "stringset", entries: Array.from(v.keys()).sort() };
        } else {
          out[k] = v;
        }
      }
      result = out;
    }
  } else if (cmd === "read-unique-index") {
    const modelName = process.argv[3];
    const constraintName = process.argv[4];
    const indexMap = doc.getMap(`_uniqueIdx_${modelName}_${constraintName}`);
    const out = {};
    for (const [k, v] of indexMap.entries()) out[k] = v;
    result = out;
  } else if (cmd === "raw-meta") {
    const modelName = process.argv[3];
    const meta = doc.getMap(`_meta_${modelName}`);
    result = materializeYMap(meta);
  } else {
    process.stderr.write(`Unknown command: ${cmd}\n`);
    process.exit(1);
  }

  process.stdout.write(JSON.stringify(result));
}

main().catch((e) => {
  process.stderr.write(`Harness error: ${e.stack || e}\n`);
  process.exit(1);
});
