# Primitive Swift Client (`JsBaoClient`)

A native Swift SDK for the [Primitive](https://primitive.dev) collaboration platform. Provides real-time document editing via Yjs CRDTs, offline-first persistence, authentication, blob management, and a full REST API surface — all designed for iOS 16+ and macOS 13+.

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](architecture.md) | High-level design, module map, concurrency model |
| [Differences from JS Client](js-client-comparison.md) | What changed, what's missing, what's new |
| [The YSwift Fork](yswift-fork.md) | Why we fork yswift, what we patched, how to rebuild |
| [Collections & Queries](collections-and-queries.md) | Typed Y.Map collections with SQLite-backed query engine |
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
doc.transactSync { txn in
    let map = doc.getMap(named: "myData", transaction: txn)
    map.insert(key: "hello", value: "world", transaction: txn)
}

// Listen for events
client.events.on(.sync) { (event: SyncEvent) in
    print("Document \(event.documentId) synced: \(event.synced)")
}
```

## Package Structure

```
swift-client/
├── Package.swift              # SPM manifest — links sqlite3, depends on yswift-fork
├── Sources/JsBaoClient/
│   ├── JsBaoClient.swift      # Main client class (public API hub)
│   ├── Collection.swift       # CollectionRecord protocol + typed Y.Map access
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
