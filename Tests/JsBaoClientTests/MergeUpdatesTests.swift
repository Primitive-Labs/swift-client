import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Server-free tests for `DocumentManager.mergeUpdates` — the outbound
/// batching added for #2587 (JS parity: `flushLocalUpdates` sends
/// `Y.mergeUpdates(queued)` as ONE wire frame).
///
/// The invariant under test is the only one that matters: whatever the merge
/// produces must, when applied to a replica that already holds the document's
/// pre-batch state, reproduce exactly the state the batch produced locally.
/// A merge that quietly drops ops would still return `true` from
/// `sendLocalUpdate` and still consume the queue, so the loss would be
/// invisible — hence a replay assertion rather than a byte comparison.
final class MergeUpdatesTests: XCTestCase {

    /// Collect update frames off the doc's observer (which fires on the
    /// writing thread) without tripping Swift 6 concurrency checking.
    private final class UpdateSink: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [[UInt8]] = []
        func append(_ update: [UInt8]) { lock.withLock { frames.append(update) } }
        var all: [[UInt8]] { lock.withLock { frames } }
    }

    private func manager() -> DocumentManager {
        DocumentManager(logger: Logger(level: .none, scope: "merge-test"))
    }

    private func readString(_ doc: YDocument, root: String, record: String, key: String) -> String? {
        doc.transactSync { txn in
            guard let rootMap = txn.transactionGetMap(name: root),
                  let rec = rootMap.getMap(tx: txn, key: record) else { return nil }
            return try? rec.get(tx: txn, key: key)
        }
    }

    /// The record-write shape the Swift client actually produces: records are
    /// nested `YMap`s under a per-model root map (`DynamicModel.applyWrite`),
    /// so every edit to an ALREADY-SYNCED record has a parent whose creating
    /// op is outside the batch being merged.
    func testMergedBatchPreservesEditsToPreExistingRecords() throws {
        let doc = YDocument()

        // Pre-existing (already synced) state: one record under the model root.
        doc.transactSync { txn in
            let root = txn.transactionGetOrInsertMap(name: "Todo")
            let rec = root.getOrInsertMap(tx: txn, key: "rec1")
            _ = rec.tryUpdate(tx: txn, key: "title", value: "\"first\"")
        }
        let preBatchState: [UInt8] = doc.transactSync { $0.transactionEncodeStateAsUpdate() }

        // Two further edits to that same pre-existing record — the batch.
        let sink = UpdateSink()
        let subscription = doc.observeUpdate { sink.append($0) }
        defer { _ = subscription }

        doc.transactSync { txn in
            let root = txn.transactionGetOrInsertMap(name: "Todo")
            let rec = root.getOrInsertMap(tx: txn, key: "rec1")
            _ = rec.tryUpdate(tx: txn, key: "title", value: "\"second\"")
        }
        doc.transactSync { txn in
            let root = txn.transactionGetOrInsertMap(name: "Todo")
            let rec = root.getOrInsertMap(tx: txn, key: "rec1")
            _ = rec.tryUpdate(tx: txn, key: "note", value: "\"hello\"")
        }

        let batch = sink.all
        XCTAssertEqual(batch.count, 2, "expected one update frame per transaction")

        let merged = manager().mergeUpdates(batch)

        // Replica = a peer that already has the pre-batch state (the server).
        let replica = YDocument()
        replica.transactSync { txn in try? txn.transactionApplyUpdate(update: preBatchState) }
        replica.transactSync { txn in try? txn.transactionApplyUpdate(update: merged) }

        XCTAssertEqual(
            readString(replica, root: "Todo", record: "rec1", key: "title"), "\"second\"",
            "merged frame lost the edit to a pre-existing record"
        )
        XCTAssertEqual(
            readString(replica, root: "Todo", record: "rec1", key: "note"), "\"hello\"",
            "merged frame lost the second edit to a pre-existing record"
        )
    }

    /// The batch that creates its own dependencies (a fresh record written
    /// across two transactions) has to survive too.
    func testMergedBatchPreservesSelfContainedCreates() throws {
        let doc = YDocument()
        let sink = UpdateSink()
        let subscription = doc.observeUpdate { sink.append($0) }
        defer { _ = subscription }

        doc.transactSync { txn in
            let root = txn.transactionGetOrInsertMap(name: "Todo")
            let rec = root.getOrInsertMap(tx: txn, key: "new1")
            _ = rec.tryUpdate(tx: txn, key: "title", value: "\"a\"")
        }
        doc.transactSync { txn in
            let root = txn.transactionGetOrInsertMap(name: "Todo")
            let rec = root.getOrInsertMap(tx: txn, key: "new1")
            _ = rec.tryUpdate(tx: txn, key: "done", value: "true")
        }

        let merged = manager().mergeUpdates(sink.all)

        let replica = YDocument()
        replica.transactSync { txn in try? txn.transactionApplyUpdate(update: merged) }

        XCTAssertEqual(readString(replica, root: "Todo", record: "new1", key: "title"), "\"a\"")
        XCTAssertEqual(readString(replica, root: "Todo", record: "new1", key: "done"), "true")
    }

    /// Deletions inside the batch: a key removed from a pre-existing record
    /// must stay removed on the replica (the delete-set half of the merge).
    func testMergedBatchPreservesDeletes() throws {
        let doc = YDocument()
        doc.transactSync { txn in
            let root = txn.transactionGetOrInsertMap(name: "Todo")
            let rec = root.getOrInsertMap(tx: txn, key: "rec1")
            _ = rec.tryUpdate(tx: txn, key: "title", value: "\"first\"")
            _ = rec.tryUpdate(tx: txn, key: "gone", value: "\"x\"")
        }
        let preBatchState: [UInt8] = doc.transactSync { $0.transactionEncodeStateAsUpdate() }

        let sink = UpdateSink()
        let subscription = doc.observeUpdate { sink.append($0) }
        defer { _ = subscription }

        doc.transactSync { txn in
            let root = txn.transactionGetOrInsertMap(name: "Todo")
            let rec = root.getOrInsertMap(tx: txn, key: "rec1")
            _ = try? rec.remove(tx: txn, key: "gone")
        }
        doc.transactSync { txn in
            let root = txn.transactionGetOrInsertMap(name: "Todo")
            let rec = root.getOrInsertMap(tx: txn, key: "rec1")
            _ = rec.tryUpdate(tx: txn, key: "title", value: "\"second\"")
        }

        let batch = sink.all
        XCTAssertEqual(batch.count, 2)
        let merged = manager().mergeUpdates(batch)

        let replica = YDocument()
        replica.transactSync { txn in try? txn.transactionApplyUpdate(update: preBatchState) }
        replica.transactSync { txn in try? txn.transactionApplyUpdate(update: merged) }

        XCTAssertEqual(readString(replica, root: "Todo", record: "rec1", key: "title"), "\"second\"")
        XCTAssertNil(
            readString(replica, root: "Todo", record: "rec1", key: "gone"),
            "merged frame lost the delete of a pre-existing record's field"
        )
    }

    /// The strongest out-of-batch-dependency shape: the record is created by
    /// a DIFFERENT client (the peer that already synced it), and the local
    /// client only edits it. Every op in the batch then has a parent whose
    /// creating block belongs to a client the scratch doc has never seen.
    func testMergedBatchPreservesEditsToRemotelyCreatedRecords() throws {
        let peer = YDocument()
        peer.transactSync { txn in
            let root = txn.transactionGetOrInsertMap(name: "Todo")
            let rec = root.getOrInsertMap(tx: txn, key: "rec1")
            _ = rec.tryUpdate(tx: txn, key: "title", value: "\"peer\"")
        }
        let peerState: [UInt8] = peer.transactSync { $0.transactionEncodeStateAsUpdate() }

        let local = YDocument()
        local.transactSync { txn in try? txn.transactionApplyUpdate(update: peerState) }

        let sink = UpdateSink()
        let subscription = local.observeUpdate { sink.append($0) }
        defer { _ = subscription }

        local.transactSync { txn in
            let root = txn.transactionGetOrInsertMap(name: "Todo")
            let rec = root.getOrInsertMap(tx: txn, key: "rec1")
            _ = rec.tryUpdate(tx: txn, key: "title", value: "\"local\"")
        }
        local.transactSync { txn in
            let root = txn.transactionGetOrInsertMap(name: "Todo")
            let rec = root.getOrInsertMap(tx: txn, key: "rec1")
            _ = rec.tryUpdate(tx: txn, key: "note", value: "\"n\"")
        }

        let batch = sink.all
        XCTAssertEqual(batch.count, 2)
        let merged = manager().mergeUpdates(batch)

        let replica = YDocument()
        replica.transactSync { txn in try? txn.transactionApplyUpdate(update: peerState) }
        replica.transactSync { txn in try? txn.transactionApplyUpdate(update: merged) }

        XCTAssertEqual(readString(replica, root: "Todo", record: "rec1", key: "title"), "\"local\"")
        XCTAssertEqual(readString(replica, root: "Todo", record: "rec1", key: "note"), "\"n\"")
    }

    // MARK: - Merge budget (#2587 review)

    /// A flush merges only as much of the queue as fits one frame, so batching
    /// can't manufacture an over-`MAX_UPDATE_SIZE` frame that the outbound path
    /// has no R2 flow for — and that, once rejected, would be re-merged
    /// identically on every following pass.
    func testMergeBudgetStopsBeforeExceedingMaxUpdateSize() {
        let chunk = [UInt8](repeating: 0, count: 40_000)
        let queued = [[UInt8]](repeating: chunk, count: 5)

        let prefix = JsBaoClient.mergeBudgetPrefix(queued)

        XCTAssertEqual(prefix.count, 2, "40KB x 2 fits the 100KB budget; a third does not")
        XCTAssertLessThanOrEqual(
            prefix.reduce(0) { $0 + $1.count }, JsBaoClient.maxMergedUpdateBytes
        )
    }

    /// A single update already over the budget still goes out on its own —
    /// batching must not strand it (that was the behavior before batching).
    func testMergeBudgetAlwaysTakesAtLeastOneUpdate() {
        let huge = [UInt8](repeating: 0, count: JsBaoClient.maxMergedUpdateBytes * 2)
        let prefix = JsBaoClient.mergeBudgetPrefix([huge, [1, 2, 3]])
        XCTAssertEqual(prefix.count, 1)
        XCTAssertEqual(prefix[0].count, huge.count)
    }

    /// The common case: a burst of small updates merges whole.
    func testMergeBudgetTakesWholeQueueWhenSmall() {
        let queued: [[UInt8]] = (0..<12).map { _ in [UInt8](repeating: 7, count: 200) }
        XCTAssertEqual(JsBaoClient.mergeBudgetPrefix(queued).count, 12)
    }

    /// A single queued update must pass through untouched.
    func testSingleUpdatePassesThrough() throws {
        let doc = YDocument()
        let sink = UpdateSink()
        let subscription = doc.observeUpdate { sink.append($0) }
        defer { _ = subscription }
        doc.transactSync { txn in
            let root = txn.transactionGetOrInsertMap(name: "Todo")
            _ = root.tryUpdate(tx: txn, key: "k", value: "1")
        }
        let batch = sink.all
        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(manager().mergeUpdates(batch), batch[0])
    }
}
