# Architecture

> This document covers the *internals* of the Swift client — how the layers fit together. Parity is a separate concern.

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
| `WebSocketManager.swift` | `URLSessionWebSocketTask` connection, reconnection with exponential backoff (200ms base, capped at `maxReconnectDelay`), auth challenge detection (401/403 aborts reconnect). An `actor` behind an ordered delegate-event channel — see Concurrency Model below |
| `WebSocketTransportBoxes.swift` | The two `nonisolated` boxes that survive that conversion: the transport snapshot the synchronous reads serve from, and the weak delegate the client wires at construction |
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
| `BaoModelQueryEngine.swift` | In-memory SQLite mirror of Y.Map model data for relational queries. **Kept incrementally consistent** via the observer hooks installed by `DynamicModel` (see Schema/ below) — local writes mutate the SQLite mirror inline; remote writes flow in via the root-map + per-record observer pipeline. The dirty-flag rebuild path is a fallback (e.g., engine attach for an already-populated doc), not the steady-state strategy.  |
| `QueryTranslator.swift` | Converts MongoDB-style `DocumentFilter` dictionaries into SQL `WHERE` clauses with parameterized bindings |
| `DocumentFilter.swift` | Filter types and operators (`$eq`, `$gt`, `$in`, `$containsText`, `$or`, etc.) |

### `Types/`

| File | Description |
|------|-------------|
| `Options.swift` | `JsBaoClientOptions`, `AuthConfig`, `SyncConfig`, `StorageConfig`, `OpenDocumentOptions`, etc. |
| `Events.swift` | `JsBaoEvent` enum + typed payload structs (`SyncEvent`, `AuthStateEvent`, `StatusChangedEvent`, …) |
| `JsBaoEventPayload.swift` | The payload/event association (`JsBaoEventPayload.eventKey`), the nine payload types converted from dictionaries, and the conformance table the drift guards read |
| `Errors.swift` | `JsBaoError` / `AuthError` / `HttpError` — error codes match the JS client for cross-platform consistency |
| `EventEmitter.swift` | The event registry. Serves `AsyncStream` consumers (`client.stream(for:)`, `observeOnMainActor`, `nextEvent`) and the deprecated `on` / `onAny` callback shim from one `emit`, so both keep their delivery contracts |

## Concurrency Model

The client uses Swift's structured concurrency (`async/await`, `Task`) and is split into **two domains** with different isolation models. Which domain a type belongs to is a decision, not an accident — do not move a type across the line without going through the concurrency epic (#1993).

### The async domain — actors

The service managers that own async work are Swift `actor`s. Their state is actor-isolated and every value crossing the boundary is `Sendable` (in practice `JSONValue`, never `Any`). They carry no `Sendable` opt-out, and no lock — with exactly **two** enumerated exceptions, both belonging to `WebSocketManager` and both argued below: the transport snapshot and the weak delegate box (`Internal/WebSocketTransportBoxes.swift`).

| Actor | Owns |
|---|---|
| `OfflineStore` | Storage-provider wiring, the offline metadata DB, the persisted analytics queue |
| `KvCache` | The two-tier cache, the in-flight fetch dedup table |
| `AnalyticsQueue` | The event buffer, the batch flush timer, transmission |
| `BlobManager` | The upload queue, the in-memory blob cache, the upload-concurrency setting, the single coalesced queue timer |
| `WebSocketManager` | The socket and its session, the connect/disconnect state machine and waiter lists, the reconnect backoff and disconnect-timeout timers, the ordered delegate-event channel |

`AuthController` (#2173) is queued for the same treatment and is class-plus-lock today. `WebSocketManager` depends on it staying that way: its delegate methods are synchronous, so `connect()`'s decision region reads the access token without suspending.

#### `WebSocketManager`'s ordered delegate-event channel

`URLSession` delivers its callbacks on a serial delegate queue, so a class could take their ordering for granted. An actor cannot: a `nonisolated` callback that hops onto the actor gets no ordering guarantee against another, and an `open` overtaking a `close` would leave the state machine believing a dead socket is live.

**Invariant: every lifecycle signal that originates outside isolation enters through the channel, and nothing else does.** One `nonisolated let events: AsyncStream<DelegateEvent>` with an `.unbounded` buffering policy, and a single actor-isolated pump task as its only consumer. `AsyncStream` continuations are FIFO and there is one consumer, so ordering is preserved *by construction*. Three consequences:

- The buffer is unbounded on purpose. A bounded policy that discarded an `open` or a `close` would desynchronize the state machine permanently. It needs none of `EventEmitter`'s high-water metering: there is one producer pair and events fire once per connection-lifecycle transition, never per message.
- The `nonisolated` callbacks cannot read `task`, so they filter nothing — they carry the task's `ObjectIdentifier` and the pump drops stale events, in the same isolated step as the state it guards.
- `handleConnectionClosed` has exactly one caller: the pump. The receive loop's *message* path deliberately stays off the channel, because `webSocketManagerOnMessage` is `async` and routing messages through the pump would put an `await` inside the ordering region.

The pump is also the reason `WebSocketManager` is the one actor whose `deinit` matters: it runs for as long as the stream is live, so it captures `self` weakly. A strong capture would retain the actor forever, `deinit` would never run, and the `URLSession` would never be invalidated.

#### `WebSocketManager`'s two surviving locks

Both are `nonisolated` boxes in `Internal/WebSocketTransportBoxes.swift`, kept out of the manager's own file so that file stays provably lock-free.

**The transport snapshot** serves the four synchronous reads — `isConnected`, `isConnecting`, `connectionStatus`, `isSocketOpen` — which stay synchronous permanently (sponsor, 2026-08-02). Written only from inside the actor on each transition, read from anywhere. It holds no continuation, no queue and no ordering state, `connected` and `connecting` are written together so `status` can never report them inconsistently, and it stores the `URLSessionWebSocketTask` reference rather than a cached `Bool` so `isSocketOpen` keeps reading the socket's live `state`.

This is **not** the "second source of truth" the `BlobManager` rationale above rejects, and the difference is worth stating because the two paragraphs sit next to each other. `BlobManager`'s removed reads returned a *result about a queue mutation* — a synchronous `pauseUpload` would have had to answer `Bool` about something that had not happened yet, and a snapshot of queue contents would be a second copy of state the actor owns and mutates on its own schedule. The WebSocket box holds connection-*status* reads with exactly the consistency property the class provided: the class also released its lock before calling the delegate, so a read taken during a transition already observed the pre-transition value for one step. Nothing is duplicated — the box *is* the storage those three fields live in, and the actor reads and writes them through it, so there is no second copy to drift. What survives is the lock, not the source of truth.

**The weak delegate box** exists because `JsBaoClient.setupDependencies()` is synchronous and called from `init`: `wsManager.delegate = self` must land before `init` returns or the manager is briefly live with no delegate. The construction-time injection `KvCache` and `AnalyticsQueue` use does not apply, because the delegate *is* the client and cannot be captured before its own `init` completes.

`BlobManager` is the one actor here with substantial `nonisolated` surface, and it is worth knowing why. All of the following are `nonisolated`:

- the network transfers — `uploadImmediate`, `uploadFromSource`, `read`, `prefetch`;
- the queue driver — `processQueue`, `runUploadTask`, and the `makeQueueTimer` task factory;
- the public queue mutators — `pauseUpload`, `resumeUpload`, `pauseAll`, `resumeAll`, `cancelQueuedUpload` — each of which does its isolated bookkeeping in a named isolated step and then emits from outside it;
- every emit helper, plus `downloadUrl`, `computeBackoff` and the pure statics.

Only the queue bookkeeping is isolated: the isolated steps those verbs call (`markUploadPaused`, `markAllResumed`, `selectDueTasks`, `enqueue`, `claimQueueTimer`, `recordUploadFailure` and their siblings), plus the reads and setters over `uploadQueue`, `memoryBlobs`, `uploadConcurrency` and the queue-timer fields. That is what keeps concurrent uploads concurrent, keeps a slow event subscriber off the actor, and lets `downloadUrl` stay synchronous for SwiftUI. Its removed synchronous *reads* and result-returning mutators use a second shape beside the twins: an `@available(*, unavailable, renamed:)` stub, so the compiler offers a rename fix-it rather than "no such member" — a snapshot-backed synchronous read would be a second source of truth, and a synchronous `pauseUpload` would return a `Bool` about a mutation that had not happened yet.

Because an actor's members are isolated, a synchronous public member cannot survive a conversion unchanged. The policy for that is **additive `Async` twins plus a one-release deprecation**: the synchronous original stays, marked `@available(*, deprecated)`, beside a distinctly-named `…Async` twin that does the work on the caller's task. The twin is deliberately *not* a same-name `async` overload — Swift prefers the `async` overload in an asynchronous context, so a same-name twin turns every existing un-`await`ed call into a compile error, which is the break the window exists to avoid.

### The sync domain — class plus lock, permanently

The synchronous core keeps `NSLock` and `@unchecked Sendable` **by design**, not as debt: `YDocument` behind the yrs FFI lock, the in-process model store (`DynamicModel`, `MultiDocModel`, `BaoModelQueryEngine`), the generated synchronous reads, and the `JsBaoClient` facade itself, whose public surface has synchronous members. There is no plan to actorize any of them.

A handful of types sit next to that core and are also permanently class-plus-lock — `DatabaseSubscriptionRegistry` is the clearest case: it does no I/O, has no `await` anywhere, and an actor would cost `databases.subscribe(...)` its synchronous shape while buying nothing.

Key patterns in this domain:

- **SQLiteStorageProvider**: A serial `DispatchQueue` serializes all database access
- **DocumentManager**: Lock-protected dictionaries for open documents and sync state
- **Task-based timers**: Reconnect delays and retry backoff use `Task.sleep` with cancellation

### Review invariants

Two rules carry the correctness the compiler cannot check. Both are worth stopping a review over.

**1. Every `@unchecked Sendable` carries a written safety argument.** The attribute is a claim the compiler does not verify, so the acceptance bar is a doc comment above the declaration that names the specific locks and says which fields they confine, plus any documented exception (`deinit` is the usual one). `SendableModelLayerTests` and `SyncAdjacentBoundaryTypesTests` read the source text and fail if an argument is missing or stops naming its locks — a bare `@unchecked Sendable` cannot be added quietly.

**2. No `await` inside a decision block.** A region that reads state, decides from it, and then commits the decision — check-and-register, check-and-schedule, claim-then-act — must contain no suspension point. Under a lock this came free: one `withLock` was atomic. Under an actor it does **not**: actor isolation is *reentrant*, so an `await` in the middle lets another call interleave between the check and the commit and both callers take the same decision. This is precisely the class of race the actor conversion is supposed to remove, so it is the class most easily reintroduced.

The pattern that keeps the region await-free is to move the body being registered into its own factory method, so constructing the value needs no suspension:

```swift
// ✅ the decision region has no `await` in it
func fetch(key: String) async throws -> JSONValue {
    if let inflight = inflightRequests[key] { return try await inflight.value }  // decide
    let task = makeFetchTask(key: key)                                          // build, no await
    inflightRequests[key] = task                                                // commit
    return try await task.value                                                 // await, after
}
```

`KvCache.fetchCachedValue`, `AnalyticsQueue.scheduleFlush`, `BlobManager`'s three regions (`scheduleQueueProcessing`, `selectDueTasks`, `recordUploadFailure`) and `WebSocketManager`'s three (`connectDecision`, `disconnectDecision`, and the pump's `handle(_:)` — which is non-`async`, so the compiler enforces it) are the live examples, and each is pinned by a structural test that slices the region out of the comment-stripped source and asserts it contains no `await`. Write the same kind of test for any new decision region.

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
