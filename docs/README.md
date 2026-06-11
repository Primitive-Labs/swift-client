# Primitive Swift Client (`JsBaoClient`)

A native Swift SDK for the [Primitive](https://primitive.dev) collaboration platform. Real-time document editing via Yjs CRDTs, offline-first persistence, authentication, blob management, and a full REST API surface — designed for iOS 16+ and macOS 13+.

This directory is the navigation guide for everything in `swift-client/`. Start here.

## Where to look

### "I'm trying to figure out if a JS client feature exists on Swift"

Known divergences from the JS client are tracked as GitHub issues (label `swift-client-parity`). The standing policy lives in the Parity policy section below.

### "I'm writing Swift code that uses JsBaoClient"

- [`overview.md`](overview.md) — orientation: what is this client, layer diagram, key types
- [`baomodels.md`](baomodels.md) — typed model authoring guide (`PrimitiveModel`, `TypedModel<T>`, `DynamicModel`)
- [`architecture.md`](architecture.md) — how internals fit together

### "I'm contributing to the Swift client"

- [`testing.md`](testing.md) — running tests against a live server
- [`yswift-fork.md`](yswift-fork.md) — why we fork yswift, what we patched
- Parity policy (below) — what to maintain alignment with on the JS side

## Documentation map

```
docs/
├── README.md                         ← you are here
├── overview.md                       ← layer diagram, key types, quick start
├── architecture.md                   ← module map, concurrency model
├── baomodels.md                      ← typed model authoring
├── testing.md                        ← running the suite
└── yswift-fork.md                    ← CRDT layer fork rationale
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

This client is at **v1**. All 19 JS sub-APIs exist on Swift with matching method sets; remaining behavioral divergences are tracked as GitHub issues (label `swift-client-parity`).

## Parity policy

The JS client (`src/client/`) and js-bao (`packages/js-bao/`) are the **source of truth**. The Swift client matches their names, shapes, and semantics:

1. **Don't add Swift-only public surface.** If a capability needs a new API, it lands on JS first (or simultaneously), then Swift mirrors it. If JS removes an API, the Swift gap auto-closes — don't implement it.
2. Anything touching **field encoding/decoding** (`DynamicModel`, `PrimitiveValue`), **TOML validation** (`TomlSchemaLoader`), or **operator translation** (`QueryTranslator`) must be checked against `packages/js-bao/src/` and pinned with a cross-platform test in `Tests/JsBaoClientTests/CrossPlatform/`. Ask: "does the JS side write the same bytes here?" A Swift write that JS can't decode is a P0.
3. New events, error codes, and TOML attributes land on **both sides in the same change**, with the shape decided together.
4. Known divergences are tracked as GitHub issues labeled `swift-client-parity` — file one when you find a new divergence, close it when the behavior converges. There is no parity doc to keep in sync; the issues and the cross-platform tests are the record.
