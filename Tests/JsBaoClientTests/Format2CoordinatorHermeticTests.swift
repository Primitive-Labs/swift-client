import XCTest
@testable import JsBaoClient

/// The client's format-2 coordinator: which documents are large, what the
/// epoch frames do to them, and what an outbound update claims (#3436,
/// behaviors 10, 11 and 15, edge E11).
final class Format2CoordinatorHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/f2-coord-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    /// A coordinator with one bound large document.
    private func makeCoordinator(
        documentIds: [String] = ["d"]
    ) async throws -> Format2Coordinator {
        let provider = try await makeProvider()
        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        for documentId in documentIds {
            try coordinator.bind(documentId: documentId, models: ["Note"])
        }
        return coordinator
    }

    // MARK: - Behavior 15 — the join handshake

    func testEpochInfoJoinSetsTheMarksAndReleasesTheHold() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))

        // A document binds HELD: nothing local may go out before the room has
        // said what epoch this client is on.
        XCTAssertTrue(coordinator.hold.isHeld("d"))
        coordinator.hold.enqueue("d", frame: "queued-before-the-handshake")

        let outcome = try coordinator.handleEpochInfo([
            "type": "epoch.info",
            "documentId": "d",
            "documentFormat": 2,
            "epoch": 0,
            "sealedEpochs": [],
            "serverTime": 1_700_000_000_500,
            "offlineWindowDays": 14,
        ], now: 1_700_000_000_000)

        XCTAssertEqual(outcome.plan, .join)
        XCTAssertEqual(try binding.store.epoch(), 0)
        XCTAssertEqual(try binding.store.lastSyncAt(), 1_700_000_000_000)
        XCTAssertEqual(try binding.store.offlineWindowDays(), 14)
        XCTAssertTrue(
            try binding.store.clockOffsetKnown(),
            "the handshake carries server time, so the offset is measured, not assumed"
        )
        XCTAssertEqual(try binding.store.clockOffset(), 500)

        XCTAssertFalse(coordinator.hold.isHeld("d"), "the hold did not release")
        XCTAssertEqual(
            outcome.released, ["queued-before-the-handshake"],
            "a write queued before the frame must go out after it"
        )
    }

    func testAClientAlreadyOnTheRoomsEpochJoins() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))
        try binding.store.setEpoch(7)

        let outcome = try coordinator.handleEpochInfo([
            "type": "epoch.info", "documentId": "d", "documentFormat": 2,
            "epoch": 7, "sealedEpochs": [], "serverTime": 1_700_000_000_000,
            "offlineWindowDays": 14,
        ], now: 1_700_000_000_000)

        XCTAssertEqual(outcome.plan, .join)
        XCTAssertEqual(try binding.store.epoch(), 7)
        XCTAssertFalse(coordinator.hold.isHeld("d"))
    }

    /// A COLD client joins the room's open epoch when nothing has been sealed
    /// yet — `planColdStart`'s own first rule, and the case every large
    /// document starts in.
    ///
    /// The room opens a document at epoch 1 (`FIRST_EPOCH`) while a client
    /// that has never seen it holds 0, so "the marks must already agree" would
    /// refuse every first open there is. Nothing is missing from such a
    /// client's view: an empty sealed chain means the whole document is the
    /// open epoch's overlay, which sync is about to hand it.
    func testAColdClientJoinsAnOpenEpochWithNothingSealedBehindIt() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))
        XCTAssertEqual(try binding.store.epoch(), 0, "precondition: a cold client")

        let outcome = try coordinator.handleEpochInfo([
            "type": "epoch.info", "documentId": "d", "documentFormat": 2,
            "epoch": 1, "sealedEpochs": [], "serverTime": 1_700_000_000_000,
            "offlineWindowDays": 14,
        ], now: 1_700_000_000_000)

        XCTAssertEqual(outcome.plan, .join)
        XCTAssertEqual(try binding.store.epoch(), 1)
        XCTAssertFalse(coordinator.hold.isHeld("d"))
    }

    /// A cold client whose room HAS sealed epochs is stopped, not joined: the
    /// document's content is in those archives and in a base, and reading the
    /// open overlay alone would show a document with almost nothing in it.
    /// Loading it is #3436's phase B and #3437's chain.
    func testAColdClientWithASealedChainIsHeldForAReload() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))

        let outcome = try coordinator.handleEpochInfo([
            "type": "epoch.info", "documentId": "d", "documentFormat": 2,
            "epoch": 3,
            "sealedEpochs": [["epoch": 1, "sealedAt": 1], ["epoch": 2, "sealedAt": 2]],
            "serverTime": 1_700_000_000_000, "offlineWindowDays": 14,
        ], now: 1_700_000_000_000)

        XCTAssertEqual(outcome.plan, .reloadRequired)
        XCTAssertEqual(try binding.store.epoch(), 0, "nothing was joined")
        XCTAssertTrue(coordinator.hold.isHeld("d"))
        XCTAssertTrue(binding.reloadRequired)
    }

    /// A client BEHIND the room is never made current by the handshake alone:
    /// the chain between the two epochs has to be applied first, and with
    /// NOTHING sealed there is no chain to apply (#3437, behaviors 16 and 18).
    ///
    /// #3436 held such a document at the handshake. It is handed to the
    /// catch-up now — but a catch-up with an empty chain refuses, so the
    /// document still ends up held, reading from the view it has, with its
    /// mark untouched.
    func testAClientBehindTheRoomWithNothingSealedEndsUpHeld() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))
        try binding.store.setEpoch(2)

        let outcome = try coordinator.handleEpochInfo([
            "type": "epoch.info", "documentId": "d", "documentFormat": 2,
            "epoch": 4, "sealedEpochs": [], "serverTime": 1_700_000_000_000,
            "offlineWindowDays": 14,
        ], now: 1_700_000_000_000)

        XCTAssertEqual(outcome.plan, .catchUp)
        XCTAssertEqual(try binding.store.epoch(), 2, "the mark is not moved under it")
        XCTAssertTrue(coordinator.hold.isHeld("d"))

        let fetched = LockedBox(0)
        let caughtUp = try await coordinator.runCatchUp(
            documentId: "d", target: outcome.reported, sealed: outcome.sealed,
            fetch: { _ in
                fetched.withValue { $0 += 1 }
                return Data()
            },
            now: 1_700_000_000_000
        )
        XCTAssertEqual(
            caughtUp, .reload(reason: .gap, epoch: 2),
            "the chain skips the epoch this client holds, so nothing available "
                + "says what happened in it"
        )
        XCTAssertEqual(fetched.value, 0, "and nothing was downloaded to find out")
        XCTAssertEqual(try binding.store.epoch(), 2)
        XCTAssertTrue(binding.reloadRequired)
        XCTAssertTrue(coordinator.hold.isHeld("d"))
    }

    /// E11 — `epoch.info` for a document that is not open, or a malformed
    /// frame, is DROPPED. Never treated as a join: a join moves the epoch
    /// mark, and moving it for a document nobody is holding would tell the
    /// next open that it is current when it is not.
    func testEpochInfoForAnUnopenedOrMalformedFrameIsDropped() async throws {
        let coordinator = try await makeCoordinator()

        let unopened = try coordinator.handleEpochInfo([
            "type": "epoch.info", "documentId": "not-open", "documentFormat": 2,
            "epoch": 3, "sealedEpochs": [], "serverTime": 1, "offlineWindowDays": 14,
        ], now: 1)
        XCTAssertEqual(unopened.plan, .dropped)

        // No `epoch` at all: the one field the decision is made from.
        let malformed = try coordinator.handleEpochInfo([
            "type": "epoch.info", "documentId": "d", "documentFormat": 2,
        ], now: 1)
        XCTAssertEqual(malformed.plan, .dropped)

        let binding = try XCTUnwrap(coordinator.binding("d"))
        XCTAssertEqual(try binding.store.epoch(), 0, "a dropped frame moved the epoch mark")
        XCTAssertTrue(
            coordinator.hold.isHeld("d"),
            "a dropped frame released the hold — the document is still unanswered"
        )
    }

    // MARK: - Behavior 10 — update.ack

    func testAnAckPrunesAtOrBelowTheMarkAndRecordsIt() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))
        for index in 1...3 {
            _ = try binding.writePath.write(
                model: "Note",
                mutation: OverlayMutation(
                    id: "r\(index)", kind: .create, fields: ["t": .string("x")]
                ),
                fields: ["t"]
            )
        }

        let pruned = try coordinator.handleUpdateAck([
            "type": "update.ack", "documentId": "d", "maxContiguousSeq": 2,
        ])
        XCTAssertEqual(pruned, 2)
        XCTAssertEqual(try binding.store.pendingOps().map(\.seq), [3])
        XCTAssertEqual(try binding.store.ackedSeq(), 2)
    }

    func testALowerOrRepeatedAckChangesNothing() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))
        _ = try binding.writePath.write(
            model: "Note",
            mutation: OverlayMutation(id: "r1", kind: .create, fields: ["t": .string("x")]),
            fields: ["t"]
        )
        _ = try binding.writePath.write(
            model: "Note",
            mutation: OverlayMutation(id: "r2", kind: .create, fields: ["t": .string("x")]),
            fields: ["t"]
        )
        _ = try coordinator.handleUpdateAck([
            "type": "update.ack", "documentId": "d", "maxContiguousSeq": 2,
        ])

        _ = try coordinator.handleUpdateAck([
            "type": "update.ack", "documentId": "d", "maxContiguousSeq": 1,
        ])
        XCTAssertEqual(try binding.store.ackedSeq(), 2, "a lower ack lowered the mark")
        _ = try coordinator.handleUpdateAck([
            "type": "update.ack", "documentId": "d", "maxContiguousSeq": 2,
        ])
        XCTAssertEqual(try binding.store.pendingOps().count, 0)
    }

    func testAnAckForAnotherDocumentPrunesNothingHere() async throws {
        let coordinator = try await makeCoordinator(documentIds: ["a", "b"])
        let a = try XCTUnwrap(coordinator.binding("a"))
        let b = try XCTUnwrap(coordinator.binding("b"))
        for binding in [a, b] {
            _ = try binding.writePath.write(
                model: "Note",
                mutation: OverlayMutation(id: "r1", kind: .create, fields: ["t": .string("x")]),
                fields: ["t"]
            )
        }

        _ = try coordinator.handleUpdateAck([
            "type": "update.ack", "documentId": "a", "maxContiguousSeq": 1,
        ])
        XCTAssertEqual(try a.store.pendingOps().count, 0)
        XCTAssertEqual(try b.store.pendingOps().count, 1, "a sibling's log was pruned")
    }

    func testAnAckForADocumentThatIsNotOpenIsDropped() async throws {
        let coordinator = try await makeCoordinator()
        XCTAssertNil(
            try coordinator.handleUpdateAck([
                "type": "update.ack", "documentId": "not-open", "maxContiguousSeq": 5,
            ])
        )
    }

    // MARK: - Behavior 11 — the outbound stamps

    func testAFormatTwoUpdateFrameCarriesSeqSeqFromAndAckedSeq() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))
        for index in 1...3 {
            _ = try binding.writePath.write(
                model: "Note",
                mutation: OverlayMutation(
                    id: "r\(index)", kind: .create, fields: ["t": .string("x")]
                ),
                fields: ["t"]
            )
            // The update carrying this write is enqueued now, so the sequence
            // it covers is noted now — the three of them merge into one frame.
            try coordinator.noteLocalUpdate(documentId: "d")
        }
        _ = try coordinator.handleUpdateAck([
            "type": "update.ack", "documentId": "d", "maxContiguousSeq": 1,
        ])

        let stamps = try XCTUnwrap(
            try coordinator.outboundClaim(documentId: "d", covering: 3)?.stamps
        )
        XCTAssertEqual(stamps.seq, 3, "the highest sequence the frame carries")
        XCTAssertEqual(stamps.seqFrom, 1, "the lowest sequence the frame carries")
        XCTAssertEqual(stamps.ackedSeq, 1, "and the mark the server already holds")
    }

    func testAFormatOneDocumentGetsNoStamps() async throws {
        let coordinator = try await makeCoordinator()
        XCTAssertNil(
            try coordinator.outboundClaim(documentId: "an-ordinary-document", covering: 1),
            "an ordinary document's update frame carries none of these fields"
        )
    }

    /// The claim is what the frame CARRIES, never everything above the acked
    /// mark. The server takes `[seqFrom, seq]` as proof that every sequence in
    /// it committed (`AckTracker.record`), so a frame claiming a sequence whose
    /// content is still in the NEXT frame gets that write acknowledged — and
    /// pruned from `_pending_ops` — although the frame carrying it may never
    /// arrive.
    func testAFrameNeverClaimsASequenceTheNextFrameCarries() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))

        _ = try binding.writePath.write(
            model: "Note",
            mutation: OverlayMutation(id: "r1", kind: .create, fields: ["t": .string("x")]),
            fields: ["t"]
        )
        try coordinator.noteLocalUpdate(documentId: "d")
        let firstClaim = try XCTUnwrap(
            try coordinator.outboundClaim(documentId: "d", covering: 1)
        )
        let first = try XCTUnwrap(firstClaim.stamps)
        coordinator.markSent(documentId: "d", claim: firstClaim)
        XCTAssertEqual([first.seqFrom, first.seq], [1, 1])

        // The second write's content is in the SECOND frame. Nothing has been
        // acknowledged yet, so "everything above the acked mark" would be
        // [1, 2] — a claim on the first frame's sequence as well.
        _ = try binding.writePath.write(
            model: "Note",
            mutation: OverlayMutation(id: "r2", kind: .create, fields: ["t": .string("x")]),
            fields: ["t"]
        )
        try coordinator.noteLocalUpdate(documentId: "d")
        let second = try XCTUnwrap(
            try coordinator.outboundClaim(documentId: "d", covering: 1)?.stamps
        )
        XCTAssertEqual(second.ackedSeq, 0, "nothing has been acknowledged yet")
        XCTAssertEqual(
            [second.seqFrom, second.seq], [2, 2],
            "the second frame claimed a sequence whose content the first one carried"
        )
    }

    /// The same rule against the other door it can be opened by: a flush does
    /// not always send everything queued. `mergeBudgetPrefix` merges the
    /// longest prefix of the queue that fits one frame and leaves the rest for
    /// the next pass, so a claim over EVERYTHING enqueued gets a write whose
    /// bytes are still in the queue acknowledged and pruned.
    func testAPartialBatchClaimsOnlyTheUpdatesItCarries() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))
        for index in 1...3 {
            _ = try binding.writePath.write(
                model: "Note",
                mutation: OverlayMutation(
                    id: "r\(index)", kind: .create, fields: ["t": .string("x")]
                ),
                fields: ["t"]
            )
            try coordinator.noteLocalUpdate(documentId: "d")
        }

        // The budget fits only the first two of the three queued updates.
        let partial = try XCTUnwrap(
            try coordinator.outboundClaim(documentId: "d", covering: 2)
        )
        let stamps = try XCTUnwrap(partial.stamps)
        XCTAssertEqual(
            [stamps.seqFrom, stamps.seq], [1, 2],
            "the frame claimed a sequence carried by an update it left in the queue"
        )
        coordinator.markSent(documentId: "d", claim: partial)

        // And the update left behind still has its sequence to claim.
        let rest = try XCTUnwrap(
            try coordinator.outboundClaim(documentId: "d", covering: 1)?.stamps
        )
        XCTAssertEqual(
            [rest.seqFrom, rest.seq], [3, 3],
            "the next frame claims what the first one left"
        )
    }

    /// A write enqueued between the batch being chosen and the frame being
    /// stamped is in no frame yet, so it may not be claimed by this one.
    func testAWriteEnqueuedAfterTheBatchWasChosenIsNotClaimed() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))
        _ = try binding.writePath.write(
            model: "Note",
            mutation: OverlayMutation(id: "r1", kind: .create, fields: ["t": .string("x")]),
            fields: ["t"]
        )
        try coordinator.noteLocalUpdate(documentId: "d")

        // The flush chose a batch of one. Another write lands before the frame
        // is stamped.
        _ = try binding.writePath.write(
            model: "Note",
            mutation: OverlayMutation(id: "r2", kind: .create, fields: ["t": .string("x")]),
            fields: ["t"]
        )
        try coordinator.noteLocalUpdate(documentId: "d")

        let stamps = try XCTUnwrap(
            try coordinator.outboundClaim(documentId: "d", covering: 1)?.stamps
        )
        XCTAssertEqual(
            [stamps.seqFrom, stamps.seq], [1, 1],
            "the frame claimed a write that was not in the batch it carries"
        )
    }

    func testAFrameWithNothingEnqueuedClaimsNothing() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))
        _ = try binding.writePath.write(
            model: "Note",
            mutation: OverlayMutation(id: "r1", kind: .create, fields: ["t": .string("x")]),
            fields: ["t"]
        )
        try coordinator.noteLocalUpdate(documentId: "d")
        XCTAssertNotNil(try coordinator.outboundClaim(documentId: "d", covering: 1))

        // A frame that carries no local write of this document — a remote
        // update echoed back, an awareness flush — claims nothing, and the
        // claim it would have made is not reissued.
        XCTAssertNil(
            try coordinator.outboundClaim(documentId: "d", covering: 1),
            "the same sequences were claimed by two frames"
        )
    }

    func testAFailedSendPutsTheClaimBackOnTheQueue() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))
        _ = try binding.writePath.write(
            model: "Note",
            mutation: OverlayMutation(id: "r1", kind: .create, fields: ["t": .string("x")]),
            fields: ["t"]
        )
        try coordinator.noteLocalUpdate(documentId: "d")

        let claim = try XCTUnwrap(
            try coordinator.outboundClaim(documentId: "d", covering: 1)
        )
        coordinator.restoreClaim(documentId: "d", claim: claim)

        // The frame never went out, so the next one carries that write and
        // claims it from the same place.
        let retry = try XCTUnwrap(
            try coordinator.outboundClaim(documentId: "d", covering: 1)?.stamps
        )
        XCTAssertEqual([retry.seqFrom, retry.seq], [1, 1])
    }

    /// The claim is made for a document this coordinator holds, and for no
    /// other. What the frame then CARRIES — the JS field names, and that
    /// nothing it already held was disturbed — is asserted on a real frame the
    /// socket received, in `Format2ClientHoldHermeticTests`.
    func testNoClaimIsMadeForADocumentThisClientDoesNotHold() async throws {
        let coordinator = try await makeCoordinator()
        XCTAssertNil(try coordinator.outboundClaim(documentId: "other", covering: 1))
    }
}
