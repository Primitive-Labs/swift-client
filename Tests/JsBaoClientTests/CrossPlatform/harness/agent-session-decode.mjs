// The JS client's decode of agent session rows, projected for comparison
// with the Swift client's (#3810, AgentSessionDecodeParityLiveTests; #4884:
// the seven models of a session's db3).
//
// Usage, from the repository root:
//   node --import tsx agent-session-decode.mjs <repoRoot> < rows.json
//
// stdin is `{ "rows": [{ "model": "ToolCall", "row": { ... } }, ...] }`;
// stdout is one projection per row, in order, or `null` for a row the JS
// client does not decode. The projection is the one the shared fixtures spell
// (swift-client/Tests/JsBaoClientTests/Agents/AgentSessionProjection.swift):
// every column the record represents (for a `Part`, its kind's columns; for
// one of a kind it does not know, `kind: "unknown"` and `rawKind`), an open
// value as the known value or "unknown", `{"$absent": true}` for no value, a
// stringset as its members sorted ([] when absent), a JSON column as its
// value. The columns are the IR's, so the projection follows the models.
//
// `projectAgentSessionRow` is exported for the JS unit suite, which holds the
// shared fixtures' `expect` to it.
//
// The client's ESM `dist` does not load under plain node (its imports carry no
// extensions), so the decoders are read from the client source through `tsx`.

import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const ABSENT = { $absent: true };
const value = (v) => (v === undefined ? ABSENT : v);
const members = (v) => (Array.isArray(v) ? [...v].sort() : []);

const DECODERS = {
  Session: "decodeAgentSession",
  Member: "decodeAgentSessionMember",
  Turn: "decodeAgentSessionTurn",
  Message: "decodeAgentSessionMessage",
  Part: "decodeAgentSessionPart",
  ToolCall: "decodeAgentSessionToolCall",
  Step: "decodeAgentSessionStep",
};

/**
 * The projection of one row of `model`, decoded by `decoders` (the client's
 * `sessionModels.generated`) under `schema` (the IR); `null` when it does not
 * decode.
 */
export function projectAgentSessionRow(schema, decoders, model, row) {
  const spec = schema.models[model];
  const decode = decoders[DECODERS[model]];
  if (!spec || typeof decode !== "function") return null;
  const record = decode(row);
  if (!record) return null;
  const columns = Object.entries(spec.columns);
  const out = {};
  const put = (name, column) => {
    out[name] = column.kind === "stringset" ? members(record[name]) : value(record[name]);
  };
  const discriminator = spec.discriminator;
  if (!discriminator) {
    for (const [name, column] of columns) put(name, column);
    return out;
  }
  const variant = Object.prototype.hasOwnProperty.call(discriminator.variants, record[discriminator.column])
    ? discriminator.variants[record[discriminator.column]]
    : undefined;
  const kindColumns = new Set(Object.values(discriminator.variants).flatMap((v) => v.columns));
  for (const [name, column] of columns) {
    if (name === discriminator.column) continue;
    if (kindColumns.has(name) && !variant?.columns.includes(name)) continue;
    put(name, column);
  }
  out[discriminator.column] = record[discriminator.column];
  if (!variant) out.rawKind = record.rawKind;
  return out;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const root = process.argv[2];
  const decoders = await import(pathToFileURL(path.join(root, "src/client/agents/sessionModels.generated.ts")).href);
  const { AGENT_SESSION_SCHEMA } = await import(
    pathToFileURL(path.join(root, "src/agents/session-document-schema.ts")).href
  );
  const input = JSON.parse(readFileSync(0, "utf8"));
  process.stdout.write(
    JSON.stringify(input.rows.map(({ model, row }) => projectAgentSessionRow(AGENT_SESSION_SCHEMA, decoders, model, row)))
  );
}
