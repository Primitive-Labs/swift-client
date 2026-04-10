import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Repro tests for the live updates deadlock observed in the demo app.
///
/// Symptom: After WebSocket sync completes, calling `readCurrentState()` hangs.
/// The hang occurs at this pattern:
///
///     let txn = doc.document.transact(origin: nil)
///     let map = doc.document.getMap(name: "liveDemo")  // <-- hangs here
///
/// Hypothesis: `transact()` acquires Yrs's document write lock. Calling
/// `getMap(name:)` on the same `YrsDoc` while a transaction is open tries
/// to acquire that same lock and deadlocks.
///
/// The BaoModel class already documents this:
/// > Get or create the root map OUTSIDE any transaction to avoid deadlocks.
///
/// IMPORTANT: These tests use DispatchQueue + DispatchSemaphore (NOT Swift Concurrency)
/// because a Task blocked in Rust FFI on a lock cannot be cancelled, which would
/// hang `withTaskGroup` forever. With GCD, the hung worker thread is leaked at the end
/// of the test but the test itself completes.
final class YDocumentDeadlockTests: XCTestCase {

    /// Sanity / control: getMap BEFORE opening a transaction works fine.
    func testGetMapBeforeTransactionWorks() {
        let doc = YDocument()

        // Get the map first (no txn open)
        let map = doc.document.getMap(name: "liveDemo")

        // Then open a txn and use it
        let txn = doc.document.transact(origin: nil)
        defer { txn.free() }

        map.insert(tx: txn, key: "note", value: "\"hello\"")
        let raw = try? map.get(tx: txn, key: "note")
        XCTAssertEqual(raw as? String, "\"hello\"")
    }

    /// Regression marker: asserts that calling `getMap` from INSIDE an open
    /// `transact()` deadlocks (i.e. the worker never signals within 3s).
    /// If this test ever starts failing — meaning the call returns successfully
    /// — Yrs has made the document lock reentrant and the LiveText / BaoModel
    /// "resolve handles before transact" workaround can be relaxed.
    func testGetMapInsideTransactionDeadlocks_regressionMarker() {
        let doc = YDocument()
        let semaphore = DispatchSemaphore(value: 0)

        // NOTE: this thread is intentionally leaked when the deadlock occurs.
        // It's holding the YrsDoc write lock — there is no safe way to free it.
        // Each run of this test leaks one thread. Acceptable for a regression marker.
        DispatchQueue.global(qos: .userInitiated).async {
            let txn = doc.document.transact(origin: nil)
            defer { txn.free() }
            let map = doc.document.getMap(name: "liveDemo")
            _ = try? map.get(tx: txn, key: "note")
            semaphore.signal()
        }

        let result = semaphore.wait(timeout: .now() + 3)
        XCTAssertEqual(result, .timedOut, "Expected getMap-inside-transact to deadlock. " +
                       "If this test fails, Yrs may have made the document lock reentrant — " +
                       "consider relaxing the resolve-handles-first pattern in LiveText/BaoModel.")
    }

    /// Regression marker: same as above using the exact dispatch shape that
    /// the original buggy `readCurrentState()` used.
    func testReadCurrentStatePatternDeadlocks_regressionMarker() {
        let doc = YDocument()

        // Pre-seed some data via the SAFE pattern (getMap first, then transact)
        let preMap = doc.document.getMap(name: "liveDemo")
        let preTxn = doc.document.transact(origin: nil)
        preMap.insert(tx: preTxn, key: "note", value: "\"hello\"")
        preTxn.free()

        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            let txn = doc.document.transact(origin: nil)
            defer { txn.free() }
            let map = doc.document.getMap(name: "liveDemo")
            _ = try? map.get(tx: txn, key: "note")
            semaphore.signal()
        }

        let result = semaphore.wait(timeout: .now() + 3)
        XCTAssertEqual(result, .timedOut, "Expected the buggy readCurrentState pattern to deadlock.")
    }

    /// End-to-end: simulate the live updates scenario after syncStep2.
    /// Client A writes data; we encode it as a Yrs update; client B applies the update
    /// (mimicking handleSyncStep2); then client B reads via the FIXED pattern.
    /// This closely mirrors the demo's post-sync read path.
    func testLiveUpdatesEndToEndAfterRemoteApply() {
        // ----- Producer doc (mimics another client) -----
        let producer = YDocument()
        let prodMap = producer.document.getMap(name: "liveDemo")
        let prodTxn = producer.document.transact(origin: nil)
        prodMap.insert(tx: prodTxn, key: "note", value: "\"hello from producer\"")
        prodMap.insert(tx: prodTxn, key: "counter", value: "42")
        let producerUpdate = prodTxn.transactionEncodeStateAsUpdate()
        prodTxn.free()

        // ----- Consumer doc (mimics LiveUpdatesDemo's local YDocument) -----
        let consumer = YDocument()

        // Apply the update on a background queue (mirroring handleSyncStep2 dispatch).
        let applySem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let txn = consumer.document.transact(origin: nil)
            try? txn.transactionApplyUpdate(update: producerUpdate)
            txn.free()
            applySem.signal()
        }
        XCTAssertEqual(applySem.wait(timeout: .now() + 3), .success, "applying remote update should not hang")

        // ----- Now read via the FIXED readCurrentState pattern -----
        let readSem = DispatchSemaphore(value: 0)
        var readNote: String?
        var readCounter: String?

        // Hoist getMap BEFORE the txn (the fix)
        let map = consumer.document.getMap(name: "liveDemo")

        DispatchQueue.global(qos: .userInitiated).async {
            let txn = consumer.document.transact(origin: nil)
            defer { txn.free() }
            readNote = try? map.get(tx: txn, key: "note")
            readCounter = try? map.get(tx: txn, key: "counter")
            readSem.signal()
        }

        XCTAssertEqual(readSem.wait(timeout: .now() + 3), .success, "fixed read should not hang")
        XCTAssertEqual(readNote, "\"hello from producer\"")
        XCTAssertEqual(readCounter, "42")
    }

    /// Confirms the FIX works: getMap hoisted above transact, then used inside the closure.
    func testFixedReadCurrentStatePatternWorks() {
        let doc = YDocument()

        // Pre-seed some data
        let preMap = doc.document.getMap(name: "liveDemo")
        let preTxn = doc.document.transact(origin: nil)
        preMap.insert(tx: preTxn, key: "note", value: "\"hello\"")
        preTxn.free()

        let semaphore = DispatchSemaphore(value: 0)
        var readNote: String?

        DispatchQueue.global(qos: .userInitiated).async {
            // FIX: get the map BEFORE opening the transaction
            let map = doc.document.getMap(name: "liveDemo")

            let txn = doc.document.transact(origin: nil)
            defer { txn.free() }

            if let raw = try? map.get(tx: txn, key: "note") {
                readNote = raw as? String
            }
            semaphore.signal()
        }

        let result = semaphore.wait(timeout: .now() + 3)
        XCTAssertEqual(result, .success, "Fixed pattern should not hang")
        XCTAssertEqual(readNote, "\"hello\"")
    }
}
