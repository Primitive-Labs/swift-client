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

    // MARK: - Merge budget — removed (#3559)
    //
    // The budget capped one merged frame at 102400 bytes for exactly one
    // reason, written where it stood: Swift's outbound path had no R2 upload
    // flow, so a merged frame past that size could only go out inline. #3559
    // gave it one, switching at the same size the JS client does on both
    // outbound paths, so the cap went with the gap it existed for and a flush
    // merges the whole queue as `flushLocalUpdates` does.
    //
    // What the cap used to be checked for is now checked where the behavior
    // lives: `OversizeOutboundUpdateHermeticTests` drives a flush of three
    // 50 KB writes and pins that it drains as ONE frame, offloaded because the
    // merge is oversize. The merge itself — that nothing is lost by merging —
    // is the replay assertions above, which are unchanged.

    /// A merge of the whole queue is still a correct merge, past the size the
    /// old budget would have split at. This is the claim the budget tests used
    /// to make about a PREFIX, made about the whole queue.
    func testWholeQueueMergesCorrectlyPastTheOldBudget() throws {
        let doc = YDocument()
        let sink = UpdateSink()
        let subscription = doc.observeUpdate { sink.append($0) }
        defer { _ = subscription }

        // Five ~40 KB writes: 200 KB queued, which the old budget would have
        // drained as three passes.
        let chunk = String(repeating: "x", count: 40_000)
        for index in 0..<5 {
            doc.transactSync { txn in
                let root = txn.transactionGetOrInsertMap(name: "Todo")
                let rec = root.getOrInsertMap(tx: txn, key: "rec\(index)")
                _ = rec.tryUpdate(tx: txn, key: "body", value: "\"\(chunk)\"")
            }
        }

        let batch = sink.all
        XCTAssertEqual(batch.count, 5)
        XCTAssertGreaterThan(batch.reduce(0) { $0 + $1.count }, 102_400)

        let merged = manager().mergeUpdates(batch)
        let replica = YDocument()
        replica.transactSync { txn in try? txn.transactionApplyUpdate(update: merged) }

        for index in 0..<5 {
            XCTAssertEqual(
                readString(replica, root: "Todo", record: "rec\(index)", key: "body"),
                "\"\(chunk)\"",
                "merging the whole queue lost record rec\(index)"
            )
        }
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
