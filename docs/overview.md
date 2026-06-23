# Overview

A 5-minute orientation for someone landing on the Swift client for the first time.

## What this is

A native Swift SDK that gives an iOS or macOS app the same capabilities the JS client gives a web app:

- **Real-time collaborative documents** via Yjs CRDTs
- **Typed records** stored in those documents, with MongoDB-style queries against an in-memory SQLite mirror
- **Offline-first persistence** so writes don't get lost without a connection
- **Authentication** (JWT + refresh, OAuth, magic-link, OTP)
- **Blob storage** (images, files) per-document
- **REST API surface** for everything else (workflows, LLM, prompts, groups, etc.)

It runs on iOS 16+ and macOS 13+. It doesn't run on Linux/Windows — Apple-platform only.

## Layer diagram

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
│  YSwift (fork) ─► Yniffi ─► Yrs (Rust FFI)      │  CRDT engine
└─────────────────────────────────────────────────┘
```

Each layer is independently usable in tests. The [architecture doc](architecture.md) goes deeper.

## Key types

| Type | What it is | When to use |
|---|---|---|
| `JsBaoClient` | Top-level client. Owns connection, auth, document manager, all sub-APIs. | Always. One per "user session" in your app. |
| `YDocument` | A live Yjs document. Real-time CRDT state, observable. | Whenever you've opened a document via `client.openDocument(docId:)`. |
| `PrimitiveModel` | Protocol every typed model conforms to. Codegen produces structs that implement this from a TOML schema. | Authoring typed records. |
| `TypedModel<T: PrimitiveModel>` | Generic wrapper. CRUD and query helpers for a typed struct. | When you have a codegen-emitted struct and want type-safe access. |
| `DynamicModel` | Schemaless view of records in a doc. Same storage, weaker typing. | When the schema isn't known at compile time, or you need a method `TypedModel<T>` doesn't expose yet. |
| `PrimitiveRecord` | Stringly-typed record dictionary. What `DynamicModel` returns. | Inside `init?(record:)` (codegen-emitted), or when working with `DynamicModel`. |
| `EventEmitter` / `JsBaoEvent` | Typed event bus. `.sync`, `.connectionState`, etc. | Subscribing to lifecycle events. |
| `JsBaoError` / `JsBaoErrorCode` | Error taxonomy. 19 error codes that match JS exactly. | Catching and reasoning about failures. |

## How a request flows

A `client.documents.get(id)` call goes:

```
1. DocumentsAPI.get(id:)
2. → HttpClient.request(...)
3. → AuthController checks token, refreshes on 401, retries once
4. → URLSession sends the actual HTTP request
5. → response decoded as Codable, surfaced as a typed return
```

A `try await client.openDocument(docId:)` call goes:

```
1. DocumentManager.openDocument(...)
2. → idempotency check (already open?)
3. → YDocument constructed (yswift-fork)
4. → WebSocketManager opens / verifies connection
5. → Sync protocol: syncStep1 → syncStep2 → syncComplete
6. → SQLite persistence catches up
7. → Doc returned, ready for writes
```

A `model.query(filter)` call goes:

```
1. TypedModel<T>.query(...)
2. → DynamicModel.query(...)
3. → BaoModelQueryEngine.query(...)
4. → QueryTranslator translates filter to SQL
5. → SQLite mirror executes
6. → rows hydrated back to T via T.init?(record:)
7. → returns [T]
```

## What you should read next

- **Authoring typed records:** [`baomodels.md`](baomodels.md)
- **Internal architecture:** [`architecture.md`](architecture.md)
- **What does the JS client do that this doesn't?:** open GitHub issues labeled `swift-client-parity`
- **Cross-platform wire format:** `Tests/JsBaoClientTests/CrossPlatform/` (the tests are the spec)
