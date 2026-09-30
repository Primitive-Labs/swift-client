import XCTest
@testable import JsBaoClient

/// The local write path of a large document (#3436, behavior 8, decision
/// 3436-SO-01), and the outbound hold's store-side half (behavior 33).
///
/// **Commit, then publish, inside one serialized operation.** The merged row
/// and the pending op land in ONE SQLite transaction, and only then does the
/// overlay mutation reach the epoch doc. The order is not a preference: a Yjs
/// mutation cannot be rolled back, so publishing first and committing second
/// means a SQLite failure leaves a rejected save on its way to every peer with
/// no durable record that it happened. `BaseModel.ts` commits first for the
/// same reason.
///
/// Serialized, because the fold queue runs against the same store: a batch
/// that landed between the commit and the publish would fold the pre-save
/// value over the row just committed.
final class Format2WritePathHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/f2-write-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeWriter(
        host: (any Format2SqlHost)? = nil
    ) async throws -> Format2WritePath {
        let provider: any Format2SqlHost
        if let host { provider = host } else { provider = try await makeProvider() }
        let store = Format2RecordStore(host: provider, documentId: "d", clientId: "me")
        try store.initialize()
        let overlay = OverlayDocument()
        let observer = Format2Observer(store: store, overlay: overlay)
        observer.register(model: "Note")
        return Format2WritePath(store: store, overlay: overlay, observer: observer)
    }

    // MARK: - Behavior 8 — the commit, then the publish

    func testACreateCommitsTheRowAndThePendingOpThenWritesTheOverlay() async throws {
        let writer = try await makeWriter()

        let seq = try writer.write(
            model: "Note",
            mutation: OverlayMutation(
                id: "r1", kind: .create, fields: ["title": .string("hello")]
            ),
            fields: ["title"]
        )
        XCTAssertEqual(seq, 1)

        // The merged row is readable immediately — read-your-writes holds
        // because the commit precedes the return.
        XCTAssertEqual(
            try writer.store.read(model: "Note", recordId: "r1")?["title"],
            .string("hello")
        )

        // The pending op carries this client's id, seq 1, the mutation it
        // stands for, and the overlay's prior values for the keys it wrote —
        // `[:]` here, because the overlay held none of them.
        let pending = try XCTUnwrap(try writer.store.pendingOps().first)
        XCTAssertEqual(pending.seq, 1)
        XCTAssertEqual(pending.model, "Note")
        XCTAssertEqual(pending.recordId, "r1")
        XCTAssertEqual(pending.op, .create)
        XCTAssertEqual(pending.mutation?.kind, .create)
        XCTAssertEqual(pending.mutation?.fields["title"], .string("hello"))
        XCTAssertEqual(pending.priorOverlay, [:])

        // And only then the overlay: `_replace`, the tombstone clear, the field.
        let overlayKeys = Set(writer.overlay.entries(model: "Note").map(\.0))
        XCTAssertEqual(overlayKeys, ["r1/_replace", "r1/_deleted", "r1/title"])
    }

    func testUpdateAndDeleteAppendTheNextSequences() async throws {
        let writer = try await makeWriter()
        _ = try writer.write(
            model: "Note",
            mutation: OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("a")]),
            fields: ["title"]
        )
        let updateSeq = try writer.write(
            model: "Note",
            mutation: OverlayMutation(id: "r1", kind: .patch, fields: ["title": .string("b")]),
            fields: ["title"]
        )
        let deleteSeq = try writer.write(
            model: "Note",
            mutation: OverlayMutation(id: "r1", kind: .delete),
            fields: []
        )
        XCTAssertEqual([updateSeq, deleteSeq], [2, 3])
        XCTAssertEqual(try writer.store.pendingOps().map(\.seq), [1, 2, 3])
        XCTAssertEqual(try writer.store.pendingOps().map(\.op), [.create, .patch, .delete])
        XCTAssertNil(
            try writer.store.read(model: "Note", recordId: "r1"),
            "the delete's tombstone folded to no row"
        )
    }

    func testAPatchRecordsWhatTheOverlayHeldBeforeIt() async throws {
        let writer = try await makeWriter()
        _ = try writer.write(
            model: "Note",
            mutation: OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("a")]),
            fields: ["title"]
        )
        _ = try writer.write(
            model: "Note",
            mutation: OverlayMutation(id: "r1", kind: .patch, fields: ["title": .string("b")]),
            fields: ["title"]
        )

        let patch = try XCTUnwrap(try writer.store.pendingOps().last)
        XCTAssertEqual(
            patch.priorOverlay?["r1/title"], .string("a"),
            "the prior value is what the overlay held when the write started"
        )
    }

    // MARK: - Behavior 8 — the failure

    func testASqliteFailureAtTheCommitPublishesNothingAndThrows() async throws {
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let writer = try await makeWriter(host: failing)

        let overlayBefore = writer.overlay.entries(model: "Note").count
        let vectorBefore = writer.overlay.encodeStateAsUpdate()

        failing.failStatementsContaining = "INSERT OR REPLACE INTO _pending_ops"
        XCTAssertThrowsError(
            try writer.write(
                model: "Note",
                mutation: OverlayMutation(
                    id: "r1", kind: .create, fields: ["title": .string("doomed")]
                ),
                fields: ["title"]
            ),
            "the write must throw rather than report a save that did not happen"
        )
        failing.failStatementsContaining = nil

        // Nothing at all: no merged row, no pending op, no overlay key — and
        // therefore no outbound frame, because an outbound frame is a Y.Doc
        // update and there is none.
        XCTAssertNil(try writer.store.read(model: "Note", recordId: "r1"), "a row was committed")
        XCTAssertEqual(try writer.store.pendingOps().count, 0, "a pending op survived")
        XCTAssertEqual(
            writer.overlay.entries(model: "Note").count, overlayBefore,
            "an overlay key was published for a write that failed"
        )
        XCTAssertEqual(
            writer.overlay.encodeStateAsUpdate(), vectorBefore,
            "the epoch doc changed, so peers would have seen the rejected save"
        )
    }

    func testTheRowAndThePendingOpRollBackTogether() async throws {
        // The two halves are one transaction: a failure after the row is
        // projected must take the row with it, or the merged view shows a
        // save the durable log has no record of.
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let writer = try await makeWriter(host: failing)

        failing.failStatementsContaining = "INSERT OR REPLACE INTO _pending_ops"
        XCTAssertThrowsError(
            try writer.write(
                model: "Note",
                mutation: OverlayMutation(id: "r1", kind: .create, fields: ["t": .string("x")]),
                fields: ["t"]
            )
        )
        failing.failStatementsContaining = nil

        XCTAssertNil(try writer.store.read(model: "Note", recordId: "r1"))
        XCTAssertEqual(try writer.store.recordIds(model: "Note"), [])
    }

    // MARK: - Behavior 8 — the operation boundary

    func testAFoldBatchIsAppliedAfterTheOperationNeverBetweenCommitAndPublish() async throws {
        // The hazard #3429 hit through a second door: a fold batch that
        // materializes between the commit and the publish reads the PRE-save
        // overlay and folds it over the row just committed, silently undoing
        // the save. The write holds the document's operation lock for both
        // halves, so a drain that arrives mid-write runs after it.
        let writer = try await makeWriter()
        _ = try writer.write(
            model: "Note",
            mutation: OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("a")]),
            fields: ["title"]
        )

        // A real second thread, asking to fold WHILE the write's operation is
        // open. It must not be serviced until the operation releases.
        //
        // The semaphores live in a synchronous function: `DispatchSemaphore`
        // is unavailable from an async context, and rightly — blocking a
        // cooperative-pool thread is exactly what it warns about.
        let order = LockedBox<[String]>([])
        func raceADrainAgainstTheOperation() throws {
            let drainReady = DispatchSemaphore(value: 0)
            let drainDone = DispatchSemaphore(value: 0)

            DispatchQueue.global().async {
                drainReady.wait()
                _ = try? writer.foldPendingUnderOperation()
                order.withValue { $0.append("drain") }
                drainDone.signal()
            }

            try writer.withOperation {
                // Let the other thread in, and give it every chance to get in
                // front of the commit.
                drainReady.signal()
                Thread.sleep(forTimeInterval: 0.05)
                try writer.commitInsideOperation(
                    model: "Note",
                    mutation: OverlayMutation(
                        id: "r1", kind: .patch, fields: ["title": .string("b")]
                    ),
                    fields: ["title"]
                )
                order.withValue { $0.append("write") }
            }
            XCTAssertEqual(drainDone.wait(timeout: .now() + 5), .success, "the drain never ran")
        }
        try raceADrainAgainstTheOperation()

        XCTAssertEqual(
            order.value, ["write", "drain"],
            "a fold ran between the commit and the publish"
        )
        XCTAssertEqual(
            try writer.store.read(model: "Note", recordId: "r1")?["title"],
            .string("b"),
            "the fold undid the save"
        )
    }

    /// A write that was WAITING for the operation a failing fold held is
    /// refused too.
    ///
    /// The early refusal in `write` is taken before the lock, so a fold that
    /// holds the operation, fails, and declares the merged view broken does it
    /// behind a write that has already passed that check. Expressed at
    /// `commitInsideOperation` — the seam a caller inside the operation goes
    /// through — because that is exactly where such a write resumes, and the
    /// interleaving is then deterministic rather than a sleep.
    func testAWriteInsideTheOperationIsRefusedOnceTheFoldHasBrokenTheView() async throws {
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let writer = try await makeWriter(host: failing)

        // Something to fold, then a fold that fails: the state is sticky from
        // here, and this is the moment a waiting write is let through.
        let peer = OverlayDocument()
        peer.apply(
            OverlayMutation(id: "r1", kind: .create, fields: ["title": .string("a")]),
            model: "Note"
        )
        try writer.overlay.applyUpdate(peer.encodeStateAsUpdate())
        failing.failStatementsContaining = "INSERT INTO records_f2_"
        XCTAssertThrowsError(try writer.foldPendingUnderOperation())
        failing.failStatementsContaining = nil
        XCTAssertTrue(writer.observer.isFoldBroken)

        let overlayBefore = writer.overlay.entries(model: "Note").count
        XCTAssertThrowsError(
            try writer.withOperation {
                try writer.commitInsideOperation(
                    model: "Note",
                    mutation: OverlayMutation(
                        id: "r2", kind: .create, fields: ["title": .string("late")]
                    ),
                    fields: ["title"]
                )
            }
        ) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .format2FoldBroken)
        }

        XCTAssertEqual(try writer.store.pendingOps().count, 0, "a pending op was written")
        XCTAssertEqual(
            writer.overlay.entries(model: "Note").count, overlayBefore,
            "the write published to the epoch doc on a document known to be broken"
        )
    }

    /// The observer's second fold of a local write is idempotent — yswift
    /// carries no transaction origin, so a write this client made is folded
    /// once by the commit and again by the observer.
    func testTheObserversSecondFoldOfALocalWriteChangesNothing() async throws {
        let writer = try await makeWriter()
        _ = try writer.write(
            model: "Note",
            mutation: OverlayMutation(
                id: "r1", kind: .create,
                fields: ["title": .string("a")],
                stringSetDeltas: ["tags": ["x": true]]
            ),
            fields: ["title"]
        )
        let afterCommit = try writer.store.read(model: "Note", recordId: "r1")
        let membersAfterCommit = try writer.store.dumpMembers()

        try writer.observer.drain()

        // The RECORD is the claim, not the stored blob's byte order — though
        // the fold sorts its patch keys, so the blob is stable too.
        XCTAssertEqual(try writer.store.read(model: "Note", recordId: "r1"), afterCommit)
        XCTAssertEqual(try writer.store.dumpMembers(), membersAfterCommit)
        XCTAssertEqual(
            try writer.store.dumpRecords().count, 1,
            "the second fold minted a second row"
        )
    }

    // MARK: - Behavior 33 — the hold, store side

    func testAHeldDocumentQueuesItsFramesAndReleasesThemInOrder() async throws {
        let writer = try await makeWriter()
        let hold = Format2OutboundHold()

        XCTAssertFalse(hold.isHeld("d"), "a document with no hold is not held")
        hold.hold("d", reason: "awaiting epoch.info")
        XCTAssertTrue(hold.isHeld("d"))

        // Held frames are KEPT, not dropped.
        hold.enqueue("d", frame: "frame-1")
        hold.enqueue("d", frame: "frame-2")
        XCTAssertEqual(hold.queuedCount("d"), 2)

        let released = hold.release("d", reason: "join")
        XCTAssertEqual(released, ["frame-1", "frame-2"], "released out of order")
        XCTAssertFalse(hold.isHeld("d"))
        XCTAssertEqual(hold.queuedCount("d"), 0)
        _ = writer
    }

    /// E16 — a release with an empty queue sends nothing; a hold set twice
    /// releases once.
    func testAnEmptyReleaseSendsNothingAndADoubleHoldReleasesOnce() async throws {
        let hold = Format2OutboundHold()
        hold.hold("d", reason: "seal")
        XCTAssertEqual(hold.release("d", reason: "handshake"), [])

        hold.hold("d", reason: "seal")
        hold.hold("d", reason: "reconnect")
        hold.enqueue("d", frame: "f")
        XCTAssertEqual(
            hold.release("d", reason: "handshake"), ["f"],
            "a hold set twice must release on the one handshake, not owe a second release"
        )
        XCTAssertFalse(hold.isHeld("d"))
    }

    func testAFormatOneDocumentIsNeverHeld() async throws {
        let hold = Format2OutboundHold()
        hold.hold("large", reason: "awaiting epoch.info")
        XCTAssertFalse(
            hold.isHeld("ordinary"),
            "a hold is per document — an ordinary document on the same socket is not held"
        )
        XCTAssertEqual(hold.release("ordinary", reason: "n/a"), [])
    }
}
