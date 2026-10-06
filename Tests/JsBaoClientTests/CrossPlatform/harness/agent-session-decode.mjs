// The JS client's decode of agent session rows, projected for comparison
// with the Swift client's (#3810, AgentSessionDecodeParityLiveTests).
//
// Usage, from the repository root:
//   node --import tsx agent-session-decode.mjs <repoRoot> < rows.json
//
// stdin is `{ "rows": [{ "model": "PrimitivePart", "row": { ... } }, ...] }`;
// stdout is one projection per row, in order, or `null` for a row the JS
// client does not decode. The projection is the one the shared fixtures spell
// (swift-client/Tests/JsBaoClientTests/Agents/AgentSessionProjection.swift):
// an open value as the known value or "unknown", `{"$absent": true}` for no
// value, a stringset as its members sorted ([] when absent), a JSON column as
// its value.
//
// The client's ESM `dist` does not load under plain node (its imports carry no
// extensions), so the decoders are read from the client source through `tsx`.

import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = process.argv[2];
const models = await import(
  pathToFileURL(path.join(root, "src/client/agents/sessionModels.generated.ts")).href
);

const ABSENT = { $absent: true };
const value = (v) => (v === undefined ? ABSENT : v);
const members = (v) => (Array.isArray(v) ? [...v].sort() : []);

function pick(record, keys, stringsets = []) {
  const out = {};
  for (const key of keys) out[key] = stringsets.includes(key) ? members(record[key]) : value(record[key]);
  return out;
}

const SESSION_KEYS = [
  "id", "schemaVersion", "agentKey", "configId", "status", "activeTurnId",
  "activeTurnInitiatorUserId", "activeTurnStartedAt", "activeTurnMessageIds", "queue", "title",
  "scope", "variables", "viewerUserIds", "participantUserIds", "ownerUserId", "lastErrorCode",
  "lastErrorMessage", "createdAt", "modifiedAt",
];
const SESSION_SETS = ["activeTurnMessageIds", "viewerUserIds", "participantUserIds"];
const MESSAGE_KEYS = ["id", "seq", "turnId", "authorKind", "authorUserId", "clientMessageId", "createdAt"];
const PART_COMMON = ["id", "messageId", "seq", "createdAt", "modifiedAt"];
const PART_KINDS = {
  text: ["kind", "state", "text", "providerMetadata"],
  reasoning: ["kind", "state", "text", "providerMetadata"],
  tool_call: [
    "kind", "state", "toolCallId", "toolName", "input", "output", "errorText", "errorCode",
    "statusText", "approvalApproved", "approvalReason", "approvalUserId", "approvalRespondedAt",
    "resolvedByUserId", "artifact", "artifactBlobId", "providerMetadata",
  ],
  file: ["kind", "mediaType", "filename", "blobId", "sizeBytes"],
  event: ["kind", "eventKind", "eventId", "refersTo", "data"],
  unknown: ["kind", "rawKind"],
};
const STEP_KEYS = [
  "id", "turnId", "seq", "kind", "status", "startedAt", "endedAt", "durationMs", "provider",
  "model", "configId", "callId", "toolName", "functionName", "functionVersion", "inputTokens",
  "outputTokens", "totalTokens", "reasoningTokens", "cachedInputTokens", "cost",
  "historyMessageIds", "errorCode", "errorMessage", "historyMode", "historySelection",
  "providerDurationMs",
];

function project(model, row) {
  switch (model) {
    case "PrimitiveSession": {
      let record;
      try {
        record = models.decodePrimitiveSession(row);
      } catch {
        return null;
      }
      return pick(record, SESSION_KEYS, SESSION_SETS);
    }
    case "PrimitiveMessage": {
      const record = models.decodePrimitiveMessage(row);
      return record ? pick(record, MESSAGE_KEYS) : null;
    }
    case "PrimitivePart": {
      const record = models.decodePrimitivePart(row);
      if (!record) return null;
      const kindKeys = PART_KINDS[record.kind] ?? PART_KINDS.unknown;
      return pick(record, [...PART_COMMON, ...kindKeys]);
    }
    case "PrimitiveStep": {
      const record = models.decodePrimitiveStep(row);
      return record ? pick(record, STEP_KEYS, ["historyMessageIds"]) : null;
    }
    default:
      return null;
  }
}

const input = JSON.parse(readFileSync(0, "utf8"));
process.stdout.write(JSON.stringify(input.rows.map(({ model, row }) => project(model, row))));
