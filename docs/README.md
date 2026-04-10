# Primitive Swift Client (`JsBaoClient`)

A native Swift SDK for the [Primitive](https://primitive.dev) collaboration platform. Provides real-time document editing via Yjs CRDTs, offline-first persistence, authentication, blob management, and a full REST API surface — all designed for iOS 16+ and macOS 13+.

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](architecture.md) | High-level design, module map, concurrency model |
| [Differences from JS Client](js-client-comparison.md) | What changed, what's missing, what's new |
| [The YSwift Fork](yswift-fork.md) | Why we fork yswift, what we patched, how to rebuild |
| [BaoModels & Queries](baomodels-and-queries.md) | Typed Y.Map record models with SQLite-backed query engine |
| [Testing](testing.md) | Running integration tests against a live server |

## Quick Start

```swift
import JsBaoClient

let client = JsBaoClient(options: JsBaoClientOptions(
    apiUrl: "https://your-api.example.com",
    wsUrl: "wss://your-api.example.com",
    appId: "your-app-id",
    token: userJwt
))

try await client.connect()

// Open a document for real-time editing
let doc = try await client.openDocument(docId: documentId)

// Write to it (CRDT — merges automatically with other clients)
//
// IMPORTANT: inside an open transaction, use `getOrInsertMap(named:transaction:)`
// — NOT the doc-level `getOrCreateMap(named:)`. The latter re-acquires the
// underlying yrs lock and deadlocks the calling thread. See yswift-fork.md
// for the full story.
doc.transactSync { txn in
    let map: YMap<String> = doc.getOrInsertMap(named: "myData", transaction: txn)
    map.updateValue("world", forKey: "hello", transaction: txn)
}

// Listen for events
client.events.on(.sync) { (event: SyncEvent) in
    print("Document \(event.documentId) synced: \(event.synced)")
}
```

> **Most apps won't write to Y.Maps directly** — they'll use [`BaoModel<T>`](baomodels-and-queries.md), which gives you typed records, MongoDB-style queries, and handles the transaction-safety rules for you. The raw `YDocument` API shown above is for cases where `BaoModel` doesn't fit (e.g. text editors, custom CRDT structures).

## Package Structure

```
swift-client/
├── Package.swift              # SPM manifest — links sqlite3, depends on yswift-fork
├── Sources/JsBaoClient/
│   ├── JsBaoClient.swift      # Main client class (public API hub)
│   ├── BaoModel.swift         # BaoModelRecord protocol + typed Y.Map access
│   ├── API/                   # REST sub-APIs (documents, databases, LLM, etc.)
│   ├── Internal/              # Core internals (auth, WS, documents, blobs, cache)
│   ├── Query/                 # SQLite query engine + MongoDB-style filter translator
│   ├── Storage/               # StorageProvider protocol + SQLite/Memory backends
│   ├── Types/                 # Options, Events, Errors, EventEmitter
│   └── Utils/                 # Binary encoding helpers
├── Tests/JsBaoClientTests/    # 35+ integration test files (~5,400 lines)
├── yswift-fork/               # Patched YSwift with observe_update_v1 support
└── docs/                      # You are here
```
