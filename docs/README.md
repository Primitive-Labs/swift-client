# Primitive Swift Client (`JsBaoClient`)

A native Swift SDK for the [Primitive](https://primitive.dev) collaboration platform. Real-time document editing via Yjs CRDTs, offline-first persistence, authentication, blob management, and a full REST API surface — designed for iOS 16+ and macOS 13+.

This directory is the navigation guide for everything in `swift-client/`. Start here.

## Where to look

### "I'm trying to figure out if a JS client feature exists on Swift"

Go to [`parity/`](parity/). It's the canonical reference. The big chart is [`parity/api-methods.md`](parity/api-methods.md). For "why is X not here?", see [`exclusions-v1.md`](exclusions-v1.md).

### "I'm writing Swift code that uses JsBaoClient"

- [`overview.md`](overview.md) — orientation: what is this client, layer diagram, key types
- [`baomodels.md`](baomodels.md) — typed model authoring guide (`PrimitiveModel`, `TypedModel<T>`, `DynamicModel`)
- [`architecture.md`](architecture.md) — how internals fit together

### "I'm contributing to the Swift client"

- [`testing.md`](testing.md) — running tests against a live server
- [`yswift-fork.md`](yswift-fork.md) — why we fork yswift, what we patched
- [`parity/`](parity/) — what to maintain alignment with on the JS side

## Documentation map

```
docs/
├── README.md                         ← you are here
├── overview.md                       ← layer diagram, key types, quick start
├── architecture.md                   ← module map, concurrency model
├── baomodels.md                      ← typed model authoring
├── testing.md                        ← running the suite
├── yswift-fork.md                    ← CRDT layer fork rationale
├── exclusions-v1.md                  ← what's deliberately out of v1
└── parity/                           ← canonical reference for JS-client parity
    ├── README.md                     ← legend + index
    ├── api-methods.md                ← per-sub-API method tables
    ├── schema-and-models.md          ← field types, validation, relationships
    ├── query-engine.md               ← operators, sort, cursor
    ├── wire-format.md                ← byte-level invariants, divergences
    ├── events.md                     ← event-name table
    ├── errors.md                     ← error-code taxonomy
    └── test-coverage.md              ← Swift tests ↔ JS tests
```

## Quick start

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

// Most apps work through TypedModel<T> + codegen — define your schema in
// schema.toml, let swift-bao-codegen emit the record struct, then go through
// the typed wrapper:
//
//     let tasks = TypedModel<TaskRecord>(doc: doc)
//     try tasks.create(TaskRecord(id: "t1", title: "Write docs"))
//     for t in tasks.findAll() { print(t.title) }
//
// See baomodels.md (typed model authoring) and codegen.md (the schema.toml +
// build-plugin flow) for the full story. The legacy untyped BaoModel<T> API
// from earlier releases still ships, but new apps should start with TypedModel.

// For raw Y.Map access (e.g. text editors), use the YDocument API directly.
// IMPORTANT: inside an open transaction, use getOrInsertMap(named:transaction:),
// NOT the doc-level getOrCreateMap(named:). The latter re-acquires the
// underlying yrs lock and deadlocks the calling thread. See yswift-fork.md.
doc.transactSync { txn in
    let map: YMap<String> = doc.getOrInsertMap(named: "myData", transaction: txn)
    map.updateValue("world", forKey: "hello", transaction: txn)
}

// Listen for events
client.events.on(.sync) { (event: SyncEvent) in
    print("Document \(event.documentId) synced: \(event.synced)")
}
```

## Status

This client is at **v1**. It implements 14 of the 17 JS sub-APIs and most of the typed-model layer. See [`parity/api-methods.md`](parity/api-methods.md) for the full mapping and [`exclusions-v1.md`](exclusions-v1.md) for what's deliberately out of v1.
