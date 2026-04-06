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

If you modify the Rust FFI code in `yswift-fork/lib/`:

```bash
cd swift-client/yswift-fork/lib

# Build for macOS (arm64)
cargo build --target aarch64-apple-darwin --release

# Copy the built library into the xcframework
cp target/aarch64-apple-darwin/release/libuniffi_yniffi.a \
   yniffiFFI.xcframework/macos-arm64_x86_64/
```

For iOS targets you'd need additional `cargo build` invocations with the appropriate Apple target triples (`aarch64-apple-ios`, `aarch64-apple-ios-sim`, etc.) and then update the xcframework accordingly.

## Keeping Up with Upstream

The fork is based on yswift 0.5.x. If upstream yswift adds `observeUpdateV1` natively (or the y-crdt team ships it in a new release), we can drop the fork and point `Package.swift` at the official package. Until then, track upstream changes manually and cherry-pick as needed.

The key files to watch in upstream:
- `Sources/YSwift/YDocument.swift` — if they add `observeUpdate`, we can migrate
- `lib/` (Rust source) — if the UniFFI scaffold changes, our patches may need rebasing
