# The YSwift Fork

## Why We Fork

The Swift client depends on [YSwift](https://github.com/y-crdt/yswift) — Swift bindings for [Yrs](https://github.com/y-crdt/y-crdt), the Rust implementation of the Yjs CRDT. The upstream release (0.5.3) is missing a critical feature: **document-level update observers**.

In the JS world, Yjs exposes `doc.on("update", callback)` which fires after every transaction with the raw update bytes. This is how the JS client knows when to send changes to the server — it observes the document and forwards new updates over WebSocket.

Upstream YSwift only exposed observers for individual types (YMap, YArray, YText), not for the document as a whole. Without a document-level observer, the Swift client would need to either:

1. Observe every individual type separately (fragile, misses dynamically created types), or
2. Wrap every write in a custom `transactAndSync()` method (bad DX, easy to forget)

Neither is acceptable, so we added `observeUpdateV1` to the fork.

## What We Changed

### Rust FFI Layer (`lib/`)

- Added `YrsUpdateEvent` struct — wraps the raw update bytes
- Added `YrsUpdateObservationDelegate` trait — callback interface for the FFI boundary
- Added `observeUpdateV1()` method on `YrsDoc` — registers an observer that fires after each transaction

### Swift Bindings (`Sources/YSwift/`)

- Added `YUpdateObservationDelegateWrapper` — bridges the Rust delegate trait to a Swift closure
- Added `YDocument.observeUpdate(_ body: @escaping ([UInt8]) -> Void) -> YSubscription` — closure-based API
- Added `YDocument.observeUpdate() -> AnyPublisher<[UInt8], Never>` — Combine publisher variant

### Transaction-Aware Get-or-Insert (Deadlock Fix)

#### The bug

yrs (the Rust CRDT under yswift) protects each `Doc` with a non-reentrant `RwLock`. The doc-level factory methods on `YDocument` — `getOrCreateText/Array/Map(named:)` — internally call `transact_mut()` to take that write lock. **If you call them from inside a transaction that's already open on the same thread**, the lock acquisition deadlocks the calling thread against itself.

This is a port-fidelity gap with Yjs: the JS reference has no lock at all (single-threaded event loop), so `doc.getMap()` from inside a transaction is fine. yswift inherited the JS API surface but the yrs lock model — the two don't compose, and the result is a footgun that hangs the calling thread silently with no error message.

The original repro was the most natural pattern in the world:

```swift
// ⚠️ DEADLOCKS — do not do this
doc.transactSync { txn in
    let map = doc.document.getMap(name: "liveDemo")  // ← hangs forever here
    return map.get(tx: txn, key: "note")
}
```

#### The fix

Added three new methods on `YrsTransaction` that route get-or-create through the **already-held** `TransactionMut` instead of going back to the doc to take a fresh lock. They're surfaced on `YDocument` as transaction-taking factory methods:

```swift
public func getOrInsertText(named: String, transaction: YrsTransaction) -> YText
public func getOrInsertArray<T: Codable>(named: String, transaction: YrsTransaction) -> YArray<T>
public func getOrInsertMap<T: Codable>(named: String, transaction: YrsTransaction) -> YMap<T>
```

The safe pattern:

```swift
// ✅ Safe — works inside any open transaction
doc.transactSync { txn in
    let map: YMap<String> = doc.getOrInsertMap(named: "liveDemo", transaction: txn)
    return map.get(key: "note", transaction: txn)
}
```

These three methods take an explicit `YrsTransaction` parameter (no defaulted `nil`), so the type system makes it impossible to call them outside an open transaction — the API shape itself enforces the safe usage.

#### Rules of thumb

- **Inside a `transactSync { txn in ... }` closure:** use `getOrInsertText/Array/Map(named:transaction:)`. Never use the doc-level `getOrCreateText/Array/Map(named:)`.
- **Outside any transaction (e.g. cached at object init time):** the doc-level `getOrCreateText/Array/Map(named:)` are fine — they take a fresh lock, and there's no held lock to conflict with.
- **If you're not sure whether you're in a transaction:** prefer the transaction-aware methods. They're always correct; the doc-level ones are only sometimes correct.
- **The doc-level methods are NOT deprecated** because `BaoModel` (and other wrappers) legitimately use them at init time to cache shared-type references for performance. But the call-site rule above always applies.

The non-reentrant nature of yrs's lock means even raw `doc.document.getMap(name:)` inside a transaction will hang. **Never reach past `YDocument` into `doc.document.*` from inside a transaction** — use the `YDocument.getOrInsert*` methods instead.

#### Tests

- [`YDocumentGetOrInsertTests.swift`](../yswift-fork/Tests/YSwiftTests/YDocumentGetOrInsertTests.swift) covers the new safe API across text/array/map, idempotence, persistence across transactions, and interop with the legacy `getOrCreateMap`. It also includes a 3-second-timeout *regression marker* test that proves the old `getOrCreateMap`-inside-transaction path still deadlocks. If yrs ever ships a reentrant lock, that test will start failing — which is the signal to celebrate and delete it.
- [`YDocumentDeadlockTests.swift`](../Tests/JsBaoClientTests/YDocumentDeadlockTests.swift) (in the `JsBaoClient` test suite, not the YSwift fork) is the original repro that documented the bug. Read it for context if you ever debug a hung WebSocket client and the symptoms match.

### Additional Patches

- Fixed `YMap.get()` to work correctly with the scaffold code (the upstream binary was out of sync with the Swift source)

## How It's Wired In

The fork lives at `swift-client/yswift-fork/` and is referenced as a local SPM dependency:

```swift
// swift-client/Package.swift
dependencies: [
    .package(name: "YSwift", path: "./yswift-fork"),
]
```

The fork itself bundles a **pre-built xcframework** (`lib/yniffiFFI.xcframework`) containing the compiled Rust library. This avoids requiring a Rust toolchain to build the Swift client.

## How to Rebuild the Rust Binary

If you modify the Rust FFI code in `yswift-fork/lib/` (anything in `lib/src/*.rs` or `lib/src/yniffi.udl`), you need to rebuild the xcframework so the Swift bindings see the new symbols.

### Full rebuild (recommended — required if you change `yniffi.udl`)

The cleanest path is to run the bundled build script, which:

1. Regenerates `lib/swift/scaffold/yniffi.swift` via `uniffi-bindgen` (this is the Swift-facing surface — any UDL change requires this)
2. Builds `libuniffi_yniffi.a` for **all 5 Apple targets** (`x86_64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-apple-ios`, `aarch64-apple-darwin`, `x86_64-apple-darwin`)
3. `lipo`s the macOS and iOS-simulator slices into fat binaries
4. Repacks everything into `lib/yniffiFFI.xcframework/`

```bash
cd swift-client/yswift-fork
bash scripts/build-xcframework.sh
```

Cold builds can take 30-60 minutes (it builds yrs from source for every target). Subsequent rebuilds are much faster (~5 min) because cargo's dependency cache survives the script's `rm -rf target`.

### Quick rebuild (Mac-only, single target — DANGEROUS)

If you're only iterating on the Rust internals and just want to test on Mac arm64 quickly:

```bash
cd swift-client/yswift-fork/lib
cargo build --target aarch64-apple-darwin --release
cp target/aarch64-apple-darwin/release/libuniffi_yniffi.a \
   yniffiFFI.xcframework/macos-arm64_x86_64/
```

**⚠️ Catch:** if you also modified `yniffi.udl` or anything that changes the FFI surface, the regenerated `lib/swift/scaffold/yniffi.swift` will reference symbols that exist *only* in the macOS slice you just rebuilt. **iOS builds will then fail to link** because the iOS slice of `yniffiFFI.xcframework` still has the old `.a` without the new symbols. You'll be in a "Mac works, iOS broken" state until you run the full rebuild.

Use the quick path **only** when:
- You're iterating purely on Rust *implementation* (not the FFI surface), AND
- No iOS builds are happening in parallel.

When in doubt, use the full rebuild.

## Keeping Up with Upstream

The fork is based on yswift 0.5.x. If upstream yswift adds `observeUpdateV1` natively (or the y-crdt team ships it in a new release), we can drop the fork and point `Package.swift` at the official package. Until then, track upstream changes manually and cherry-pick as needed.

The key files to watch in upstream:
- `Sources/YSwift/YDocument.swift` — if they add `observeUpdate`, we can migrate
- `lib/` (Rust source) — if the UniFFI scaffold changes, our patches may need rebasing
