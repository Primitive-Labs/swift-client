# Differences from the JS Client

The Swift client (`JsBaoClient`) is a native port of the JS client (`js-bao-wss-client`). The public API is intentionally kept close to the JS version — same method names, same event names, same error codes — so developers familiar with one can pick up the other quickly. The differences are all about platform adaptation.

## Storage: SQLite replaces IndexedDB

| Concern | JS | Swift |
|---------|-----|-------|
| Document persistence | IndexedDB via `y-indexeddb` | SQLite via C API (`sqlite3`) |
| Key-value storage | IndexedDB (`StorageProvider`) | SQLite WAL-mode (`SQLiteStorageProvider`) |
| Query engine | `sql.js` (Wasm SQLite in-memory) | Native SQLite in-memory |
| Storage config | `"auto"` / `"indexeddb"` / `"better-sqlite3"` / `"memory"` | `.sqlite(directory:)` / `.memory` |

The Swift client uses a single `kv_store` table with compound key `(store, key)` across all storage domains (metadata, auth, analytics, cache). WAL mode is enabled for concurrent reads.

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
| Reconnection | Same backoff logic | Same backoff logic (200ms base + exponential) |
| Custom headers | Via constructor options | Via `wsHeaders` option (URLSession supports this natively) |

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
| Offline grants (passkey/PIN) | WebAuthn is browser-only; Swift equivalent would use Keychain + LAContext |
| Service worker blob proxy | iOS/macOS don't have service workers |
| `js-bao` model system | The JS client re-exports dynamo-bao model constructors; Swift has `CollectionRecord` instead |
| `autoOAuth` / `suppressAutoLoginMs` | Not yet wired up |
| `listLocalDocumentsUnified` | Unified local+remote document listing |
| Analytics auto-events config | The granular `analyticsAutoEvents` options object |
| Database CSV import | `databases.importCsv()` |

## Features in Swift but Not JS

| Feature | Notes |
|---------|-------|
| Combine publishers | `doc.observeUpdate()` returns an `AnyPublisher` for reactive SwiftUI integration |
| `.sqlite()` storage default | JS defaults to `"auto"` (IndexedDB in browser); Swift defaults to SQLite |
| `CollectionRecord` protocol | Typed, protocol-based collection records with `fields` definitions — more idiomatic than JS's dynamic approach |

## Error Code Parity

Error codes (`JsBaoErrorCode`, `AuthCode`) use identical string values across both clients so server-side error handling works consistently regardless of which client generated the error. For example, `"OFFLINE"`, `"ACCESS_DENIED"`, `"NOT_FOUND"` are the same strings in both.

## Event Name Parity

`JsBaoEvent` cases map to the same string event names as the JS client (e.g., `.authSuccess` → `"auth-success"`, `.blobsUploadProgress` → `"blobs:upload-progress"`). This matters for any server-side or cross-client logic that keys on event names.
