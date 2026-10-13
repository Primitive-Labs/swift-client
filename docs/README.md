# Primitive Swift Client (`JsBaoClient`)

A native Swift SDK for the [Primitive](https://primitive.dev) collaboration platform. Real-time document editing via Yjs CRDTs, offline-first persistence, authentication, blob management, and a full REST API surface — designed for iOS 16+ and macOS 13+.

**Toolchain floor: Swift 6.1 (Xcode 16.3) or newer.** `Package.swift` declares `swift-tools-version: 6.1`, so an older toolchain cannot resolve the package at all. The manifest went from 6.0 to 6.1 in #2966: `Target.directoryURL` is the only non-deprecated way for the codegen plugin to read a consuming target's source directory, and SwiftPM compiles that plugin inside every package that uses it, so the 6.0 spelling printed a deprecation warning on every consumer build.

This directory is the navigation guide for everything in `swift-client/`. Start here.

## Where to look

### "I'm trying to figure out if a JS client feature exists on Swift"

Known divergences from the JS client are tracked as GitHub issues (label `swift-client-parity`). The standing policy lives in the Parity policy section below.

### "I'm writing Swift code that uses JsBaoClient"

- [`overview.md`](overview.md) — orientation: what is this client, layer diagram, key types
- [`baomodels.md`](baomodels.md) — typed model authoring guide (`PrimitiveModel`, `TypedModel<T>`, `DynamicModel`)
- [`record-log.md`](record-log.md) — record-log documents (`documentFormat: 3`): the store, refusals, upserts, `confirm`, `syncState`, `transact`
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
├── record-log.md                     ← record-log documents (documentFormat: 3)
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

// Listen for events. The payload type names its own event, so there is no
// separate event argument to get wrong.
for await event in client.stream(for: SyncEvent.self) {
    print("Document \(event.documentId) synced: \(event.synced)")
}

// For a callback instead of a loop — an ObservableObject wiring itself up, say
// — `observeOnMainActor` runs the handler on the main actor. Hold the returned
// EventSubscription for as long as you want the handler live.
syncSubscription = client.observeOnMainActor(SyncEvent.self) { event in
    print("Document \(event.documentId) synced: \(event.synced)")
}

// For one occurrence: `try await client.nextEvent(SyncEvent.self, timeout: 30)`.
```

## Status

This client is at **v1**. All 19 JS sub-APIs exist on Swift with matching method sets; remaining behavioral divergences are tracked as GitHub issues (label `swift-client-parity`).

## The event surface

Events are delivered through typed payloads only. Each payload type names the
one event key it is delivered under, so there is no separate event argument to
get wrong:

- `client.stream(for:buffering:replayingLatest:)` — an `AsyncStream` of one
  payload type, for `for await` loops.
- `client.observeOnMainActor(_:handler:)` — a callback on the main actor. Hold
  the returned `EventSubscription` for as long as the handler should stay live.
- `client.nextEvent(_:timeout:where:)` — one occurrence, awaited.

What is no longer there:

- The untyped surface — `client.events`, `on`, `onAny`, `emit(_:_:)` and the
  free `waitForEvent(emitter:...)` — was removed in #2367. The "batched
  breaking API cleanup (#2367)" entry in `../CHANGELOG.md` has the
  symbol-by-symbol replacement table.
- Every payload is a typed struct; there is no `[String: Any]` handler shape.
  The nine events that used to be bare dictionaries (`meUpdated`,
  `pendingCreateFailed`, `authRefreshDeferred`, the five `offlineAuth*` events
  and `blobsQueueDrained`) are typed payloads.
- The `.invitation` event and its `InvitationEvent` payload were removed in
  #2951, with the per-document invitation routes that were its only emitter.
  There is no replacement push event — the sharing system grants access
  immediately, so a subscriber has nothing left to wait for.

## Parity policy

The JS client (`src/client/`) and js-bao (`packages/js-bao/`) are the **source of truth**. The Swift client matches their names, shapes, and semantics:

1. **Don't add Swift-only public surface.** If a capability needs a new API, it lands on JS first (or simultaneously), then Swift mirrors it. If JS removes an API, the Swift gap auto-closes — don't implement it.
2. Anything touching **field encoding/decoding** (`DynamicModel`, `PrimitiveValue`), **TOML validation** (`TomlSchemaLoader`), or **operator translation** (`QueryTranslator`) must be checked against `packages/js-bao/src/` and pinned with a cross-platform test in `Tests/JsBaoClientTests/CrossPlatform/`. Ask: "does the JS side write the same bytes here?" A Swift write that JS can't decode is a P0.
3. New events, error codes, and TOML attributes land on **both sides in the same change**, with the shape decided together.
4. Known divergences are tracked as GitHub issues labeled `swift-client-parity` — file one when you find a new divergence, close it when the behavior converges. There is no parity doc to keep in sync; the issues and the cross-platform tests are the record.
