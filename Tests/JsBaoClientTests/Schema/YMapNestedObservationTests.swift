import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Phase A of Work Item 2: verifies the YSwift fork's observer now
/// surfaces nested-shared-type changes (instead of silently filtering
/// them out).
///
/// Specifically, when a root Y.Map stores per-record nested Y.Maps
/// as its values, observers must fire `.insertedNested` on record
/// add and `.removedNested` on record delete. Prior to this change,
/// `mapchange.rs::try_from_entry_change` returned `None` for
/// nested-type values, so the observer delivered an empty array —
/// DynamicModel couldn't react to record add/remove without doing
/// a full doc-level diff.
final class YMapNestedObservationTests: XCTestCase {

    /// Adding a nested Y.Map under a root map fires `.insertedNested`.
    func testInsertNestedMapFiresInsertedNested() {
        let doc = YDocument()
        let root = doc.document.getMap(name: "root_a")
        let collector = Collector()
        let sub = YrsMapObserverSubscription(
            map: root,
            callback: { collector.append($0) }
        )
        defer { sub.cancel() }

        doc.transactSync { txn in
            _ = root.insertMap(tx: txn, key: "r1")
        }

        XCTAssertEqual(collector.events.count, 1)
        guard case let .insertedNested(key, kind) = collector.events.first else {
            return XCTFail("Expected .insertedNested, got \(String(describing: collector.events.first))")
        }
        XCTAssertEqual(key, "r1")
        XCTAssertEqual(kind, "ymap")
    }

    /// Removing a nested Y.Map fires `.removedNested`.
    func testRemoveNestedMapFiresRemovedNested() {
        let doc = YDocument()
        let root = doc.document.getMap(name: "root_b")
        // Pre-populate before attaching the observer so the insert
        // isn't part of our captured history.
        doc.transactSync { txn in
            _ = root.insertMap(tx: txn, key: "r1")
        }

        let collector = Collector()
        let sub = YrsMapObserverSubscription(
            map: root,
            callback: { collector.append($0) }
        )
        defer { sub.cancel() }

        doc.transactSync { txn in
            _ = try? root.remove(tx: txn, key: "r1")
        }

        XCTAssertEqual(collector.events.count, 1)
        guard case let .removedNested(key, kind) = collector.events.first else {
            return XCTFail("Expected .removedNested, got \(String(describing: collector.events.first))")
        }
        XCTAssertEqual(key, "r1")
        XCTAssertEqual(kind, "ymap")
    }

    /// Scalar inserts still fire `.inserted` (regression: the new
    /// variants must coexist with the old ones, not replace them).
    func testScalarInsertStillFiresInserted() {
        let doc = YDocument()
        let root = doc.document.getMap(name: "root_c")
        let collector = Collector()
        let sub = YrsMapObserverSubscription(
            map: root,
            callback: { collector.append($0) }
        )
        defer { sub.cancel() }

        doc.transactSync { txn in
            root.insert(tx: txn, key: "s1", value: "\"hello\"")
        }

        XCTAssertEqual(collector.events.count, 1)
        guard case let .inserted(key, value) = collector.events.first else {
            return XCTFail("Expected .inserted, got \(String(describing: collector.events.first))")
        }
        XCTAssertEqual(key, "s1")
        XCTAssertEqual(value, "\"hello\"")
    }

    /// Multiple changes in one transaction all surface.
    func testMixedBatchFiresAllEvents() {
        let doc = YDocument()
        let root = doc.document.getMap(name: "root_d")
        let collector = Collector()
        let sub = YrsMapObserverSubscription(
            map: root,
            callback: { collector.append($0) }
        )
        defer { sub.cancel() }

        doc.transactSync { txn in
            root.insert(tx: txn, key: "scalar", value: "42")
            _ = root.insertMap(tx: txn, key: "nested")
        }

        // Order isn't guaranteed — just assert both types landed.
        let kinds = Set(collector.events.map { event -> String in
            switch event {
            case .inserted:       return "inserted"
            case .insertedNested: return "insertedNested"
            default:              return "other"
            }
        })
        XCTAssertEqual(kinds, ["inserted", "insertedNested"])
    }

    /// Replacing a scalar with a nested map fires `.updatedNested`.
    func testUpdatedNestedFiresWhenReplacingScalarWithMap() {
        let doc = YDocument()
        let root = doc.document.getMap(name: "root_e")
        doc.transactSync { txn in
            root.insert(tx: txn, key: "k", value: "\"scalar\"")
        }
        let collector = Collector()
        let sub = YrsMapObserverSubscription(
            map: root,
            callback: { collector.append($0) }
        )
        defer { sub.cancel() }

        doc.transactSync { txn in
            _ = root.insertMap(tx: txn, key: "k")
        }

        XCTAssertEqual(collector.events.count, 1)
        guard case let .updatedNested(key, oldKind, newKind) = collector.events.first else {
            return XCTFail("Expected .updatedNested, got \(String(describing: collector.events.first))")
        }
        XCTAssertEqual(key, "k")
        XCTAssertEqual(oldKind, "any")
        XCTAssertEqual(newKind, "ymap")
    }

    // MARK: - Helpers

    private final class Collector {
        let lock = NSLock()
        private var _events: [YMapChange<String>] = []
        func append(_ arr: [YMapChange<String>]) {
            lock.lock(); _events.append(contentsOf: arr); lock.unlock()
        }
        var events: [YMapChange<String>] {
            lock.lock(); defer { lock.unlock() }; return _events
        }
    }

    /// Directly observes a `YrsMap` (the raw FFI handle), decoding
    /// values as `String`. Used here because the typed `YMap<T>`
    /// wrapper would need a specific Codable type — we're working at
    /// the raw-map level like `DynamicModel` does.
    private final class YrsMapObserverSubscription {
        private let subscription: Yniffi.YSubscription
        init(map: YrsMap, callback: @escaping ([YMapChange<String>]) -> Void) {
            let delegate = RawStringDelegate(callback: callback)
            self.subscription = map.observe(delegate: delegate)
        }
        func cancel() { /* Yniffi subscription auto-cancels on drop */ }
    }

    /// Delegate that treats scalar values as raw strings (no Coder
    /// decoding) so tests can assert the exact on-wire JSON.
    private final class RawStringDelegate: YrsMapObservationDelegate {
        let callback: ([YMapChange<String>]) -> Void
        init(callback: @escaping ([YMapChange<String>]) -> Void) {
            self.callback = callback
        }
        func call(value: [YrsMapChange]) {
            let mapped: [YMapChange<String>] = value.map { c in
                switch c.change {
                case let .inserted(v):        return .inserted(key: c.key, value: v)
                case let .updated(o, n):      return .updated(key: c.key, oldValue: o, newValue: n)
                case let .removed(v):         return .removed(key: c.key, value: v)
                case let .insertedNested(k):  return .insertedNested(key: c.key, kind: k)
                case let .updatedNested(o, n): return .updatedNested(key: c.key, oldKind: o, newKind: n)
                case let .removedNested(k):   return .removedNested(key: c.key, kind: k)
                }
            }
            callback(mapped)
        }
    }
}
