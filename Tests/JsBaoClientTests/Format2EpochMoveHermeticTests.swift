import XCTest
@testable import JsBaoClient
import YSwift

/// Following an ordinary seal while current (#3437, behavior 10 and 12,
/// edges E1, E5, E13).
///
/// #3436 STOPPED a document on `epoch.seal`: reads kept answering, the pending
/// log was kept, and the next open had to reload from a covering base. This is
/// the path that makes a seal a non-event instead — the client moves onto a
/// fresh overlay carrying exactly the writes the server has not acknowledged,
/// and goes on writing.
///
/// The order inside the move is not a preference:
///
/// - the carry is read under the operation lock, so a local write cannot land
///   between reading the owed values and installing the fresh overlay;
/// - the queued frames are discarded, because every one of them is a delta
///   against an overlay the room has archived;
/// - the fresh overlay is persisted BEFORE the epoch mark moves, so a crash in
///   between restarts holding the fresh overlay under the OLD mark — which the
///   next handshake's catch-up repairs idempotently — rather than the sealed
///   overlay under the new mark, which would be resent whole into the new
///   epoch (finding 3437-R05);
/// - the mark, the sync mark and (when the carry was deferred) the judgement
///   note are ONE store transaction.
final class Format2EpochMoveHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "body": FieldDescriptor(type: .string),
        ]
    )

    private struct Fixture {
        let coordinator: Format2Coordinator
        let binding: Format2DocumentBinding
        let model: DynamicModel
        let documentId: String
        /// Every document the coordinator asked to have replaced, and with
        /// what — the stand-in for `DocumentManager.replaceOpenDocument`.
        let replaced: LockedBox<[(String, YDocument)]>
    }

    private func makeFixture() async throws -> Fixture {
        let directory = NSTemporaryDirectory() + "/f2-move-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")

        let documentId = "move-\(UUID().uuidString.prefix(8))"
        let doc = YDocument()
        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        let replaced = LockedBox<[(String, YDocument)]>([])
        coordinator.replaceDocument = { id, document in
            replaced.withValue { $0.append((id, document)) }
        }
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: doc
        )
        let shared = MultiDocModel(schema: Self.schema)
        let model = shared.connect(docId: documentId, doc: doc)
        model.bindFormat2(binding)

        // Joined, so the document is current and not held.
        _ = try coordinator.handleEpochInfo(
            ["documentId": documentId, "epoch": 1, "sealedEpochs": []],
            now: Int(Date().timeIntervalSince1970 * 1000)
        )
        return Fixture(
            coordinator: coordinator, binding: binding, model: model,
            documentId: documentId, replaced: replaced
        )
    }

    private func sealFrame(
        _ documentId: String, epoch: Int, next: Int, flagged: Bool = false
    ) -> [String: Any] {
        [
            "type": "epoch.seal", "documentId": documentId,
            "epoch": epoch, "next": next, "baseDiscontinuity": flagged,
        ]
    }

    // MARK: - Behavior 10 — the move

    func testAnOrdinarySealMovesTheDocumentOntoAFreshOverlay() async throws {
        let fixture = try await makeFixture()

        // One acknowledged write and one still owed.
        _ = try fixture.model.create(id: "acked", values: ["title": .string("old news")])
        try fixture.coordinator.handleUpdateAck(
            ["documentId": fixture.documentId, "maxContiguousSeq": 1]
        )
        _ = try fixture.model.create(id: "owed", values: ["title": .string("still owed")])
        XCTAssertEqual(try fixture.binding.store.pendingOps().map(\.seq), [2])

        let sealedOverlay = fixture.binding.overlay

        let decision = try fixture.coordinator.handleEpochSeal(
            sealFrame(fixture.documentId, epoch: 1, next: 2)
        )
        XCTAssertEqual(decision, .move(next: 2))

        let outcome = try await fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 2,
            now: 1_700_000_000_000
        )
        XCTAssertEqual(outcome, .moved(epoch: 2))

        // The document was replaced, and the binding follows the fresh overlay.
        XCTAssertEqual(fixture.replaced.value.count, 1)
        XCTAssertEqual(fixture.replaced.value.first?.0, fixture.documentId)
        XCTAssertFalse(
            fixture.binding.overlay === sealedOverlay,
            "the binding reads and writes the FRESH overlay from here on"
        )

        // The owed write travelled; the acknowledged one did not — it is
        // already in the server's records table and in this client's merged
        // view, so re-sending it would cost an epoch and buy nothing.
        XCTAssertEqual(
            fixture.binding.overlay.value(model: "Note", key: "owed/title"),
            .string("still owed")
        )
        XCTAssertNil(
            fixture.binding.overlay.value(model: "Note", key: "acked/title"),
            "an acknowledged write must not re-seed the new epoch"
        )

        // The marks moved, together.
        XCTAssertEqual(try fixture.binding.store.epoch(), 2)
        XCTAssertEqual(try fixture.binding.store.lastSyncAt(), 1_700_000_000_000)
        XCTAssertNil(
            try fixture.binding.store.deferredReplay(),
            "an ordinary move owes no judgement"
        )

        // Nothing was stopped, and the hold is gone.
        XCTAssertNil(fixture.binding.reloadRefusal)
        XCTAssertFalse(fixture.coordinator.hold.isHeld(fixture.documentId))

        // And the merged view is unchanged by the move — the records are the
        // document, not the overlay.
        XCTAssertEqual(
            try fixture.binding.store.read(model: "Note", recordId: "acked")?["title"],
            .string("old news")
        )
        XCTAssertEqual(
            try fixture.binding.store.read(model: "Note", recordId: "owed")?["title"],
            .string("still owed")
        )
    }

    func testTheMoveDiscardsTheFramesQueuedAgainstTheSealedOverlay() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "owed", values: ["title": .string("x")])

        // A frame is queued but unsent: it is a DELTA against the overlay the
        // room has just archived, so it can never be integrated there.
        fixture.coordinator.outbound.note(fixture.documentId, seq: 1)
        _ = try fixture.coordinator.handleEpochSeal(
            sealFrame(fixture.documentId, epoch: 1, next: 2)
        )
        _ = try await fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 2, now: 1_700_000_000_000
        )

        // The owed sequence is claimable again, because the fresh overlay
        // carries its content afresh rather than as a delta.
        let claim = fixture.coordinator.outbound.wholeState(
            fixture.documentId, from: 1, upTo: try fixture.binding.store.highestLocalSeq()
        )
        XCTAssertEqual(claim.range?.from, 1)
    }

    func testTheWritePathAcceptsWritesAfterTheMoveAndTheyLandOnTheFreshOverlay()
        async throws
    {
        let fixture = try await makeFixture()
        _ = try fixture.coordinator.handleEpochSeal(
            sealFrame(fixture.documentId, epoch: 1, next: 2)
        )
        // The move's `now` IS the offline window's mark, so it takes this
        // client's real clock: a back-dated one would leave the document
        // read-only the moment it joined the new epoch.
        _ = try await fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 2,
            now: Int(Date().timeIntervalSince1970 * 1000)
        )

        // Edge E5: the facade keeps working, and its write is on the fresh
        // overlay and recorded against the epoch the document joined.
        _ = try fixture.model.create(id: "after", values: ["title": .string("new epoch")])
        XCTAssertEqual(
            fixture.binding.overlay.value(model: "Note", key: "after/title"),
            .string("new epoch")
        )
        let pending = try XCTUnwrap(
            try fixture.binding.store.pendingOps().first { $0.recordId == "after" }
        )
        XCTAssertEqual(pending.baseEpoch, 2)
        XCTAssertEqual(
            try fixture.model.find(id: "after")?["title"], .string("new epoch"),
            "the merged view answers through the rebound observer"
        )
    }

    /// The seal holds the document's outbound frames the INSTANT it is read,
    /// not when the move gets round to discarding them.
    ///
    /// The move drops the queued frames because each is a Yjs delta against the
    /// overlay the room has archived. But the move is work — settling folds,
    /// reading the owed values, writing the carry, persisting the fresh
    /// document — and the debounced flush of a write made just before the seal
    /// runs on its own schedule. Measured live: the delta went out in the same
    /// millisecond as the move, from the flush that had been waiting for it.
    ///
    /// What the room does with that frame is the reason this matters. It cannot
    /// integrate it, and it does not drop it either: the structs sit
    /// unintegrated in the room's document, and from then on EVERY frame from
    /// that connection is answered with a resync request instead of an
    /// acknowledgement — for ever, at the rate the client re-sends. Reproduced
    /// live, 25 answered resyncs a second until the test gave up with its write
    /// still pending.
    ///
    /// Held, not refused: the write behind the frame is the user's, it commits
    /// as it always did, and the move carries its content onto the fresh
    /// overlay.
    func testASealHoldsTheOutboundQueueBeforeTheMoveRuns() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "owed", values: ["title": .string("owed")])
        XCTAssertNil(
            fixture.coordinator.hold.reason(fixture.documentId),
            "a current document sends what it commits"
        )

        let decision = try fixture.coordinator.handleEpochSeal(
            sealFrame(fixture.documentId, epoch: 1, next: 2)
        )
        XCTAssertEqual(decision, .move(next: 2))
        XCTAssertTrue(
            fixture.coordinator.hold.isHeld(fixture.documentId),
            "a flush firing between this frame and the move must find the "
                + "document held: the frame it would send is a delta against an "
                + "overlay the room has archived, and the room is poisoned by it"
        )

        _ = try await fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 2, now: 1_700_000_000_000
        )
        XCTAssertFalse(
            fixture.coordinator.hold.isHeld(fixture.documentId),
            "and the move releases it: the fresh overlay's state is what goes "
                + "out instead"
        )
    }

    /// A seal that is read but never moved gives the hold back.
    ///
    /// `handleEpochSeal` decides and `runEpochMove` acts, and between them the
    /// document can be moved by something else — a catch-up that ended in the
    /// same epoch, a second seal already followed. The move then answers
    /// `already-current`, and a hold nobody gave back leaves the document
    /// committing writes and sending none of them, for ever.
    func testASealHoldThatNeverMovesIsGivenBack() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.coordinator.handleEpochSeal(
            sealFrame(fixture.documentId, epoch: 1, next: 2)
        )
        XCTAssertTrue(fixture.coordinator.hold.isHeld(fixture.documentId))

        // Something else got there first.
        try fixture.binding.store.setEpoch(2)
        let outcome = try await fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 2, now: 1_700_000_000_000
        )
        XCTAssertEqual(outcome, .alreadyCurrent)
        XCTAssertFalse(
            fixture.coordinator.hold.isHeld(fixture.documentId),
            "the document goes on sending: nothing else was ever coming to "
                + "release a hold the seal took"
        )
    }

    /// And a seal neither adopts nor gives back a hold it did not take: a
    /// document stopped for a reload, or held awaiting a base past a bulk load,
    /// is held for a reason a rotation knows nothing about.
    func testASealDoesNotGiveBackAHoldItDidNotTake() async throws {
        let fixture = try await makeFixture()
        fixture.coordinator.hold.hold(
            fixture.documentId, reason: "awaiting a base past a bulk load"
        )
        _ = try fixture.coordinator.handleEpochSeal(
            sealFrame(fixture.documentId, epoch: 1, next: 2)
        )
        XCTAssertEqual(
            fixture.coordinator.hold.reason(fixture.documentId),
            "awaiting a base past a bulk load",
            "the seal reads a document that is already held and takes nothing"
        )

        try fixture.binding.store.setEpoch(2)
        _ = try await fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 2, now: 1_700_000_000_000
        )
        XCTAssertTrue(
            fixture.coordinator.hold.isHeld(fixture.documentId),
            "and the base it is waiting for has not arrived because a seal "
                + "went past"
        )
    }

    // MARK: - Behavior 12 and edge E1 — duplicates and serialization

    func testADuplicateSealIsAlreadyCurrentAndChangesNothing() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.coordinator.handleEpochSeal(
            sealFrame(fixture.documentId, epoch: 1, next: 2)
        )
        _ = try await fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 2, now: 1_700_000_000_000
        )
        XCTAssertEqual(fixture.replaced.value.count, 1)

        // The same seal again: the document has already left epoch 1.
        let again = try fixture.coordinator.handleEpochSeal(
            sealFrame(fixture.documentId, epoch: 1, next: 2)
        )
        XCTAssertEqual(again, .alreadyCurrent)
        XCTAssertEqual(
            fixture.replaced.value.count, 1, "nothing moved a second time"
        )
        XCTAssertEqual(try fixture.binding.store.epoch(), 2)
    }

    func testAResyncForAnEpochAlreadyLeftIsAlreadyCurrent() async throws {
        let fixture = try await makeFixture()
        try fixture.binding.store.setEpoch(5)
        let decision = try fixture.coordinator.handleEpochSeal([
            "type": "epoch.resync", "documentId": fixture.documentId, "epoch": 3,
        ])
        XCTAssertEqual(decision, .alreadyCurrent)
    }

    func testAResyncAtTheCurrentEpochAsksForWholeState() async throws {
        let fixture = try await makeFixture()
        let decision = try fixture.coordinator.handleEpochSeal([
            "type": "epoch.resync", "documentId": fixture.documentId, "epoch": 1,
        ])
        XCTAssertEqual(
            decision, .resyncOwed,
            "a resync naming the epoch the document is ON is not a rotation: the "
            + "room could not integrate ONE frame and is asking for self-contained "
            + "state (finding 3436-B01)"
        )
    }

    func testASealForADocumentThatIsNotBoundIsDropped() async throws {
        let fixture = try await makeFixture()
        XCTAssertEqual(
            try fixture.coordinator.handleEpochSeal(
                sealFrame("nobody-holds-this", epoch: 1, next: 2)
            ),
            .dropped
        )
    }

    /// Behavior 12: two moves of one document do not interleave. The second
    /// finds the first already done and is a no-op rather than a second swap.
    func testMovesOfOneDocumentAreSerialized() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "owed", values: ["title": .string("x")])
        _ = try fixture.coordinator.handleEpochSeal(
            sealFrame(fixture.documentId, epoch: 1, next: 2)
        )

        async let first = fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 2, now: 1_700_000_000_000
        )
        async let second = fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 2, now: 1_700_000_000_000
        )
        let outcomes = try await [first, second]

        XCTAssertEqual(
            outcomes.filter { $0 == .moved(epoch: 2) }.count, 1,
            "exactly one of the two moved the document"
        )
        XCTAssertEqual(
            outcomes.filter { $0 == .alreadyCurrent }.count, 1,
            "the other found it already done"
        )
        XCTAssertEqual(fixture.replaced.value.count, 1, "one swap, not two")
        XCTAssertEqual(try fixture.binding.store.epoch(), 2)
    }

    // MARK: - Edge E13 — one release

    func testAHoldSetByASealAndByAReconnectReleasesOnce() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.coordinator.handleEpochSeal(
            sealFrame(fixture.documentId, epoch: 1, next: 2)
        )
        // A reconnect lands before the move runs, holding the document again.
        _ = fixture.coordinator.holdAllForNewConnection()
        XCTAssertTrue(fixture.coordinator.hold.isHeld(fixture.documentId))

        _ = try await fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 2, now: 1_700_000_000_000
        )
        XCTAssertFalse(
            fixture.coordinator.hold.isHeld(fixture.documentId),
            "a hold set twice releases once — anything else leaves a document "
            + "held by a seal that a reconnect also held, owing a second "
            + "release nobody sends"
        )
    }
}
