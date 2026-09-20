import XCTest
@testable import JsBaoClient
import YSwift

/// A bulk load re-founds a document, and what a client that was connected
/// through it has to do about the writes it made (#3437, behaviors 28 to 31).
///
/// The seal that carries `baseDiscontinuity` says the sum of the overlays on
/// either side of it is NOT the document: an ingest replaced ranges of rows
/// wholesale, and no chain crosses that. So the ordinary carry cannot run —
/// the values it would read off the sealed overlay may be for records the
/// ingest deleted — and the ordinary recency rules cannot judge the owed
/// writes either, because the ingest's changes are in no overlay the conflict
/// ledger holds.
///
/// What replaces both is PRESENCE, and presence is only a fact once the base
/// the ingest produced has landed. So the move defers, the owed sequences are
/// withheld from every claim until they are judged, and the debt is durable —
/// a restart in between must not publish a write recency never saw (finding
/// 3437-SO-03).
final class Format2DiscontinuityHermeticTests: XCTestCase {

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
            "title": FieldDescriptor(type: .string, indexed: true),
        ]
    )

    private struct Fixture {
        let coordinator: Format2Coordinator
        let binding: Format2DocumentBinding
        let model: DynamicModel
        let documentId: String
        let directory: String
        let resolved: LockedBox<[DocumentOfflineWritesResolvedEvent]>
    }

    private func newDirectory() -> String {
        let directory = NSTemporaryDirectory() + "/f2-disc-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory
    }

    private func makeFixture(
        heldEpoch: Int, directory: String? = nil, documentId: String? = nil
    ) async throws -> Fixture {
        let directory = directory ?? newDirectory()
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")

        let documentId = documentId ?? "dc-\(UUID().uuidString.prefix(8))"
        let document = YDocument()
        let coordinator = Format2Coordinator(
            host: provider, clientId: "me-\(UUID().uuidString.prefix(6))",
            logger: Logger(level: .none)
        )
        let resolved = LockedBox<[DocumentOfflineWritesResolvedEvent]>([])
        coordinator.onOfflineWritesResolved = { event in
            resolved.withValue { $0.append(event) }
        }
        coordinator.replaceDocument = { _, _ in }
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: document
        )
        let model = MultiDocModel(schema: Self.schema)
            .connect(docId: documentId, doc: document)
        model.bindFormat2(binding)
        try binding.store.noteClockOffset(0)
        if heldEpoch > 0 { try binding.store.setEpoch(heldEpoch) }
        return Fixture(
            coordinator: coordinator, binding: binding, model: model,
            documentId: documentId, directory: directory, resolved: resolved
        )
    }

    /// A wall clock the offline-window gate reads as current. Seal times and
    /// move marks are taken from it rather than from small integers: a mark
    /// at epoch-zero milliseconds is twenty thousand days stale, and the gate
    /// refuses every write that follows it.
    private let clock = Int(Date().timeIntervalSince1970 * 1000)

    private func flaggedSeal(
        _ documentId: String, epoch: Int, next: Int
    ) -> [String: Any] {
        [
            "type": "epoch.seal", "documentId": documentId,
            "epoch": epoch, "next": next, "baseDiscontinuity": true,
        ]
    }

    // MARK: - A base the real encoder wrote

    private struct Base {
        let manifest: [String: Any]
        let bodies: [String: Data]
        let grantPath: String
    }

    private func buildBase(
        epoch: Int, rows: [(id: String, data: String)]
    ) throws -> Base {
        let response = try Format2Harness.run([
            "command": "encode-chunk",
            "chunks": [[
                "key": "app/doc/\(epoch)-b\(epoch)/Note/0.ndjson.gz",
                "path": "Note/0",
                "ordinal": 0,
                "model": "Note",
                "rows": rows.map { ["id": $0.id, "data": $0.data] },
            ]],
        ])
        let encoded = try XCTUnwrap(response["chunks"] as? [[String: Any]])
        let entry = try XCTUnwrap(encoded[0]["entry"] as? [String: Any])
        let body = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(encoded[0]["body"] as? String))
        )
        return Base(
            manifest: [
                "version": 2, "epoch": epoch, "buildId": "b\(epoch)", "createdAt": 0,
                "schema": ["Note": ["stringSetFields": []]],
                "chunks": [entry],
                "totals": [
                    "rows": entry["rows"] as? Int ?? 0,
                    "bytes": entry["bytes"] as? Int ?? 0,
                ],
            ],
            bodies: ["Note/0": body],
            grantPath: "/artifact/base-\(epoch)"
        )
    }

    private func source(_ base: Base) -> Format2SnapshotSource {
        Format2SnapshotSource(
            apiUrl: "https://api.example.test",
            documentId: "d",
            grantPath: base.grantPath,
            read: { url in
                if url.path == base.grantPath {
                    return Format2SnapshotSource.Answer(
                        status: 200,
                        body: try JSONSerialization.data(withJSONObject: base.manifest)
                    )
                }
                let suffix = String(url.path.dropFirst(base.grantPath.count + 1))
                guard let body = base.bodies[suffix] else {
                    return Format2SnapshotSource.Answer(status: 404, body: Data())
                }
                return Format2SnapshotSource.Answer(status: 200, body: body)
            }
        )
    }

    private func archive(_ entries: [(String, JSONValue)]) -> Data {
        let overlay = OverlayDocument()
        overlay.applyRawEntries(entries, model: "Note")
        return Data(overlay.encodeStateAsUpdate())
    }

    // MARK: - Behavior 28 — a flagged seal

    func testAFlaggedSealNotesTheDiscontinuityBeforeItMovesAndDefersTheCarry()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 4)
        _ = try fixture.model.create(id: "n1", values: ["title": .string("mine")])
        fixture.binding.settleFolds()
        let owed = try XCTUnwrap(try fixture.binding.store.pendingOps().map(\.seq).max())

        let decision = try fixture.coordinator.handleEpochSeal(
            flaggedSeal(fixture.documentId, epoch: 4, next: 5)
        )
        XCTAssertEqual(decision, .move(next: 5))
        XCTAssertEqual(
            try fixture.binding.store.discontinuityEpochs(), [4],
            "the boundary is durable BEFORE the move: a crash between the two "
                + "must not leave a client on the far side of a bulk load with "
                + "no record that it crossed one"
        )

        let moved = try await fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 5, now: clock
        )
        XCTAssertEqual(moved, .moved(epoch: 5))

        let note = try XCTUnwrap(try fixture.binding.store.deferredReplay())
        XCTAssertEqual(note.kind, .discontinuity)
        XCTAssertEqual(note.throughSeq, owed)
        XCTAssertEqual(note.fromEpoch, 4)
        XCTAssertEqual(note.toEpoch, 5)
        XCTAssertNil(
            fixture.binding.overlay.value(model: "Note", key: "n1/title"),
            "the carry is deferred: the fresh overlay is installed WITHOUT the "
                + "owed write, because presence has not been read yet"
        )
        XCTAssertNotNil(
            try fixture.binding.store.read(model: "Note", recordId: "n1"),
            "and the merged view keeps answering reads meanwhile"
        )

        // Withheld from every claim until they are judged.
        _ = try fixture.model.create(id: "n2", values: ["title": .string("after")])
        fixture.binding.settleFolds()
        let resend = try XCTUnwrap(
            try fixture.coordinator.wholeStateResend(documentId: fixture.documentId)
        )
        let stamps = try XCTUnwrap(resend.claim.stamps)
        XCTAssertGreaterThan(
            stamps.seqFrom, owed,
            "no frame claims a sequence whose content is on no frame — the "
                + "whole-state claim starts above the withheld span"
        )
    }

    func testASecondFlaggedSealBeforeTheBaseDefersAgainAndKeepsTheOrder()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 4)
        _ = try fixture.model.create(id: "n1", values: ["title": .string("first")])
        fixture.binding.settleFolds()

        _ = try fixture.coordinator.handleEpochSeal(
            flaggedSeal(fixture.documentId, epoch: 4, next: 5)
        )
        _ = try await fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 5, now: clock
        )
        _ = try fixture.model.create(id: "n2", values: ["title": .string("second")])
        fixture.binding.settleFolds()
        let second = try XCTUnwrap(try fixture.binding.store.pendingOps().map(\.seq).max())

        _ = try fixture.coordinator.handleEpochSeal(
            flaggedSeal(fixture.documentId, epoch: 5, next: 6)
        )
        _ = try await fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 6, now: clock + 1_000
        )

        XCTAssertEqual(try fixture.binding.store.discontinuityEpochs(), [4, 5])
        let note = try XCTUnwrap(try fixture.binding.store.deferredReplay())
        XCTAssertEqual(
            note.throughSeq, second,
            "one debt, widened: 'everything at or below this sequence' twice "
                + "over overlapping spans is one judgement"
        )
        XCTAssertEqual(note.fromEpoch, 4, "from the FIRST boundary it crossed")
        XCTAssertEqual(note.toEpoch, 6)
        XCTAssertEqual(note.kind, .discontinuity)
    }

    // MARK: - Behavior 29 — the rebuild past the discontinuity

    func testTheRebuildJudgesTheOwedWritesByPresenceAndSettlesTheLedger()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 4)
        // A record the ingest will keep, one it will delete, and a create at an
        // id the server has never held.
        _ = try fixture.model.create(id: "kept", values: ["title": .string("seed")])
        _ = try fixture.model.create(id: "removed", values: ["title": .string("seed")])
        fixture.binding.settleFolds()
        try fixture.binding.store.prunePendingOps(
            maxContiguousSeq: try fixture.binding.store.nextSeq() - 1
        )
        try fixture.model.update(id: "kept", values: ["title": .string("my patch")])
        try fixture.model.update(id: "removed", values: ["title": .string("my patch")])
        _ = try fixture.model.create(id: "brand-new", values: ["title": .string("offline")])
        fixture.binding.settleFolds()

        _ = try fixture.coordinator.handleEpochSeal(
            flaggedSeal(fixture.documentId, epoch: 4, next: 5)
        )
        _ = try await fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 5, now: clock
        )
        XCTAssertEqual(try fixture.binding.store.discontinuityEpochs(), [4])

        // The room rotated once more while the ingest's base was building, so
        // the base at epoch 5 trails the room at 6 — and the write in the
        // sealed overlay of epoch 5 is part of the document (3437-SO-04).
        let base = try buildBase(epoch: 5, rows: [
            (id: "kept", data: #"{"title":"from the ingest"}"#),
        ])
        let outcome = try await fixture.coordinator.runRebuild(
            documentId: fixture.documentId,
            base: Format2Coordinator.BaseToLoad(
                epoch: 5, grantPath: base.grantPath, rows: 1
            ),
            source: source(base),
            reported: 6,
            sealed: [SealedEpochChainEntry(epoch: 5, downloadPath: "/grants/5")],
            reason: .discontinuity,
            fetch: { _ in self.archive([("above/title", .string("sealed above the base"))]) },
            now: clock + 2_000
        )
        XCTAssertEqual(outcome, .rebuilt(epoch: 6, applied: [5]))

        XCTAssertNotNil(
            try fixture.binding.store.read(model: "Note", recordId: "above"),
            "a write that lives only in a sealed overlay above the base is in "
                + "the rebuilt view (finding 3437-SO-04)"
        )
        let event = try XCTUnwrap(fixture.resolved.value.first)
        XCTAssertEqual(event.epoch, 6)
        let byRecord = Dictionary(
            grouping: event.notices, by: { $0.recordId }
        ).mapValues { $0.map { ($0.outcome, $0.reason) } }
        XCTAssertEqual(
            byRecord["removed"]?.first?.0, .dropped,
            "a patch onto a record the ingest removed is dropped"
        )
        XCTAssertEqual(byRecord["removed"]?.first?.1, .bulkIngest)
        XCTAssertEqual(
            byRecord["kept"]?.first?.0, .keptAmbiguous,
            "one onto a record the ingest kept is applied and surfaced"
        )
        XCTAssertEqual(byRecord["kept"]?.first?.1, .bulkIngest)
        XCTAssertEqual(
            byRecord["brand-new"]?.first?.0, .keptAmbiguous,
            "and an offline create at an id the server never held is kept — "
                + "it is absent because nobody ever wrote it, not because the "
                + "ingest took it"
        )

        XCTAssertNil(try fixture.binding.store.read(model: "Note", recordId: "removed"))
        XCTAssertEqual(
            try fixture.model.query(["title": .string("seed")], options: nil).count, 0,
            "and `query` agrees with `find` about the records the ingest removed"
        )
        XCTAssertEqual(
            try fixture.binding.store.discontinuityEpochs(), [],
            "the document has converged: the boundary is settled"
        )
        XCTAssertNil(try fixture.binding.store.deferredReplay())
    }

    func testASnapshotReadyAtOrBelowTheDiscontinuityIsNotABaseToRebuildFrom()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 4)
        try fixture.binding.store.noteDiscontinuity(epoch: 5)
        XCTAssertTrue(fixture.coordinator.handleSnapshotInfo([
            "type": "snapshot.ready", "documentId": fixture.documentId,
            "snapshot": [
                "epoch": 5, "buildId": "b5", "rows": 1,
                "download": ["path": "/artifact/base-5", "expiresAt": 0],
            ],
        ]))
        XCTAssertNil(
            fixture.coordinator.rebuildBaseOnOffer(fixture.documentId),
            "a base cut on the wrong side of a bulk load is not a base this "
                + "document can be re-founded on"
        )
        _ = fixture.coordinator.handleSnapshotInfo([
            "type": "snapshot.ready", "documentId": fixture.documentId,
            "snapshot": [
                "epoch": 6, "buildId": "b6", "rows": 1,
                "download": ["path": "/artifact/base-6", "expiresAt": 0],
            ],
        ])
        XCTAssertEqual(
            fixture.coordinator.rebuildBaseOnOffer(fixture.documentId)?.epoch, 6
        )
    }

    // MARK: - Behavior 30 — a restart between the flagged seal and the base

    func testARestartBeforeTheBaseKeepsTheAffectedWritesOffTheOverlay() async throws {
        let directory = newDirectory()
        let documentId = "dc-restart"
        do {
            let fixture = try await makeFixture(
                heldEpoch: 4, directory: directory, documentId: documentId
            )
            _ = try fixture.model.create(id: "n1", values: ["title": .string("mine")])
            fixture.binding.settleFolds()
            _ = try fixture.coordinator.handleEpochSeal(
                flaggedSeal(documentId, epoch: 4, next: 5)
            )
            _ = try await fixture.coordinator.runEpochMove(
                documentId: documentId, next: 5, now: clock
            )
        }

        // A different instance over the same file: a new client id, so the
        // previous instance's unacknowledged write is an orphan to adopt.
        let restarted = try await makeFixture(
            heldEpoch: 0, directory: directory, documentId: documentId
        )
        XCTAssertEqual(try restarted.binding.store.epoch(), 5)
        XCTAssertEqual(try restarted.binding.store.discontinuityEpochs(), [4])

        let adoption = try restarted.binding.adoptAndRestore()
        XCTAssertEqual(adoption.adopted.count, 1)
        XCTAssertEqual(
            adoption.restored, [],
            "nothing at or below the boundary is put back on the overlay: the "
                + "rebuild is what decides whether it survives"
        )
        XCTAssertEqual(adoption.deferred.count, 1)
        XCTAssertNil(
            restarted.binding.overlay.value(model: "Note", key: "n1/title"),
            "so the write is not published by the flush that follows the bind"
        )
        XCTAssertNotNil(
            try restarted.binding.store.deferredReplay(),
            "and the debt still stands"
        )
    }

    // MARK: - Behavior 31 — a converge plan

    func testAWarmClientsChainThatCrossesABulkLoadConvergesRatherThanApplying()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 3)
        let chain: [[String: Any]] = [
            ["epoch": 3, "sealedAt": clock, "download": ["path": "/g/3"]],
            [
                "epoch": 4, "sealedAt": clock + 1, "baseDiscontinuity": true,
                "download": ["path": "/g/4"],
            ],
            ["epoch": 5, "sealedAt": clock + 2, "download": ["path": "/g/5"]],
        ]
        let outcome = try fixture.coordinator.handleEpochInfo(
            ["documentId": fixture.documentId, "epoch": 6, "sealedEpochs": chain],
            now: clock
        )
        XCTAssertEqual(outcome.plan, .catchUp)

        let fetched = LockedBox<[Int]>([])
        let caughtUp = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId,
            target: 6,
            sealed: outcome.sealed,
            fetch: { step in
                fetched.withValue { $0.append(step.epoch) }
                return Data()
            },
            now: clock
        )
        XCTAssertEqual(
            caughtUp, .converge(from: 3, discontinuities: [4]),
            "a chain that crosses a bulk load is not a chain: the sum of the "
                + "overlays on either side is not the document"
        )
        XCTAssertEqual(
            fetched.value, [],
            "and nothing below the boundary is applied — it would be applied "
                + "to a view the ingest is about to replace"
        )
        XCTAssertEqual(try fixture.binding.store.epoch(), 3, "nothing moved")
        XCTAssertNil(
            fixture.binding.reloadRefusal,
            "the document is NOT stopped: it keeps answering reads and taking "
                + "local writes while the ingest's base builds"
        )
    }

    /// The same for a COLD client, which the planner answers directly: the
    /// chain up to the boundary is applicable, the base beyond it is being
    /// built, and "wait for it" is the honest answer where `unavailable` would
    /// stop the document.
    func testAColdClientBehindABulkLoadAwaitsTheBaseWithoutBeingStopped()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 0)
        let outcome = try fixture.coordinator.handleEpochInfo(
            [
                "documentId": fixture.documentId, "epoch": 6,
                "sealedEpochs": [
                    ["epoch": 1, "sealedAt": clock, "download": ["path": "/g/1"]],
                    ["epoch": 2, "sealedAt": clock + 1, "download": ["path": "/g/2"]],
                    ["epoch": 3, "sealedAt": clock + 2, "download": ["path": "/g/3"]],
                    [
                        "epoch": 4, "sealedAt": clock + 3, "baseDiscontinuity": true,
                        "download": ["path": "/g/4"],
                    ],
                    ["epoch": 5, "sealedAt": clock + 4, "download": ["path": "/g/5"]],
                ],
            ],
            now: clock
        )
        XCTAssertEqual(outcome.plan, .awaitBase)
        XCTAssertEqual(outcome.reported, 6)
        XCTAssertTrue(
            fixture.coordinator.hold.isHeld(fixture.documentId),
            "nothing of this client's goes out until it has converged"
        )
        XCTAssertNil(
            fixture.binding.reloadRefusal,
            "but the document is not stopped"
        )
        XCTAssertEqual(
            try fixture.binding.store.discontinuityEpochs(), [4],
            "and the boundary is recorded, so a restart before the base "
                + "arrives still knows what it is waiting for"
        )
    }
    // MARK: - Finding 3437-REVIEW-001 — presence decides, and only presence

    func testAnOrdinaryJudgementRefusesADiscontinuityNoteUntilTheRebuildHasRun()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 4)
        _ = try fixture.model.create(id: "kept", values: ["title": .string("seed")])
        _ = try fixture.model.create(id: "removed", values: ["title": .string("seed")])
        fixture.binding.settleFolds()
        try fixture.binding.store.prunePendingOps(
            maxContiguousSeq: try fixture.binding.store.nextSeq() - 1
        )
        try fixture.model.update(id: "removed", values: ["title": .string("my patch")])
        fixture.binding.settleFolds()
        let owed = try XCTUnwrap(try fixture.binding.store.pendingOps().map(\.seq).max())

        _ = try fixture.coordinator.handleEpochSeal(
            flaggedSeal(fixture.documentId, epoch: 4, next: 5)
        )
        _ = try await fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 5, now: clock
        )

        // The room answers the move's `syncStep1` with `epoch.info` and then a
        // `syncComplete`, both of which arrive long before the ingest's base
        // does. Neither may settle this debt: the writes it covers raced a
        // bulk load, whose changes are in NO sealed overlay, so the recency
        // rules have nothing to judge them by — presence does, and presence is
        // a fact only once the replacement base has landed.
        XCTAssertNil(
            try fixture.coordinator.completeDeferredReplay(
                documentId: fixture.documentId, now: clock + 500
            ),
            "the ordinary judgement declines a discontinuity note "
                + "(finding 3437-REVIEW-001)"
        )
        XCTAssertFalse(
            try fixture.coordinator.resumeDeferredReplay(
                documentId: fixture.documentId,
                sealed: [SealedEpochChainEntry(epoch: 4, downloadPath: "/grants/4")],
                fetch: { _ in Data() },
                now: clock + 500
            ),
            "and so does the restart path, rather than reading a chain nothing "
                + "will consult"
        )
        XCTAssertEqual(
            try fixture.binding.store.deferredReplay()?.kind, .discontinuity,
            "the note stands"
        )
        XCTAssertEqual(
            fixture.coordinator.outbound.withheldCeiling(fixture.documentId), owed,
            "with the owed sequences still withheld from every claim"
        )
        XCTAssertNil(
            fixture.binding.overlay.value(model: "Note", key: "removed/title"),
            "and the patch onto a record the ingest may have removed is on no "
                + "overlay and published by nobody"
        )
        XCTAssertTrue(fixture.resolved.value.isEmpty)
    }

    // MARK: - Finding 3437-REVIEW-011 — converging with nothing owed

    func testAClientWithNoPendingWritesClearsTheBoundaryWhenItRebuilds()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 4)
        _ = try fixture.model.create(id: "kept", values: ["title": .string("seed")])
        fixture.binding.settleFolds()
        // Everything this client wrote is acknowledged: it has no stake in the
        // bulk load at all beyond having to converge on it.
        try fixture.binding.store.prunePendingOps(
            maxContiguousSeq: try fixture.binding.store.nextSeq() - 1
        )
        XCTAssertTrue(try fixture.binding.store.pendingOps().isEmpty)

        _ = try fixture.coordinator.handleEpochSeal(
            flaggedSeal(fixture.documentId, epoch: 4, next: 5)
        )
        _ = try await fixture.coordinator.runEpochMove(
            documentId: fixture.documentId, next: 5, now: clock
        )
        XCTAssertEqual(try fixture.binding.store.discontinuityEpochs(), [4])

        let base = try buildBase(epoch: 5, rows: [
            (id: "kept", data: #"{"title":"from the ingest"}"#),
        ])
        let outcome = try await fixture.coordinator.runRebuild(
            documentId: fixture.documentId,
            base: Format2Coordinator.BaseToLoad(
                epoch: 5, grantPath: base.grantPath, rows: 1
            ),
            source: source(base),
            reported: 5,
            sealed: [],
            reason: .discontinuity,
            fetch: { _ in Data() },
            now: clock + 2_000
        )
        XCTAssertEqual(outcome, .rebuilt(epoch: 5, applied: []))
        XCTAssertEqual(
            try fixture.binding.store.discontinuityEpochs(), [],
            "the marker records that this client has not converged on the bulk "
                + "load, and the rebuild IS that convergence — keeping it "
                + "because nothing was owed would reload the document again "
                + "from every later `snapshot.ready` (finding 3437-REVIEW-011)"
        )
        XCTAssertNil(
            fixture.coordinator.rebuildBaseOnOffer(fixture.documentId),
            "so a base announced afterwards is recorded and no more"
        )
    }
}
