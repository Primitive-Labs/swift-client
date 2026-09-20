import XCTest
import YSwift
@testable import JsBaoClient

/// What the handshake does with each plan, and what a seal does to an open
/// document (#3436, behaviors 26 and 30, decision 3436-SO-03).
///
/// This child honours exactly two plans: `join`, and a COLD client's snapshot
/// whose base covers the epoch the room reports. Everything else stops the
/// document. That is not caution — refolding an old-epoch overlay over a fresh
/// base can resurrect a tombstone or a `_replace`, which is precisely what the
/// JS cold-start module forbids on its stale path, and following the chain
/// instead is #3437's epoch handoff. So the assertions here are as much about
/// what does NOT happen as about what does.
final class Format2HandshakePlanHermeticTests: XCTestCase {

    /// Load events arrive on whatever thread the load runs on.
    private final class HandshakeEventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DocumentSnapshotLoadEvent] = []
        func append(_ event: DocumentSnapshotLoadEvent) {
            lock.withLock { events.append(event) }
        }
        var all: [DocumentSnapshotLoadEvent] { lock.withLock { events } }
    }


    private var directories: [String] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directories = []
        super.tearDown()
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/f2-plan-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeCoordinator(
        documentId: String = "d", document: YDocument = YDocument()
    ) async throws -> Format2Coordinator {
        let provider = try await makeProvider()
        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        try coordinator.bind(
            documentId: documentId, models: ["Note"], document: document
        )
        return coordinator
    }

    private func sealed(_ epoch: Int, granted: Bool = true) -> [String: Any] {
        var entry: [String: Any] = ["epoch": epoch, "sealedAt": 1]
        if granted { entry["download"] = ["path": "/artifact/tok-\(epoch)"] }
        return entry
    }

    private func frame(
        documentId: String = "d",
        epoch: Int,
        sealed: [[String: Any]] = [],
        snapshot: [String: Any]? = nil
    ) -> [String: Any] {
        var frame: [String: Any] = [
            "type": "epoch.info",
            "documentId": documentId,
            "documentFormat": 2,
            "epoch": epoch,
            "sealedEpochs": sealed,
            "serverTime": 1_700_000_000_000,
            "offlineWindowDays": 30,
        ]
        if let snapshot { frame["snapshot"] = snapshot }
        return frame
    }

    /// A base the real encoder wrote, with the grant path a handshake offers.
    private struct Base {
        let manifest: [String: Any]
        let bodies: [String: Data]
        let grantPath = "/artifact/tok-base"
    }

    private func buildBase(
        epoch: Int, rows: [(id: String, data: String)]
    ) throws -> Base {
        let response = try Format2Harness.run([
            "command": "encode-chunk",
            "chunks": [[
                "key": "app/doc/\(epoch)-b1/Note/0.ndjson.gz",
                "path": "Note/0",
                "ordinal": 0,
                "model": "Note",
                "rows": rows.map { ["id": $0.id, "data": $0.data] },
            ] as [String: Any]],
        ])
        let encoded = try XCTUnwrap(response["chunks"] as? [[String: Any]])
        let entry = try XCTUnwrap(encoded[0]["entry"] as? [String: Any])
        let body = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(encoded[0]["body"] as? String))
        )
        let manifest: [String: Any] = [
            "version": 2, "epoch": epoch, "buildId": "b1", "createdAt": 0,
            "schema": ["Note": ["stringSetFields": []]],
            "chunks": [entry],
            "totals": [
                "rows": entry["rows"] as? Int ?? 0,
                "bytes": entry["bytes"] as? Int ?? 0,
            ],
        ]
        return Base(
            manifest: manifest,
            bodies: [try XCTUnwrap(entry["key"] as? String): body]
        )
    }

    private func source(
        _ base: Base, onRead: @escaping (URL) -> Void = { _ in }
    ) -> Format2SnapshotSource {
        Format2SnapshotSource(
            apiUrl: "https://api.example.test",
            documentId: "d",
            grantPath: base.grantPath,
            read: { url in
                onRead(url)
                if url.path == base.grantPath {
                    return Format2SnapshotSource.Answer(
                        status: 200,
                        body: try JSONSerialization.data(withJSONObject: base.manifest)
                    )
                }
                let body = base.bodies.values.first!
                return Format2SnapshotSource.Answer(status: 200, body: body)
            }
        )
    }

    // MARK: - Behavior 26 — a cold client whose base covers the room

    func testAColdClientWithACoveringBaseLoadsItFoldsTheOverlayAndJoins() async throws {
        let document = YDocument()
        let coordinator = try await makeCoordinator(document: document)
        let binding = try XCTUnwrap(coordinator.binding("d"))
        let base = try buildBase(epoch: 5, rows: [
            (id: "n1", data: #"{"title":"from the base"}"#),
            (id: "n2", data: #"{"title":"also from the base"}"#),
        ])

        // The open epoch's overlay, which sync delivers as an ordinary Y.Doc
        // and which the base does NOT carry: a patch to a record the base has,
        // and a record the base has never heard of.
        try binding.writePath.withOperation {
            _ = binding.overlay.applyRawEntries([
                (OverlayKeys.fieldKey(recordId: "n1", field: "title"),
                 .string("edited in the open epoch")),
                (OverlayKeys.fieldKey(recordId: "n3", field: "title"),
                 .string("written in the open epoch")),
                (OverlayKeys.markerKey(recordId: "n3", marker: OverlayKeys.markerReplace),
                 .bool(true)),
            ], model: "Note")
        }
        coordinator.hold.enqueue("d", frame: "queued-before-the-cold-start")

        let events = HandshakeEventLog()
        coordinator.onSnapshotLoad = { events.append($0) }

        let planned = try coordinator.handleEpochInfo(
            frame(
                epoch: 5,
                sealed: [sealed(3), sealed(4)],
                snapshot: [
                    "epoch": 5, "buildId": "b1", "rows": 2, "manifestVersion": 2,
                    "download": ["path": base.grantPath, "expiresAt": 0],
                ]
            ),
            now: 1_700_000_000_000
        )
        XCTAssertEqual(planned.plan, .loadBase)
        XCTAssertEqual(planned.base?.epoch, 5)
        XCTAssertEqual(planned.base?.grantPath, base.grantPath)
        // Nothing has moved yet: the load is a download and it has not run.
        XCTAssertEqual(try binding.store.epoch(), 0)
        XCTAssertTrue(coordinator.hold.isHeld("d"))

        var read: [String] = []
        let outcome = try coordinator.runBaseLoad(
            documentId: "d",
            base: try XCTUnwrap(planned.base),
            source: source(base, onRead: { read.append($0.path) }),
            now: 1_700_000_000_000
        )

        XCTAssertEqual(outcome.plan, .join)
        XCTAssertEqual(read, ["/artifact/tok-base", "/artifact/tok-base/Note/0"])
        XCTAssertEqual(try binding.store.epoch(), 5, "the epoch mark moved onto the base")
        XCTAssertTrue(try XCTUnwrap(binding.store.baseState()).complete)
        XCTAssertFalse(coordinator.hold.isHeld("d"))
        XCTAssertEqual(outcome.released, ["queued-before-the-cold-start"])
        XCTAssertFalse(binding.reloadRequired, "no error: the document is current")

        // The base's rows are in, AND the open epoch's overlay is folded over
        // them — the part of the document the base does not carry.
        XCTAssertEqual(try binding.store.recordIds(model: "Note"), ["n1", "n2", "n3"])
        XCTAssertEqual(
            try binding.store.read(model: "Note", recordId: "n1")?["title"],
            .string("edited in the open epoch"),
            "the base overwrote the folded overlay and nothing folded it back"
        )
        XCTAssertEqual(
            try binding.store.read(model: "Note", recordId: "n2")?["title"],
            .string("also from the base")
        )
        XCTAssertEqual(
            try binding.store.read(model: "Note", recordId: "n3")?["title"],
            .string("written in the open epoch")
        )

        XCTAssertEqual(
            events.all.map(\.phase), [.started, .progress, .model, .loaded]
        )
        XCTAssertEqual(Set(events.all.map(\.mode)), ["load"])
        XCTAssertEqual(Set(events.all.map(\.epoch)), [5])
        XCTAssertEqual(events.all.last?.rows, 2)
        XCTAssertEqual(events.all.last?.totalChunks, 1)
        XCTAssertEqual(events.all.first(where: { $0.phase == .model })?.model, "Note")
    }

    // MARK: - Behavior 26 — everything this child stops

    /// A client BEHIND the room is never made current by the BASE, whatever
    /// the snapshot says. Its overlay belongs to an epoch the room has
    /// archived: folding it over a newer base would put back a record a later
    /// epoch deleted (decision 3436-SO-03).
    ///
    /// #3436 stopped such a document. #3437 hands it to the catch-up, which
    /// applies the sealed chain instead — but the base is still not loaded, the
    /// mark is still not moved by the handshake, the merged view is untouched
    /// and the owed writes are still owed, which is everything this case was
    /// written to protect.
    func testAClientBehindTheRoomIsNotMadeCurrentByTheBase() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))
        try binding.store.setEpoch(3)

        // A record this client DELETED in its own (now old) epoch, and an owed
        // write. The base the room is about to offer still carries `n1` — it
        // was cut before the delete — so "load it and fold the old overlay
        // over it" would put a deleted record back, which is exactly what
        // decision 3436-SO-03 forbids.
        try binding.store.applyRemote(
            model: "Note",
            entry: OverlayRecordEntry(id: "n1", fields: ["title": .string("local")], replace: true)
        )
        try binding.store.commitLocalWrite(
            model: "Note",
            mutation: OverlayMutation(id: "n2", kind: .create, fields: ["title": .string("owed")]),
            pending: PendingOpInput(
                model: "Note", recordId: "n2", op: .create,
                fields: ["title"], baseEpoch: 3, ts: 1
            )
        )
        try binding.writePath.withOperation {
            _ = binding.overlay.applyRawEntries([
                (OverlayKeys.markerKey(recordId: "n1", marker: OverlayKeys.markerDeleted),
                 .bool(true)),
            ], model: "Note")
            try binding.observer.drain()
        }
        XCTAssertNil(
            try binding.store.read(model: "Note", recordId: "n1"),
            "the delete is this epoch's own state, folded into this client's view"
        )
        let pendingBefore = try binding.store.pendingOps()
        let rowsBefore = try binding.store.recordIds(model: "Note")

        let outcome = try coordinator.handleEpochInfo(
            frame(
                epoch: 5,
                sealed: [sealed(3), sealed(4)],
                snapshot: [
                    "epoch": 5, "download": ["path": "/artifact/tok-base"],
                ]
            ),
            now: 1_700_000_000_000
        )

        XCTAssertEqual(outcome.plan, .catchUp)
        XCTAssertNil(outcome.base, "nothing to load: this client is not cold")
        XCTAssertEqual(
            outcome.sealed.map(\.epoch), [3, 4],
            "what it is handed instead is the chain between the two epochs"
        )
        XCTAssertFalse(
            coordinator.acceptsInbound("d"),
            "and from here its overlay is its own"
        )

        XCTAssertTrue(coordinator.hold.isHeld("d"), "the hold stays set")
        XCTAssertEqual(try binding.store.epoch(), 3, "the mark did not move")
        XCTAssertNil(try binding.store.baseState(), "nothing was loaded")
        // The merged view is NOT discarded: it is what keeps answering reads,
        // and it is exactly what it was before the frame arrived.
        XCTAssertEqual(try binding.store.recordIds(model: "Note"), rowsBefore)
        // The base was never fetched, so the record this client deleted in its
        // own epoch did not come back with it.
        XCTAssertNil(try binding.store.read(model: "Note", recordId: "n1"))
        // And the writes this client owes are still owed.
        XCTAssertEqual(try binding.store.pendingOps(), pendingBefore)
    }

    func testAWriteOnAStoppedDocumentIsRefusedWithoutPublishingAnything() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))
        // Stopped by a plan that still stops: a COLD client with no base and a
        // chain that has a hole in it. (A client behind the room is handed to
        // #3437's catch-up now, so it is no longer the shape that produces a
        // stopped document.)
        _ = try coordinator.handleEpochInfo(
            frame(epoch: 5, sealed: [sealed(3), sealed(4, granted: false)]), now: 1
        )
        XCTAssertTrue(binding.reloadRequired)

        let before = binding.overlay.encodeStateAsUpdate()
        XCTAssertThrowsError(
            try binding.writePath.write(
                model: "Note",
                mutation: OverlayMutation(id: "x", kind: .create, fields: ["t": .string("v")]),
                fields: ["t"]
            )
        ) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .format2ReloadRequired)
        }
        XCTAssertEqual(try binding.store.pendingOps().count, 0, "no pending op")
        XCTAssertEqual(binding.overlay.encodeStateAsUpdate(), before, "nothing published")
        // Reads keep answering.
        XCTAssertEqual(try binding.store.recordIds(model: "Note"), [])
    }

    /// The plans that STILL stop a document, now that #3437 honours the rest.
    ///
    /// Two shapes are left, and both are refusals rather than seams: a chain
    /// with a hole in it and no base to start from, and a base that came with
    /// no way to read it. `await-base` is the third and is phase C's.
    func testEveryPlanThatCannotBeHonouredStopsTheDocument() async throws {
        let cases: [(name: String, plan: String, frame: [String: Any])] = [
            (
                "a chain with a hole in it and no base",
                "unavailable",
                frame(epoch: 5, sealed: [sealed(3), sealed(4, granted: false)])
            ),
            (
                "a base that covers the room but came with no grant",
                "snapshot",
                frame(
                    epoch: 5, sealed: [sealed(3), sealed(4)],
                    snapshot: ["epoch": 5, "rows": 9]
                )
            ),
            (
                "a base that does not reach the room's epoch and came with no grant",
                "snapshot",
                frame(
                    epoch: 5, sealed: [sealed(3), sealed(4)],
                    snapshot: ["epoch": 4, "rows": 9]
                )
            ),
        ]

        for each in cases {
            let coordinator = try await makeCoordinator()
            let binding = try XCTUnwrap(coordinator.binding("d"))
            let outcome = try coordinator.handleEpochInfo(each.frame, now: 1)
            XCTAssertEqual(outcome.plan, .reloadRequired, each.name)
            XCTAssertEqual(
                binding.reloadRefusal?.details?["plan"], .string(each.plan), each.name
            )
            XCTAssertTrue(coordinator.hold.isHeld("d"), each.name)
            XCTAssertEqual(try binding.store.epoch(), 0, each.name)
            XCTAssertNil(try binding.store.baseState(), each.name)
        }
    }

    /// The window and the clock travel whatever else the frame says, including
    /// to a client that cannot act on the rest of it: they are facts about the
    /// deployment, not about this document's epoch.
    func testAStoppedDocumentStillLearnsTheWindowAndTheClockOffset() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))
        try binding.store.setEpoch(3)

        var stopped = frame(epoch: 5, sealed: [sealed(3), sealed(4)])
        stopped["serverTime"] = 1_700_000_000_750
        stopped["offlineWindowDays"] = 10
        _ = try coordinator.handleEpochInfo(stopped, now: 1_700_000_000_000)

        XCTAssertEqual(try binding.store.offlineWindowDays(), 10)
        XCTAssertEqual(try binding.store.clockOffset(), 750)
        // But NOT the sync mark, which says "this client is up to date".
        XCTAssertNil(try binding.store.lastSyncAt())
    }

    // MARK: - Behavior 30 — the seal hold

    func testASealHoldsTheDocumentAndRefusesWritesWhileKeepingReads() async throws {
        for kind in ["epoch.seal", "epoch.resync"] {
            let coordinator = try await makeCoordinator()
            let binding = try XCTUnwrap(coordinator.binding("d"))
            _ = try coordinator.handleEpochInfo(frame(epoch: 4), now: 1)
            XCTAssertFalse(coordinator.hold.isHeld("d"), kind)

            try binding.store.applyRemote(
                model: "Note",
                entry: OverlayRecordEntry(
                    id: "n1", fields: ["title": .string("kept")], replace: true
                )
            )
            try binding.store.commitLocalWrite(
                model: "Note",
                mutation: OverlayMutation(id: "n2", kind: .create, fields: ["t": .string("owed")]),
                pending: PendingOpInput(
                    model: "Note", recordId: "n2", op: .create,
                    fields: ["t"], baseEpoch: 4, ts: 1
                )
            )

            // A frame that SKIPS epochs: the sealed chain between this client
            // and the room has to be applied before it can be moved. #3436
            // stopped it here; #3437 hands it to the catch-up (edge E2), and
            // what this case protects is the rest — the document is HELD, so
            // nothing of its goes out on an epoch the room has archived, its
            // reads keep answering and its pending log is kept.
            let decision = try coordinator.handleEpochSeal([
                "type": kind, "documentId": "d", "epoch": 7, "next": 8,
            ])
            XCTAssertEqual(decision, .catchUp(from: 4, to: 8), kind)
            XCTAssertFalse(coordinator.acceptsInbound("d"), kind)
            XCTAssertFalse(
                binding.reloadRequired,
                "\(kind): a chain nobody has tried yet is not a document that "
                    + "has to be reloaded"
            )

            XCTAssertTrue(coordinator.hold.isHeld("d"), kind)
            // That a local write still COMMITS while the document is behind
            // the room is asserted where it can be: this fixture's sync mark
            // is epoch millisecond 1, so its writes are refused by the offline
            // window whatever the seal did
            // (`Format2CatchUpPlanHermeticTests`).
            //
            // Reads keep answering, and the pending log is kept.
            XCTAssertNotNil(try binding.store.read(model: "Note", recordId: "n1"), kind)
            XCTAssertEqual(try binding.store.pendingOps().count, 1, kind)
        }
    }

    func testAWriteQueuedBeforeASealIsHeldRatherThanDropped() async throws {
        let coordinator = try await makeCoordinator()
        _ = try coordinator.handleEpochInfo(frame(epoch: 4), now: 1)
        _ = try coordinator.handleEpochSeal(["type": "epoch.seal", "documentId": "d"])

        XCTAssertTrue(coordinator.hold.isHeld("d"))
        coordinator.hold.enqueue("d", frame: "an update that had already been queued")
        XCTAssertEqual(coordinator.hold.queuedCount("d"), 1)
        // Held means KEPT: when the hold does release, the frame goes out.
        XCTAssertEqual(
            coordinator.hold.release("d", reason: "test"),
            ["an update that had already been queued"]
        )
    }

    func testAnEpochFrameForADocumentThisClientDoesNotHoldIsDropped() async throws {
        let coordinator = try await makeCoordinator()
        XCTAssertEqual(
            try coordinator.handleEpochSeal([
                "type": "epoch.seal", "documentId": "somebody-elses",
            ]),
            .dropped
        )
        XCTAssertFalse(coordinator.handleSnapshotInfo([
            "type": "snapshot.ready", "documentId": "somebody-elses",
            "snapshot": ["epoch": 9],
        ]))
        XCTAssertFalse(coordinator.hold.isHeld("somebody-elses"))
    }

    // MARK: - Behavior 30 — snapshot.ready and epoch.grants

    func testSnapshotReadyAndEpochGrantsRecordTheNewestSnapshotInfo() async throws {
        let coordinator = try await makeCoordinator()
        _ = try coordinator.handleEpochInfo(
            frame(epoch: 4, snapshot: ["epoch": 2, "buildId": "old"]), now: 1
        )
        XCTAssertEqual(coordinator.snapshotInfo("d")?.buildId, "old")

        XCTAssertTrue(coordinator.handleSnapshotInfo([
            "type": "snapshot.ready", "documentId": "d",
            "snapshot": ["epoch": 4, "buildId": "fresh", "rows": 12,
                         "download": ["path": "/artifact/tok-fresh"]],
        ]))
        XCTAssertEqual(coordinator.snapshotInfo("d")?.buildId, "fresh")
        XCTAssertEqual(coordinator.snapshotInfo("d")?.rows, 12)

        // `epoch.grants` re-mints the paths for the build already named; the
        // frame carries the snapshot block at its top level.
        XCTAssertTrue(coordinator.handleSnapshotInfo([
            "type": "epoch.grants", "documentId": "d",
            "epoch": 4, "buildId": "fresh",
            "download": ["path": "/artifact/tok-renewed"],
        ]))
        XCTAssertEqual(
            coordinator.snapshotInfo("d")?.downloadPath, "/artifact/tok-renewed"
        )

        // Neither moved the document.
        XCTAssertEqual(try coordinator.binding("d")?.store.epoch(), 4)
        XCTAssertFalse(coordinator.hold.isHeld("d"))
    }

    /// Finding 3437-REVIEW-007 — a `snapshot.ready` says nothing about the room.
    ///
    /// It names the epoch its BASE covers, and carries no chain and no room
    /// epoch at all. A rebuild started by one therefore has nowhere but the
    /// last handshake to read its target from, and taking the base's epoch for
    /// it would leave every sealed overlay above the base unapplied while the
    /// client called itself current.
    func testTheRoomsEpochIsRememberedAndASnapshotOfferDoesNotLowerIt() async throws {
        let coordinator = try await makeCoordinator()
        XCTAssertEqual(coordinator.reportedEpoch("d"), 0, "nothing said yet")

        _ = try coordinator.handleEpochInfo(frame(epoch: 7), now: 1)
        XCTAssertEqual(coordinator.reportedEpoch("d"), 7)

        XCTAssertTrue(coordinator.handleSnapshotInfo([
            "type": "snapshot.ready", "documentId": "d",
            "snapshot": ["epoch": 5, "buildId": "b5", "rows": 3,
                         "download": ["path": "/artifact/tok-b5"]],
        ]))
        XCTAssertEqual(
            coordinator.snapshotInfo("d")?.epoch, 5,
            "the base is at 5 — it was cut while the room went on rotating"
        )
        XCTAssertEqual(
            coordinator.reportedEpoch("d"), 7,
            "and the room is still on 7: a rebuild from that base owes the "
                + "sealed overlays 5 and 6 before it may call itself current "
                + "(finding 3437-REVIEW-007)"
        )

        // A later handshake moves it forward, and only forward.
        _ = try coordinator.handleEpochInfo(frame(epoch: 9), now: 2)
        XCTAssertEqual(coordinator.reportedEpoch("d"), 9)
    }

    /// Edge E11 — a malformed frame is dropped, never treated as a join: a
    /// join moves the epoch mark, and moving it for a frame nobody can read
    /// would tell the next open that this client is current when it is not.
    func testAMalformedSnapshotBlockIsIgnoredRatherThanRecorded() async throws {
        let coordinator = try await makeCoordinator()
        _ = try coordinator.handleEpochInfo(frame(epoch: 4), now: 1)
        _ = coordinator.handleSnapshotInfo([
            "type": "snapshot.ready", "documentId": "d",
            "snapshot": ["buildId": "no epoch here"],
        ])
        XCTAssertNil(coordinator.snapshotInfo("d"))
    }

    // MARK: - A failed load leaves the document resumable, not half-open

    func testABaseThatCannotBeReadLeavesTheDocumentStoppedAndResumable() async throws {
        let coordinator = try await makeCoordinator()
        let binding = try XCTUnwrap(coordinator.binding("d"))
        let base = try buildBase(epoch: 5, rows: [(id: "n1", data: "{}")])

        let refusing = Format2SnapshotSource(
            apiUrl: "https://api.example.test", documentId: "d",
            grantPath: base.grantPath,
            read: { _ in Format2SnapshotSource.Answer(status: 404, body: Data()) }
        )
        XCTAssertThrowsError(
            try coordinator.runBaseLoad(
                documentId: "d",
                base: Format2Coordinator.BaseToLoad(
                    epoch: 5, grantPath: base.grantPath, rows: 1
                ),
                source: refusing
            )
        )
        XCTAssertEqual(try binding.store.epoch(), 0, "the mark did not move")
        XCTAssertTrue(coordinator.hold.isHeld("d"))
    }
}
