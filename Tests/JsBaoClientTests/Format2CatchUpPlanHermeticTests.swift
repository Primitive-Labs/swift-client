import XCTest
@testable import JsBaoClient
import YSwift

/// A document behind the room: what it refuses, and how the handshake gets it
/// current (#3437, behaviors 3, 17 and 18, edges E2, E5 and E15).
///
/// ## Why an inbound frame must not reach the held overlay
///
/// Swift sends `syncStep1` for an open document as soon as the socket is up,
/// and the room answers with its CURRENT epoch's state. For a document behind
/// the room that state belongs to an epoch this client has never held, and
/// `DocumentManager` would apply it straight into the Y.Doc the client is still
/// writing to — the HELD epoch's overlay.
///
/// Suspending the FOLD is not enough. The move's carry reads each owed
/// record's value off that overlay, and a Yjs merge of two independent epoch
/// documents can let the peer's value win the key before the carry reads it
/// (finding 3437-SO-01). So while a document is behind the room, nothing the
/// room sends for its current epoch is merged into the held overlay at all; the
/// fresh document's resync re-delivers it.
///
/// Cold plans do NOT need this: a cold client's open Y.Doc IS the room's
/// current overlay, which is why `snapshot(base < reported)` and
/// `overlays(base:)` apply their chain UNDER it and refold it rather than
/// swapping anything.
final class Format2CatchUpPlanHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(atPath: directory)
        }
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
        let document: YDocument
        let replaced: LockedBox<[(String, YDocument)]>
    }

    private func makeFixture(heldEpoch: Int) async throws -> Fixture {
        let directory = NSTemporaryDirectory() + "/f2-cu-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")

        let documentId = "cu-\(UUID().uuidString.prefix(8))"
        let document = YDocument()
        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        let replaced = LockedBox<[(String, YDocument)]>([])
        coordinator.replaceDocument = { id, fresh in
            replaced.withValue { $0.append((id, fresh)) }
        }
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: document
        )
        let shared = MultiDocModel(schema: Self.schema)
        let model = shared.connect(docId: documentId, doc: document)
        model.bindFormat2(binding)
        if heldEpoch > 0 { try binding.store.setEpoch(heldEpoch) }
        return Fixture(
            coordinator: coordinator, binding: binding, model: model,
            documentId: documentId, document: document, replaced: replaced
        )
    }

    private func chainEntry(
        _ epoch: Int, sealedAt: Int = 0, flagged: Bool = false, granted: Bool = true
    ) -> [String: Any] {
        var out: [String: Any] = ["epoch": epoch, "sealedAt": sealedAt]
        if flagged { out["baseDiscontinuity"] = true }
        if granted { out["download"] = ["path": "/grants/epoch-\(epoch)"] }
        return out
    }

    private func archive(_ entries: [(String, JSONValue)]) -> Data {
        let overlay = OverlayDocument()
        overlay.applyRawEntries(entries, model: "Note")
        return Data(overlay.encodeStateAsUpdate())
    }

    // MARK: - Behavior 17 and edge E15 — inbound isolation

    func testADocumentBehindTheRoomRefusesInboundFramesUntilItHasMoved() async throws {
        let fixture = try await makeFixture(heldEpoch: 3)
        XCTAssertTrue(
            fixture.coordinator.acceptsInbound(fixture.documentId),
            "a document that is not behind the room applies inbound frames "
                + "exactly as it always did"
        )

        let outcome = try fixture.coordinator.handleEpochInfo(
            [
                "documentId": fixture.documentId, "epoch": 5,
                "sealedEpochs": [chainEntry(3), chainEntry(4)],
            ],
            now: 1_000
        )
        XCTAssertEqual(outcome.plan, .catchUp)
        XCTAssertFalse(
            fixture.coordinator.acceptsInbound(fixture.documentId),
            "from the handshake to the move, the held overlay stays the "
                + "client's own"
        )
        XCTAssertTrue(
            fixture.binding.observer.remoteFoldsSuspended,
            "and what did arrive before the gate went up is not folded over "
                + "the view the chain is about to be applied to"
        )

        let archives: [Int: Data] = [
            3: archive([("r1/title", .string("from 3"))]),
            4: archive([("r1/body", .string("from 4"))]),
        ]
        let caughtUp = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId,
            target: outcome.reported,
            sealed: outcome.sealed,
            fetch: { archives[$0.epoch] ?? Data() },
            now: 2_000
        )
        XCTAssertEqual(caughtUp, .caughtUp(applied: [3, 4], epoch: 5))
        XCTAssertTrue(
            fixture.coordinator.acceptsInbound(fixture.documentId),
            "the fresh document's resync re-delivers the current epoch, which "
                + "folds normally"
        )
        XCTAssertFalse(fixture.binding.observer.remoteFoldsSuspended)
    }

    func testADroppedInboundFrameIsLoggedOncePerCatchUpAndNotPerFrame() async throws {
        let fixture = try await makeFixture(heldEpoch: 3)
        _ = try fixture.coordinator.handleEpochInfo(
            [
                "documentId": fixture.documentId, "epoch": 5,
                "sealedEpochs": [chainEntry(3), chainEntry(4)],
            ],
            now: 1_000
        )

        for _ in 0..<5 {
            XCTAssertFalse(fixture.coordinator.admitInbound(fixture.documentId))
        }
        XCTAssertEqual(
            fixture.coordinator.inboundDropLogCount(fixture.documentId), 1,
            "one line per document per catch-up: a burst of frames behind the "
                + "room is one fact, and a line per frame would bury it"
        )
        XCTAssertEqual(
            fixture.coordinator.droppedInboundFrameCount(fixture.documentId), 5,
            "every one of them was refused, though"
        )
    }

    /// A catch-up that arrives to find nothing to apply has been OVERTAKEN:
    /// the seal it was planned for was followed in place before it ran.
    ///
    /// The two live on different frames, so the handshake's plan can be taken
    /// on one epoch and its catch-up run on the next. Everything the plan took
    /// — the inbound gate, the suspended folds, and the outbound hold — is
    /// undone by the MOVE at the end of a chain, and a catch-up with no chain
    /// to apply never reaches it. A hold the handshake set after the move had
    /// already released its own then has nothing left to release it: the
    /// document keeps answering reads and committing writes, and not one of
    /// them ever reaches the room again.
    ///
    /// Found live (#3437): `Format2EpochMoveLiveTests`' connected-seal row
    /// timed out with its writes queued, its epoch moved and its refusal clear
    /// — the silent shape this is about.
    func testACatchUpOvertakenByASealReleasesEverythingThePlanTook() async throws {
        let fixture = try await makeFixture(heldEpoch: 3)

        // The seal, followed in place: the move installs a fresh overlay,
        // writes the mark, and releases the hold it was under.
        let moved = try await fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 4, now: 1_000
        )
        XCTAssertEqual(moved, .moved(epoch: 4))

        // The handshake that was in flight while it ran: it read the epoch
        // BEFORE the mark moved, so it plans a catch-up and takes the
        // document's overlay, its folds and its outbound queue — after the
        // move's release.
        fixture.coordinator.noteBehindTheRoom(fixture.binding)
        XCTAssertTrue(fixture.coordinator.hold.isHeld(fixture.documentId))

        let outcome = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId,
            target: 4,
            sealed: [SealedEpochChainEntry(epoch: 3, downloadPath: "/g/3")],
            fetch: { _ in XCTFail("nothing is owed"); return Data() },
            now: 2_000
        )
        XCTAssertEqual(
            outcome, .none(reason: .current),
            "the mark already agrees with the room: there is no chain to apply"
        )

        XCTAssertFalse(
            fixture.coordinator.hold.isHeld(fixture.documentId),
            "and nothing else is coming to release it: a document held here "
                + "queues every write it ever makes and sends none of them"
        )
        XCTAssertTrue(
            fixture.coordinator.acceptsInbound(fixture.documentId),
            "it is not behind the room, so the room's frames are its own again"
        )
        XCTAssertFalse(
            fixture.binding.observer.remoteFoldsSuspended,
            "and what they carry is folded rather than captured and forgotten"
        )
    }

    func testAJoinedLargeDocumentAndAnOrdinaryOneKeepApplyingFrames() async throws {
        let fixture = try await makeFixture(heldEpoch: 0)
        _ = try fixture.coordinator.handleEpochInfo(
            ["documentId": fixture.documentId, "epoch": 0, "sealedEpochs": []],
            now: 1_000
        )
        XCTAssertTrue(
            fixture.coordinator.admitInbound(fixture.documentId),
            "a large document that JOINED is current; nothing about it is behind"
        )
        XCTAssertTrue(
            fixture.coordinator.admitInbound("some-format-1-document"),
            "and a document this coordinator does not hold is not its business "
                + "at all — every format-1 document applies frames as before"
        )
        XCTAssertEqual(fixture.coordinator.inboundDropLogCount(fixture.documentId), 0)
    }

    func testTheCarriedValueIsTheClientsOwnEvenWhenAPeerWroteTheKeyMeanwhile()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 3)
        // Written offline, on the epoch this client holds, and never
        // acknowledged.
        _ = try fixture.model.create(id: "r1", values: ["title": .string("mine")])
        XCTAssertEqual(try fixture.binding.store.pendingOps().map(\.seq), [1])

        let outcome = try fixture.coordinator.handleEpochInfo(
            [
                "documentId": fixture.documentId, "epoch": 5,
                "sealedEpochs": [chainEntry(3), chainEntry(4)],
            ],
            now: 1_000
        )
        XCTAssertEqual(outcome.plan, .catchUp)

        // The room answers this client's `syncStep1` with its CURRENT epoch,
        // carrying a peer's newer value for the very key the pending write
        // touched. It must not reach the held overlay: the carry reads that
        // overlay, and a Yjs merge of two independent epoch documents can let
        // the peer's value win the key first (finding 3437-SO-01).
        let peer = OverlayDocument()
        peer.applyRawEntries([("r1/title", .string("a peer's"))], model: "Note")
        let peerFrame = peer.encodeStateAsUpdate()
        if fixture.coordinator.admitInbound(fixture.documentId) {
            try fixture.binding.overlay.applyUpdate(peerFrame)
            XCTFail("a document behind the room must not admit the frame at all")
        }

        let archives: [Int: Data] = [
            3: archive([("r1/title", .string("mine"))]),
            4: archive([]),
        ]
        _ = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId,
            target: 5,
            sealed: outcome.sealed,
            fetch: { archives[$0.epoch] ?? Data() },
            now: 2_000
        )
        // A returning client's carry is DEFERRED (behavior 20), so the value
        // reaches the fresh overlay when the judgement states it — with no
        // measured clock offset nothing is dropped on recency, so it stands.
        XCTAssertFalse(try fixture.binding.store.clockOffsetKnown())
        _ = try fixture.coordinator.completeDeferredReplay(
            documentId: fixture.documentId, now: 3_000
        )

        XCTAssertEqual(
            fixture.binding.overlay.value(model: "Note", key: "r1/title"),
            .string("mine"),
            "the value the judgement states is the CLIENT's, never the peer's: "
                + "the peer's frame was refused before the carry ever read the "
                + "overlay (finding 3437-SO-01)"
        )
    }

    func testALocalWriteDuringACatchUpCommitsAndIsCarried() async throws {
        let fixture = try await makeFixture(heldEpoch: 3)
        _ = try fixture.coordinator.handleEpochInfo(
            [
                "documentId": fixture.documentId, "epoch": 5,
                "sealedEpochs": [chainEntry(3), chainEntry(4)],
            ],
            now: 1_000
        )

        _ = try fixture.model.create(id: "during", values: ["title": .string("kept")])
        XCTAssertEqual(
            try fixture.binding.store.read(model: "Note", recordId: "during")?["title"],
            .string("kept"),
            "reads answer the merged view the whole way through (edge E5)"
        )

        let archives: [Int: Data] = [3: archive([]), 4: archive([])]
        _ = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId, target: 5, sealed: [
                SealedEpochChainEntry(epoch: 3, downloadPath: "/g/3"),
                SealedEpochChainEntry(epoch: 4, downloadPath: "/g/4"),
            ],
            fetch: { archives[$0.epoch] ?? Data() },
            now: 2_000
        )
        // The carry is deferred for a returning client, so the write reaches
        // the fresh overlay when the judgement states it (behavior 20).
        _ = try fixture.coordinator.completeDeferredReplay(
            documentId: fixture.documentId, now: 3_000
        )
        XCTAssertEqual(
            fixture.binding.overlay.value(model: "Note", key: "during/title"),
            .string("kept"),
            "a write that landed while the document was behind is owed and is "
                + "carried onto the fresh overlay"
        )
    }

    // MARK: - Behavior 18 — every handshake plan

    func testAColdBaseBelowTheRoomsEpochLoadsThenRunsTheChainWithNoSwap()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 0)
        let outcome = try fixture.coordinator.handleEpochInfo(
            [
                "documentId": fixture.documentId, "epoch": 6,
                "sealedEpochs": [chainEntry(4), chainEntry(5)],
                "snapshot": [
                    "epoch": 4, "buildId": "b1", "rows": 0,
                    "download": ["path": "/grants/base"],
                ],
            ],
            now: 1_000
        )
        XCTAssertEqual(outcome.plan, .loadBase)
        XCTAssertEqual(outcome.base?.epoch, 4)
        XCTAssertEqual(
            outcome.reported, 6,
            "the caller has to know how far above the base the room is"
        )
        XCTAssertEqual(
            outcome.sealed.map(\.epoch), [4, 5],
            "and which archives stand between them"
        )

        // The open Y.Doc IS the room's current overlay here, so the chain goes
        // UNDER it: apply 4 and 5, then refold what the document already holds.
        fixture.binding.overlay.applyRawEntries(
            [("r1/body", .string("open epoch"))], model: "Note"
        )
        let archives: [Int: Data] = [
            4: archive([("r1/title", .string("from 4"))]),
            5: archive([("r1/title", .string("from 5"))]),
        ]
        let completed = try fixture.coordinator.runColdChain(
            documentId: fixture.documentId,
            from: 4,
            to: 6,
            fetch: { archives[$0.epoch] ?? Data() },
            sealed: outcome.sealed,
            now: 2_000
        )
        XCTAssertEqual(completed.plan, .join)
        XCTAssertEqual(
            fixture.replaced.value.count, 0,
            "a cold start never swaps the document: it IS the room's overlay"
        )
        let row = try XCTUnwrap(
            fixture.binding.store.read(model: "Note", recordId: "r1")
        )
        XCTAssertEqual(row["title"], .string("from 5"))
        XCTAssertEqual(
            row["body"], .string("open epoch"),
            "the open overlay is refolded LAST, so the changes since the last "
                + "rotation are on top of the chain"
        )
        XCTAssertEqual(try fixture.binding.store.epoch(), 6)
        XCTAssertNotNil(try fixture.binding.store.lastSyncAt())
    }

    func testAnOverlaysOnlyPlanRunsTheChainFromTheFirstEpoch() async throws {
        let fixture = try await makeFixture(heldEpoch: 0)
        let outcome = try fixture.coordinator.handleEpochInfo(
            [
                "documentId": fixture.documentId, "epoch": 3,
                "sealedEpochs": [chainEntry(1), chainEntry(2)],
            ],
            now: 1_000
        )
        XCTAssertEqual(
            outcome.plan, .loadOverlays,
            "with no snapshot but a whole chain from the first epoch, the chain "
                + "IS the document"
        )
        XCTAssertEqual(outcome.base?.epoch, 1)

        let archives: [Int: Data] = [
            1: archive([("r1/title", .string("from 1"))]),
            2: archive([("r2/title", .string("from 2"))]),
        ]
        let completed = try fixture.coordinator.runColdChain(
            documentId: fixture.documentId,
            from: 1,
            to: 3,
            fetch: { archives[$0.epoch] ?? Data() },
            sealed: outcome.sealed,
            now: 2_000
        )
        XCTAssertEqual(completed.plan, .join)
        XCTAssertEqual(
            try fixture.binding.store.read(model: "Note", recordId: "r1")?["title"],
            .string("from 1")
        )
        XCTAssertEqual(
            try fixture.binding.store.read(model: "Note", recordId: "r2")?["title"],
            .string("from 2")
        )
        XCTAssertEqual(try fixture.binding.store.epoch(), 3)
        XCTAssertFalse(fixture.binding.reloadRequired)
    }

    func testAnUnavailablePlanStillStopsTheDocument() async throws {
        let fixture = try await makeFixture(heldEpoch: 0)
        let outcome = try fixture.coordinator.handleEpochInfo(
            [
                "documentId": fixture.documentId, "epoch": 6,
                // No base, and a chain that does not start at the first epoch.
                "sealedEpochs": [chainEntry(4), chainEntry(5)],
            ],
            now: 1_000
        )
        XCTAssertEqual(outcome.plan, .reloadRequired)
        XCTAssertTrue(fixture.binding.reloadRequired)
    }

    // MARK: - Edge E2 — a seal that skips epochs

    func testASealThatSkipsEpochsIsHandedToTheCatchUpRatherThanStopped()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 3)
        let decision = try fixture.coordinator.handleEpochSeal([
            "type": "epoch.seal", "documentId": fixture.documentId,
            "epoch": 5, "next": 6,
        ])
        XCTAssertEqual(
            decision, .catchUp(from: 3, to: 6),
            "moving one step would leave the chain unapplied and the merged "
                + "view short of everything those epochs held"
        )
        XCTAssertFalse(
            fixture.coordinator.acceptsInbound(fixture.documentId),
            "and from here the held overlay is the client's own until the chain "
                + "has landed"
        )
        XCTAssertFalse(
            fixture.binding.reloadRequired,
            "a chain that has not been tried yet is not a document that has to "
                + "be reloaded"
        )
    }

    // MARK: - Behavior 3 — the fourth door

    func testACompletedBaseLoadEarnsTheOfflineWindowsMark() async throws {
        let fixture = try await makeFixture(heldEpoch: 0)
        XCTAssertNil(try fixture.binding.store.lastSyncAt())

        // An empty base: the mark is what this case is about, and a base with
        // no chunks still completes a load.
        let manifest: [String: Any] = [
            "version": 2, "epoch": 4, "buildId": "b1", "createdAt": 0,
            "schema": ["Note": ["stringSetFields": []]],
            "chunks": [], "totals": ["rows": 0, "bytes": 0],
        ]
        let body = try JSONSerialization.data(withJSONObject: manifest)
        let source = Format2SnapshotSource(
            apiUrl: "https://example.test",
            documentId: fixture.documentId,
            grantPath: "/grants/base",
            logger: Logger(level: .none),
            read: { _ in Format2SnapshotSource.Answer(status: 200, body: body) }
        )
        let outcome = try fixture.coordinator.runBaseLoad(
            documentId: fixture.documentId,
            base: Format2Coordinator.BaseToLoad(
                epoch: 4, grantPath: "/grants/base", rows: 0
            ),
            source: source,
            now: 7_000
        )
        XCTAssertEqual(outcome.plan, .join)
        XCTAssertEqual(
            try fixture.binding.store.lastSyncAt(), 7_000,
            "a completed base load is a reconciliation with the server, so it "
                + "earns the mark exactly as a join does"
        )
    }

    // MARK: - Edge E3 — a seal landing under work already in flight

    /// A seal that arrives while a base load or a chain is running lets that
    /// work finish into NOTHING, and the document re-plans from a fresh
    /// handshake.
    ///
    /// The base a load is streaming was cut for an epoch the room has just
    /// replaced, so its completion may not set the mark, clear the refusal or
    /// release the hold — all three are statements about the CURRENT state of
    /// the document, and a seal has just made them false. An `epoch.seal`
    /// carries no chain, so what the document needs next is an `epoch.info`:
    /// the second `syncStep1` on the same connection draws one, because the
    /// room sends `epoch.info` on every handshake it answers.
    func testASealUnderALoadInFlightSupersedesItAndTheNextHandshakeRePlans()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 3)
        let attempt = fixture.coordinator.beginBaseLoad(fixture.documentId)
        XCTAssertTrue(
            fixture.coordinator.baseLoadIsCurrent(fixture.documentId, attempt: attempt)
        )

        let decision = try fixture.coordinator.handleEpochSeal([
            "type": "epoch.seal", "documentId": fixture.documentId,
            "epoch": 5, "next": 6,
        ])
        XCTAssertEqual(decision, .catchUp(from: 3, to: 6))
        XCTAssertFalse(
            fixture.coordinator.baseLoadIsCurrent(fixture.documentId, attempt: attempt),
            "the work in flight finishes into nothing"
        )
        XCTAssertEqual(
            try fixture.binding.store.epoch(), 3,
            "and nothing has moved: the mark is where it was"
        )

        // The fresh handshake, which is what carries the chain.
        let replanned = try fixture.coordinator.handleEpochInfo(
            [
                "documentId": fixture.documentId, "epoch": 6,
                "sealedEpochs": [
                    chainEntry(3), chainEntry(4), chainEntry(5),
                ],
            ],
            now: 8_000
        )
        XCTAssertEqual(replanned.plan, .catchUp)
        XCTAssertEqual(replanned.reported, 6)
        XCTAssertEqual(
            replanned.sealed.map(\.epoch), [3, 4, 5],
            "re-planned from what the fresh frame says, not from what the "
                + "seal left behind"
        )
    }
}
