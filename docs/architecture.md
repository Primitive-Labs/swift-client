# Architecture

> **For the parity-with-JS-client view, see [`parity/`](parity/).** This document covers the *internals* of the Swift client — how the layers fit together. Parity is a separate concern.

## Overview

The Swift client mirrors the JS client's layered design but uses platform-native primitives: `URLSession` for HTTP, `URLSessionWebSocketTask` for WebSocket, SQLite (via C API) for persistence, and Swift concurrency (`async/await`) throughout.

```
┌─────────────────────────────────────────────────┐
│                  JsBaoClient                     │  Public API surface
│   (documents, databases, llm, me, events, …)    │
├──────────┬──────────┬───────────┬───────────────┤
│  Auth    │ Document │ WebSocket │    HTTP       │  Internal layer
│Controller│ Manager  │  Manager  │   Client      │
├──────────┴──────────┴───────────┴───────────────┤
│           OfflineStore / KvCache                 │  Persistence & caching
├─────────────────────────────────────────────────┤
│         SQLiteStorageProvider / Memory           │  Storage backends
├─────────────────────────────────────────────────┤
│  YSwift (fork) ─► Yniffi ─► Yrs (Rust FFI)     │  CRDT engine
└─────────────────────────────────────────────────┘
```

## Module Map

### `JsBaoClient.swift` — Coordination Hub

The main class wires everything together and exposes the public API. It owns instances of every internal component and forwards calls to them. All sub-APIs (`documents`, `databases`, `llm`, `me`, etc.) are lazy properties that share the underlying `HttpClient`.

### `Internal/`

| File | Responsibility |
|------|----------------|
| `AuthController.swift` | JWT lifecycle, token refresh with exponential backoff, OAuth/magic-link/OTP flows, optional JWT persistence to SQLite |
| `DocumentManager.swift` | Document open/close, Yjs sync protocol (syncStep1 → syncStep2 → syncComplete → streaming updates), persistence via `YjsSQLitePersistence`, pending-create queue |
| `WebSocketManager.swift` | `URLSessionWebSocketTask` connection, reconnection with exponential backoff (200ms base, capped at `maxReconnectDelay`), auth challenge detection (401/403 aborts reconnect) |
| `HttpClient.swift` | `URLSession`-based REST client, automatic 401 → token refresh retry, JSON serialization |
| `BlobManager.swift` | Upload queue with configurable concurrency, SHA256 integrity, in-memory cache for recent downloads |
| `OfflineStore.swift` | Domain-scoped storage (meta, grants, analytics, auth, kv) namespaced per `appId:userId` |
| `KvCache.swift` | In-memory + persistent cache with TTL, deduplicates in-flight network requests for the same key |
| `AnalyticsQueue.swift` | Persists events to SQLite while offline, flushes on reconnect |
| `Logger.swift` | Leveled logger (debug/info/warn/error) |

### `API/`

Thin REST wrappers over `HttpClient`. Each file corresponds to a server resource:

`CollectionsAPI`, `DatabasesAPI`, `DocumentsAPI`, `GeminiAPI`, `GroupsAPI`, `GroupTypeConfigsAPI`, `IntegrationsAPI`, `LlmAPI`, `MeAPI`, `PromptsAPI`, `RuleSetsAPI`, `SessionAPI`, `UsersAPI`

### `Storage/`

| File | Description |
|------|-------------|
| `StorageProvider.swift` | Protocol: `put`, `get`, `delete`, `putBatch`, `iterate` — generic over `Codable` values |
| `SQLiteStorageProvider.swift` | WAL-mode SQLite via C API, single `kv_store` table with compound key `(store, key)`, `DispatchQueue`-serialized writes |
| `MemoryStorageProvider.swift` | In-memory dictionary, useful for tests |

### `Query/`

| File | Description |
|------|-------------|
| `BaoModelQueryEngine.swift` | In-memory SQLite mirror of Y.Map model data for relational queries. **Kept incrementally consistent** via the observer hooks installed by `DynamicModel` (see Schema/ below) — local writes mutate the SQLite mirror inline; remote writes flow in via the root-map + per-record observer pipeline. The dirty-flag rebuild path is a fallback (e.g., engine attach for an already-populated doc), not the steady-state strategy. See [`parity/query-engine.md`](parity/query-engine.md) for operator-by-operator parity. |
| `QueryTranslator.swift` | Converts MongoDB-style `DocumentFilter` dictionaries into SQL `WHERE` clauses with parameterized bindings |
| `DocumentFilter.swift` | Filter types and operators (`$eq`, `$gt`, `$in`, `$containsText`, `$or`, etc.) |

### `Types/`

| File | Description |
|------|-------------|
| `Options.swift` | `JsBaoClientOptions`, `AuthConfig`, `SyncConfig`, `StorageConfig`, `OpenDocumentOptions`, etc. |
| `Events.swift` | `JsBaoEvent` enum + typed payload structs (`SyncEvent`, `AuthStateEvent`, `StatusChangedEvent`, …) |
| `Errors.swift` | `JsBaoError` / `AuthError` / `HttpError` — error codes match the JS client for cross-platform consistency |
| `EventEmitter.swift` | Generic typed event bus with `.on()`, `.off()`, `.onAny()`, `waitForEvent()` |

## Concurrency Model

The client uses Swift's structured concurrency (`async/await`, `Task`) but does **not** use actors. Instead, shared mutable state is protected by `NSLock`, and types are marked `@unchecked Sendable`. This was a deliberate choice to avoid the rigidity of actor isolation while the API surface was still evolving.

Key concurrency patterns:

- **WebSocketManager**: `NSLock` guards the state machine; strict identity checks prevent callbacks from stale `URLSession` instances
- **SQLiteStorageProvider**: A serial `DispatchQueue` serializes all database access
- **DocumentManager**: Lock-protected dictionaries for open documents and sync state
- **Task-based timers**: Reconnect delays and retry backoff use `Task.sleep` with cancellation

### YDocument transactions: the non-reentrant lock rule

There is **one concurrency footgun** worth knowing about up front, because it doesn't surface as an exception or a test failure — it surfaces as a hung thread with no diagnostic.

yrs (the Rust CRDT under yswift) protects each `Doc` with a non-reentrant `RwLock`. The doc-level factory methods on `YDocument` — `getOrCreateText/Array/Map(named:)` — internally call `transact_mut()` to take that lock. **Calling them from inside an already-open `transactSync { ... }` closure on the same thread deadlocks the calling thread against itself.**

```swift
// ⚠️ DEADLOCKS — hung thread, no error
doc.transactSync { txn in
    let map = doc.getOrCreateMap(named: "myData")  // ← hangs forever here
    map.updateValue("v", forKey: "k", transaction: txn)
}

// ✅ Safe — use the transaction-aware variant
doc.transactSync { txn in
    let map: YMap<String> = doc.getOrInsertMap(named: "myData", transaction: txn)
    map.updateValue("v", forKey: "k", transaction: txn)
}
```

**Rules of thumb:**
- **Inside a `transactSync` closure:** use `doc.getOrInsertText/Array/Map(named:transaction:)`. These take an explicit transaction and route through the held `TransactionMut`, sidestepping the lock.
- **Outside any transaction (e.g. cached at object init time):** the doc-level `getOrCreateText/Array/Map(named:)` are fine.
- **Most code shouldn't deal with raw Y.Maps at all** — use [`TypedModel<T>` / `DynamicModel`](baomodels.md), which handles this rule internally so you never have to think about it.

Full technical history, the rebuild procedure for the yswift fork, and the regression tests are in [yswift-fork.md](yswift-fork.md#transaction-aware-get-or-insert-deadlock-fix).

## Yjs Sync Protocol

The sync flow between client and server follows the standard Yjs protocol:

```
Client                          Server
  │                               │
  │──── connect (WebSocket) ────►│
  │                               │
  │◄──── hello (connectionId) ───│
  │                               │
  │  For each open document:      │
  │──── syncStep1 (stateVector) ►│
  │                               │
  │◄── syncStep2 (stateVector    │
  │     + missing updates)       │
  │                               │
  │──── syncStep2 (our missing   │
  │     updates for server)     ►│
  │                               │
  │◄──── syncComplete ───────────│
  │                               │
  │◄───► update (bidirectional)  │  Ongoing — debounced outbound (50ms default)
  │                               │
  │◄───► awareness ──────────────│  Presence / cursor state
```

Local writes are detected via `YDocument.observeUpdate()` (our yswift fork addition — see [yswift-fork.md](yswift-fork.md)). The observer fires after every Yjs transaction with the raw update bytes, which `DocumentManager` debounces and sends over the WebSocket.

## Authentication Flow

```
1. Client initialized with JWT (or loads persisted JWT from SQLite)
2. JWT attached as Bearer token to HTTP requests and WS handshake
3. On 401 response → AuthController attempts token refresh:
   a. Direct: POST /auth/refresh
   b. Proxy: delegates to external refresh service (cookie-based)
4. Exponential backoff on refresh failure (base 2s, max 300s)
5. Events emitted: authSuccess, authFailed, authState, authRefreshDeferred
```

Additional auth methods: OAuth (`startOAuthFlow` / `handleOAuthCallback`), Magic Link (`magicLinkRequest` / `magicLinkVerify`), OTP (`otpRequest` / `otpVerify`).

## Offline-First Design

When `offline: true` (the default):

1. **Open document** → load from SQLite first, then sync from server
2. **Write locally** → persisted to SQLite immediately, queued for server sync
3. **Go offline** → writes continue locally, accumulate in SQLite
4. **Reconnect** → full Yjs sync merges local and remote state (CRDT, no conflicts)
5. **Pending creates** → documents created offline are queued and committed on reconnect with retry backoff

The `OfflineStore` maintains metadata, permissions, and analytics across sessions. The `KvCache` deduplicates concurrent network requests and serves stale data while refreshing in the background.
