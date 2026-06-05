# Event-name parity

Events flow through `client.events.on(.eventName) { ... }` (Swift) and `client.events.on("event-name", handler)` (JS). Cross-platform code that subscribes to an event by name needs both clients to **emit the same name with the same payload shape**.

## Status: ⚠️ Diverges in 16 places

There are real parity gaps here. None are P0, but the gaps quietly break cross-language event subscription.

## Events present on both, parity verified

| Event | Swift `JsBaoEvent` | JS event name | Payload shape | Status |
|---|---|---|---|---|
| Sync | `.sync` | `"sync"` | `{ documentId, synced }` | ✅ |
| Connection state | `.connectionState` | `"connectionState"` | `{ state }` | ✅ |
| Document loaded | `.documentLoaded` | `"documentLoaded"` | see below | ⚠️ |
| Invitation | `.invitation` | `"invitation"` | `{ ... }` | ✅ |
| Auth ready | `.authReady` | `"authReady"` | shape diverges (see api-methods.md) | ⚠️ |
| Refresh | `.refresh` | `"refresh"` | `{ }` | ✅ |
| Workflow run | `.workflowRun` | `"workflowRun"` | `{ runId, status }` | ✅ |
| Workflow cancelled | `.workflowCancelled` | `"workflowCancelled"` | `{ runId }` | ✅ |
| Workflow apply | `.workflowApply` | `"workflowApply"` | `{ runId, ... }` | ✅ |
| Network mode | `.networkMode` | `"networkMode"` | `{ mode }` | ✅ |
| Cache updated | `.cacheUpdated` | `"cacheUpdated"` | `{ key, updatedAt, source, value }` | ✅ |
| Cache update failed | `.cacheUpdateFailed` | `"cacheUpdateFailed"` | `{ key, error }` | ✅ |
| Document opened | (no Swift case) | — | — | see below |

> **`cacheUpdated` / `cacheUpdateFailed`** are emitted by `KvCache` on the network-refresh path on both clients (Swift: `Internal/KvCache.swift`, fired after a successful `set` / on a fetch error; JS: `src/client/kv-cache.ts`). The Swift `KvCache` takes an injected `emit` closure (wired through `CacheFacade` from `JsBaoClient`). Note: the JS client additionally re-emits these as `meUpdated` / `meUpdateFailed` when `key == "me"` — that `me`-reaction is **not yet wired on Swift** (see issue #1042).

## ⚠️ DocumentLoadedEvent.source — doc comment lies

| Field | What Swift docstring says | What JS actually emits |
|---|---|---|
| `source` | `"sqlite" or "server"` | `"indexeddb" \| "server" \| "local"` |

Swift's docstring is wrong. JS emits `"local"` (for offline-store hydration), `"server"` (for fresh sync), or `"indexeddb"` (browser only). Swift's `"sqlite"` value isn't emitted by JS at all, and Swift never emits `"local"` despite having an offline store.

**Recommended fix:** make Swift emit one of `"local"` / `"server"` (drop `"sqlite"` since SQLite is the *backing storage* on Apple, not a *source* — `"local"` is the cross-platform meaning), and update the docstring.

## ❌ Events present on JS but missing on Swift

These are JS-side `events.emit(...)` calls with no Swift case in `Types/Events.swift`. Cross-platform code that subscribes to any of these on the Swift side will silently never fire.

| JS event name | Triggered by | Recommended status |
|---|---|---|
| `auth:logout` | logout flow | ⛔ or ❌ |
| `auth:onlineAuthRequired` | offline → online auth handoff | ⛔ or ❌ |
| `connection-close` | WS close | ⛔ or ❌ |
| `connection-error` | WS error | ⛔ or ❌ |
| `documentOpened` | doc lifecycle | ⛔ or ❌ |
| `documentCreateCommitFailed` | pending-create failure | ⛔ or ❌ |
| `error` | generic error bus | ⛔ or ❌ |
| `meUpdateFailed` | me update failed | ⛔ or ❌ |
| `offlineAuth:expiringSoon` | offline auth nearing expiry | ⛔ or ❌ |
| `pendingCreateCommitted` | pending-create succeeded | ⛔ or ❌ |
| `schema-discovered` | runtime schema discovery | ⛔ or ❌ |
| `syncPerf` | sync performance instrumentation | ⛔ or ❌ |
| `workflowStarted` | workflow lifecycle | ⛔ or ❌ |
| `documentSyncStateChanged` | per-doc sync state | ⛔ or ❌ |

> Default for these is **⛔** ("intentionally out for v1") — flip to **❌** for any that should be on Swift v1.

## Swift-only events (JS never emits them)

| Swift event | Notes |
|---|---|
| `.auth` | Generic auth event — JS never has an `"auth"` event. Either rename to match a JS counterpart or document as Swift-only. |
| `.blobsUploadQueued` | Per-blob queue event — JS doesn't expose blob queue progress. Either add JS-side or document as Swift-only. |
| `.remoteUpdate` | Swift emits this. **JS uses `"remoteUpdate"` as a Yjs origin tag** (passed to `Y.Doc.transact(fn, "remoteUpdate")`), not as an emitted event. Cross-language code subscribing to `"remoteUpdate"` on JS will never fire. **Pick one shape — emit it as an event on both, or use it as an origin tag on both.** |

## Source files

- Swift: [`Sources/JsBaoClient/Types/Events.swift`](../../Sources/JsBaoClient/Types/Events.swift), [`Sources/JsBaoClient/Types/EventEmitter.swift`](../../Sources/JsBaoClient/Types/EventEmitter.swift)
- JS: search `src/client/internal/` for `eventEmitter.emit(`

## Payload-parity fixes (events)

`documentMetadataChanged.source` is now `"local" | "server"` (was `"local" | "remote"`) and non-optional — JS's `"idb"` is dropped (no SQLite analog); the `blobs:upload-{progress,completed,failed}` payloads now carry the full upload-queue record (`queueId`/`filename`/`contentType`/`status`/`attempts`/`retainLocal`/`nextAttemptAt`/`updatedAt`/`lastError`, `lastError` optional) populated from `BlobManager`'s `UploadTask`; and `syncPerf` gained `timings`/`clientTimings` maps for decode parity (Swift has no `syncPerf` frame handler or per-phase instrumentation yet, so they stay empty). `awareness` deltas remain out — the live presence subsystem isn't in Swift v1, so there's no snapshot to diff.

## Notes for maintainers

When adding a new event:
1. Pick the name on **both** sides at the same time. Decide the shape together.
2. Add the Swift `JsBaoEvent` case + payload struct.
3. Make sure the EventEmitter on both sides emits identical payload structures.
4. Update this table.
