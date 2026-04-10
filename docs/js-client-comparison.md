# Differences from the JS Client

The Swift client (`JsBaoClient`) is a native port of the JS client (`js-bao-wss-client`). The public API is intentionally kept close to the JS version — same method names, same event names, same error codes — so developers familiar with one can pick up the other quickly. The differences are all about platform adaptation.

## Storage: SQLite replaces IndexedDB

| Concern | JS | Swift |
|---------|-----|-------|
| Document persistence | IndexedDB via `y-indexeddb` | SQLite via C API (`sqlite3`) |
| Key-value storage | IndexedDB (`StorageProvider`) | SQLite WAL-mode (`SQLiteStorageProvider`) |
| Query engine | `sql.js` (Wasm SQLite in-memory) or `better-sqlite3` (Node) | Native SQLite in-memory |
| Storage config | `"auto"` / `"indexeddb"` / `"better-sqlite3"` / `"memory"` | `.sqlite(directory:)` / `.memory` |

The Swift client uses a single `kv_store` table with compound key `(store, key)` across all storage domains (metadata, auth, analytics, cache). WAL mode is enabled for concurrent reads.

## Query indexing: full rebuild vs incremental updates

This is the **most significant runtime difference** between the two clients today. Both clients mirror Y.Map model data into a SQLite table so users can run MongoDB-style queries against the data — but they keep that mirror in sync in completely different ways. The Swift approach is simpler but less efficient; reaching JS parity here is tracked as future work.

### How JS does it: nested observers + per-record incremental updates

In `js-bao` (the JS client's model layer, source: [`node_modules/.pnpm/js-bao@*/node_modules/js-bao/dist/chunk-3PZWHUZO.js`](../../node_modules/.pnpm/js-bao@0.2.12_yjs@13.6.29/node_modules/js-bao/dist/chunk-3PZWHUZO.js) lines 2110–2230 and 4060–4135), `BaseModel` sets up a **two-level Yjs observer hierarchy**:

1. **A top-level observer** on the model's root `Y.Map` (`documentYMap.observe(...)`). This fires whenever a record is added or deleted to the model. For each `event.changes.keys` entry:
   - `change.action === "add"` → register a nested observer on the new record's inner `Y.Map`, then issue a single `dbInstance.insert(modelName, { ...itemData, _meta_doc_id, _meta_permission_hint })` for just that one row.
   - `change.action === "delete"` → issue a single `dbInstance.delete(modelName, key)` for that row.
   - Remote adds get an extra `resolveConflictsForBatch()` step that discards Yjs-level duplicate IDs *before* hitting SQLite.

2. **A nested observer per record** on each record's inner `Y.Map` (`recordYMap.observe(...)`). This fires whenever a field on a single record changes. The handler reads the record's *current* fields out of the inner map and issues one `dbInstance.insert(modelName, { ...updatedData, _meta_doc_id, _meta_permission_hint })` (which is `INSERT OR REPLACE` under the hood). Only the touched record's row is rewritten.

So in JS, **a single field change on a single record results in a single SQLite `UPDATE` (well, `INSERT OR REPLACE`) on a single row**. The cost of keeping the index in sync is proportional to the number of changes, not the size of the model. The mirror is also always-up-to-date because the observer fires synchronously inside the Yjs transaction commit.

### How Swift does it: doc-level dirty flag + full table rebuild

The Swift `BaoModel<T>` ([`BaoModel.swift:73`](../Sources/JsBaoClient/BaoModel.swift#L73)) takes a much simpler approach. There is **one** subscription per model, and it lives at the *document* level rather than at the map or record level:

```swift
// BaoModel.swift:125
self.docUpdateSubscription = doc.observeUpdate { [weak self] _ in
    self?.markQueryIndexDirty()
}
```

`observeUpdate` is the YSwift fork's doc-level update observer (see [yswift-fork.md](yswift-fork.md)). It fires once per Yjs transaction commit with the raw update bytes — but the callback **doesn't look at the bytes at all**. It just flips a `queryIndexDirty: Bool` flag under a lock and returns. There is no per-record observer, no `change.action` switch, and no per-row SQLite write.

The actual SQLite work is deferred to the next query call ([`BaoModel.swift:254`](../Sources/JsBaoClient/BaoModel.swift#L254)):

```swift
private func syncToQueryEngine() {
    guard claimDirtyForRebuild() else { return }
    let records = findAll().map { $0.toFields() }
    queryEngine.syncRecords(modelName: T.modelName, records: records)
    syncCallCount += 1
}
```

`syncRecords` ([`BaoModelQueryEngine.swift:70`](../Sources/JsBaoClient/Query/BaoModelQueryEngine.swift#L70)) does literally what it sounds like:

```swift
execute("DELETE FROM \"\(tableName)\"")
// ... then INSERT OR REPLACE every row in a single prepared-statement loop
```

So in Swift, **the next query after any change wipes the entire table and reinserts every row in the model**, regardless of whether one field on one record changed or every record was rewritten. The dirty flag is the only optimization: it ensures we don't rebuild between queries when nothing has changed, and it coalesces N consecutive updates into a single rebuild on the next query (the recent commit `ec5598d6` added this — before that, every query rebuilt unconditionally).

### Comparison

| Aspect | JS (`js-bao` BaseModel) | Swift (`BaoModel<T>`) |
|--------|--------------------------|------------------------|
| Observation point | Top-level Y.Map + nested per-record Y.Map | Document-level `observeUpdate` |
| What the observer reads | Yjs `event.changes.keys` deltas + record contents | Nothing — just flips a bool |
| SQLite work per change | One `INSERT`/`UPDATE`/`DELETE` for the affected row | Deferred — full table rebuild on next query |
| Cost scales with | Number of changed records | Total record count, every time something changes |
| Up-to-date latency | Synchronous with the Yjs commit | "Eventually" — first query after a write triggers the rebuild |
| Multi-doc model support | Yes — `_meta_doc_id` column + `_meta_permission_hint` | No — one model is bound to exactly one document |
| Remote-add deduplication | `resolveConflictsForBatch()` before insert | N/A (rebuild reads the merged Y.Map state directly) |
| `stringset` field type | Junction-table support | Not implemented |
| Initial population | Observers fire as records load | First query triggers `findAll()` over the entire model |

### When this matters (and when it doesn't)

The Swift approach is **fine for small models and read-heavy workloads** — the dirty flag means a long burst of writes followed by a single query is exactly one rebuild, which is comparable to N incremental updates. For a 50-record model where you write once and query a hundred times, the two approaches are indistinguishable.

It **degrades** when:
- The model has hundreds or thousands of records (every rebuild scales linearly with size, not delta size).
- Writes and queries are interleaved tightly (every query forces a rebuild even when only one field changed).
- The caller expects a query immediately after a write to be cheap.

It also means Swift can't currently support multi-doc models (where one SQLite table holds records aggregated from many open documents) the way JS does — there's nowhere to put a `_meta_doc_id` column when you're rebuilding the whole table from one doc's contents on every query.

Reaching JS parity requires moving to a per-record observer model, which the YSwift fork could support but doesn't yet (the fork only exposes doc-level update bytes, not Yjs `Y.Map` change events).

## Document update observer wiring (used by both BaoModel and DocumentManager)

The dirty-flag approach above relies on `YDocument.observeUpdate(...)`, which is **not** in upstream YSwift (0.5.3) — it's an addition in our fork. The same observer is also how `DocumentManager` detects local writes to forward over the WebSocket. Both responsibilities ride on the same callback mechanism. See [yswift-fork.md](yswift-fork.md) for the full history of the fork and the `observeUpdateV1` Rust binding it added.

## CRDT Layer: YSwift fork replaces Yjs

| Concern | JS | Swift |
|---------|-----|-------|
| CRDT library | Yjs (JavaScript) | Yrs (Rust) via YSwift bindings |
| Update observer | `doc.on("update", cb)` | `doc.observeUpdate(cb)` — **requires our fork** |
| Sync protocol | Custom JS implementation | Reimplemented in Swift using YSwift's `YProtocol` |
| Combine support | N/A | `doc.observeUpdate()` returns `AnyPublisher<[UInt8], Never>` |

The upstream YSwift package (0.5.3) didn't expose document-level update observers — only map/array/text observers. We forked it and added `observeUpdateV1` at the Rust FFI layer. See [yswift-fork.md](yswift-fork.md).

## Networking

| Concern | JS | Swift |
|---------|-----|-------|
| HTTP | `fetch` / `XMLHttpRequest` | `URLSession` |
| WebSocket | Browser `WebSocket` API | `URLSessionWebSocketTask` |
| Reconnection | Same backoff logic | Same backoff logic (200ms base + exponential, capped at `maxReconnectDelay`) |
| Custom headers | Via constructor options | Via `wsHeaders` option (URLSession supports this natively) |
| WS auth | JWT in `?token=` query parameter (browser `WebSocket` cannot set custom headers) | Same `?token=` query parameter, for protocol compatibility with the existing server. See the TODO comment at [`JsBaoClient.swift:1039`](../Sources/JsBaoClient/JsBaoClient.swift#L1039) — Swift could send the token as an `Authorization` header on the upgrade request, but doing so requires a coordinated server change, so we stay on the query-param protocol for now. |
| Concurrent connect coalescing | Single `connect()` promise; all callers await it | `WebSocketManager` keeps an explicit `pendingConnectWaiters` list so secondary callers atomically register under the lock and are resumed together (eliminates a poll-based race that existed in an earlier revision) |

### Outbound update sync

Both clients debounce local Yjs updates before sending them over the WebSocket; the default is 50ms in both. The configuration knob is `sync.outboundDebounceMs` ([`Options.swift`](../Sources/JsBaoClient/Types/Options.swift)). The debounce is implemented with a per-document `Task.sleep` in Swift vs. `setTimeout` in JS — same behavior, different timer primitive.

## BaoModel: one-doc-per-model vs multi-doc indexing

JS `BaseModel` ([`js-bao` chunk-3PZWHUZO.js:2110](../../node_modules/.pnpm/js-bao@0.2.12_yjs@13.6.29/node_modules/js-bao/dist/chunk-3PZWHUZO.js)) supports a feature the Swift `BaoModel<T>` does not: **a single SQLite table can hold records from multiple Y.Docs simultaneously**. Each row carries `_meta_doc_id` and `_meta_permission_hint` columns, the model registers a top-level observer per opened doc, and queries can transparently span all the docs that have been registered. This is how the JS client implements features like "list every page across every workspace I have open."

The Swift `BaoModel<T>` is bound to exactly one `YDocument` at construction time ([`BaoModel.swift:105`](../Sources/JsBaoClient/BaoModel.swift#L105)) and its in-memory SQLite mirror only contains rows from that one doc. To query across documents you'd have to instantiate one `BaoModel<T>` per document and merge the results in Swift. This is a deliberate simplification that falls out of the dirty-flag rebuild strategy: there's no clean way to issue "rebuild but only for this one doc's slice of the table" without re-introducing the per-record observation that the rebuild approach was designed to avoid.

This is the second piece of work needed to reach JS parity in the model layer (alongside incremental updates).

## Conflict resolution on remote sync

JS does an extra step that Swift currently skips. When a remote sync delivers multiple records with the same logical ID (e.g., two clients independently created records with the same key offline), the JS top-level observer calls `resolveConflictsForBatch()` to pick a winner and discards the losers *before* writing to SQLite. The Swift client doesn't do this because the rebuild path always reads the merged Y.Map state, where Yjs's CRDT semantics have already collapsed conflicts — but the side effect is that you can't observe or react to the discarded duplicates the way you can in JS.

## Field types: `stringset` not yet implemented

JS `BaseModel` supports a `stringset` field type that's stored in a separate junction table and joined in at query time. Swift `BaoModel<T>` only supports the four primitive `FieldType` cases (`string`, `number`, `boolean`, `json`); there's no junction-table support. Records that need set semantics in Swift today should encode them as `.json` (a JSON-serialized array).

## Concurrency

| Concern | JS | Swift |
|---------|-----|-------|
| Async model | Promises / `async`/`await` | Swift `async`/`await` + `Task` |
| Thread safety | Single-threaded (event loop) | `NSLock` + `@unchecked Sendable` (no actors) |
| Event system | `Observable` (extends y-js observable) | Custom `EventEmitter<T>` with typed handlers |
| Timers | `setTimeout` / `setInterval` | `Task.sleep` with cancellation |

## Features Present in JS but Not (Yet) in Swift

| Feature | Notes |
|---------|-------|
| Incremental query-index updates | See "Query indexing" above. Swift uses dirty-flag + full rebuild; JS uses per-record observers + targeted INSERT/DELETE. |
| Multi-doc BaoModel indexing | JS `BaseModel` mirrors records from many docs into one SQLite table via `_meta_doc_id` columns; Swift `BaoModel<T>` is one model per document. |
| `stringset` field type with junction tables | Swift only supports `string`/`number`/`boolean`/`json` field types. |
| Remote-conflict deduplication on insert | JS calls `resolveConflictsForBatch()` before writing to SQLite; Swift relies on the rebuild reading Yjs's already-merged state. |
| Offline grants (passkey/PIN) | WebAuthn is browser-only; Swift equivalent would use Keychain + LAContext |
| Service worker blob proxy | iOS/macOS don't have service workers |
| `autoOAuth` / `suppressAutoLoginMs` | Not yet wired up |
| `listLocalDocumentsUnified` | Unified local+remote document listing |
| Analytics auto-events config | The granular `analyticsAutoEvents` options object |
| Database CSV import | `databases.importCsv()` |

## Features in Swift but Not JS

| Feature | Notes |
|---------|-------|
| Combine publishers | `doc.observeUpdate()` returns an `AnyPublisher` for reactive SwiftUI integration |
| `.sqlite()` storage default | JS defaults to `"auto"` (IndexedDB in browser); Swift defaults to SQLite |
| `BaoModelRecord` protocol + `BaoModel<T>` | Typed, protocol-based record models with `fields` definitions — more idiomatic than JS's dynamic approach |

## Error Code Parity

Error codes (`JsBaoErrorCode`, `AuthCode`) use identical string values across both clients so server-side error handling works consistently regardless of which client generated the error. For example, `"OFFLINE"`, `"ACCESS_DENIED"`, `"NOT_FOUND"` are the same strings in both.

## Event Name Parity

`JsBaoEvent` cases map to the same string event names as the JS client (e.g., `.authSuccess` → `"auth-success"`, `.blobsUploadProgress` → `"blobs:upload-progress"`). This matters for any server-side or cross-client logic that keys on event names.
