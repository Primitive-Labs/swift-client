import XCTest
@testable import JsBaoClient
import YSwift

/// Reloading a large document from a base, and what a reload has to take with
/// it (#3437, behaviors 21 and 22, edge E11).
///
/// Two things bring a document here. A sealed chain that cannot be trusted —
/// an epoch missing from it, or an archive the server has pruned — leaves the
/// client with no way to get from the epoch it holds to the one the room is
/// on. And a replay whose resolution would DROP a delete cannot be applied at
/// all: dropping a delete means the record has to come back, and a merged view
/// the delete already took it out of cannot put it back from anything it holds.
/// Both reload from the latest base the room has offered.
///
/// ## What a reload has to take with it
///
/// `discardMergedView` deleted the records, the stringset index and the load
/// marks, and left the derived query tables and their `_query_projection`
/// marks exactly where they were (finding 3437-SO-05). `Format2QueryProjection`
/// returns early on an existing mark, and a load writes only the ids the new
/// base carries — so a record the replacement base does not hold would stay
/// visible to `query`, `count`, `aggregate` and the stringset index after
/// `find(id:)` reports it gone. That is the worst shape a stale read can take:
/// the two doors onto one document disagreeing.
final class Format2RebuildHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let noteSchema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, indexed: true),
            "tags": FieldDescriptor(type: .stringset),
        ]
    )

    private static let taskSchema = PrimitiveSchema(
        name: "Task",
        fields: [
            "id": FieldDescriptor(type: .id),
            "label": FieldDescriptor(type: .string, indexed: true),
        ]
    )

    private struct Fixture {
        let coordinator: Format2Coordinator
        let binding: Format2DocumentBinding
        let note: DynamicModel
        let task: DynamicModel
        let documentId: String
        let document: YDocument
        let resolved: LockedBox<[DocumentOfflineWritesResolvedEvent]>
    }

    private func makeFixture(heldEpoch: Int) async throws -> Fixture {
        let directory = NSTemporaryDirectory() + "/f2-rebuild-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")

        let documentId = "rb-\(UUID().uuidString.prefix(8))"
        let document = YDocument()
        let coordinator = Format2Coordinator(
            host: provider, clientId: "me", logger: Logger(level: .none)
        )
        let resolved = LockedBox<[DocumentOfflineWritesResolvedEvent]>([])
        coordinator.onOfflineWritesResolved = { event in
            resolved.withValue { $0.append(event) }
        }
        coordinator.replaceDocument = { _, _ in }
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note", "Task"], document: document
        )
        let note = MultiDocModel(schema: Self.noteSchema)
            .connect(docId: documentId, doc: document)
        note.bindFormat2(binding)
        let task = MultiDocModel(schema: Self.taskSchema)
            .connect(docId: documentId, doc: document)
        task.bindFormat2(binding)
        // A known clock offset, or every recency verdict reads `in-window`
        // and nothing is ever decided on time.
        try binding.store.noteClockOffset(0)
        if heldEpoch > 0 { try binding.store.setEpoch(heldEpoch) }
        return Fixture(
            coordinator: coordinator, binding: binding, note: note, task: task,
            documentId: documentId, document: document, resolved: resolved
        )
    }

    // MARK: - A base the real encoder wrote

    private struct Base {
        let manifest: [String: Any]
        /// Keyed by the chunk's `key`, which is what the source's read is asked
        /// for by its path suffix.
        let bodies: [String: Data]
        let grantPath: String
    }

    /// Build a base over any number of models, through the platform's own
    /// encoder — so what the loader reads is bytes the builder really writes.
    private func buildBase(
        epoch: Int, models: [(model: String, rows: [(id: String, data: String)])]
    ) throws -> Base {
        var chunks: [[String: Any]] = []
        for (ordinal, entry) in models.enumerated() {
            chunks.append([
                "key": "app/doc/\(epoch)-b\(epoch)/\(entry.model)/\(ordinal).ndjson.gz",
                "path": "\(entry.model)/\(ordinal)",
                "ordinal": ordinal,
                "model": entry.model,
                "rows": entry.rows.map { ["id": $0.id, "data": $0.data] },
            ])
        }
        let response = try Format2Harness.run(["command": "encode-chunk", "chunks": chunks])
        let encoded = try XCTUnwrap(response["chunks"] as? [[String: Any]])
        var entries: [[String: Any]] = []
        var bodies: [String: Data] = [:]
        var rows = 0
        var bytes = 0
        for chunk in encoded {
            let entry = try XCTUnwrap(chunk["entry"] as? [String: Any])
            entries.append(entry)
            rows += entry["rows"] as? Int ?? 0
            bytes += entry["bytes"] as? Int ?? 0
            bodies[try XCTUnwrap(entry["path"] as? String)] =
                Data(base64Encoded: try XCTUnwrap(chunk["body"] as? String))
        }
        var schema: [String: Any] = [:]
        for entry in models {
            schema[entry.model] = ["stringSetFields": entry.model == "Note" ? ["tags"] : []]
        }
        return Base(
            manifest: [
                "version": 2, "epoch": epoch, "buildId": "b\(epoch)", "createdAt": 0,
                "schema": schema,
                "chunks": entries,
                "totals": ["rows": rows, "bytes": bytes],
            ],
            bodies: bodies,
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

    private func archive(_ entries: [(String, JSONValue)], model: String = "Note") -> Data {
        let overlay = OverlayDocument()
        overlay.applyRawEntries(entries, model: model)
        return Data(overlay.encodeStateAsUpdate())
    }

    private func chainEntry(_ epoch: Int, granted: Bool = true) -> SealedEpochChainEntry {
        SealedEpochChainEntry(
            epoch: epoch, sealedAt: epoch * 1_000,
            downloadPath: granted ? "/grants/epoch-\(epoch)" : nil
        )
    }

    // MARK: - Finding 3437-SO-05 — the merged view is not the only view

    func testDiscardingTheMergedViewAlsoTakesTheDocumentsProjectedRows() async throws {
        let fixture = try await makeFixture(heldEpoch: 4)
        _ = try fixture.note.create(
            id: "n1", values: ["title": .string("kept"), "tags": .stringset(["a"])]
        )
        _ = try fixture.note.create(id: "n2", values: ["title": .string("gone")])
        fixture.binding.settleFolds()

        XCTAssertEqual(try fixture.note.count(), 2)
        // Something a rebuild must NOT take: writes the server still owes an
        // acknowledgement for, and the ledger of bulk loads this client crossed.
        try fixture.binding.store.noteDiscontinuity(epoch: 3)
        let owedBefore = try fixture.binding.store.pendingOps().count
        XCTAssertGreaterThan(owedBefore, 0)

        try fixture.binding.store.discardMergedView()

        XCTAssertNil(try fixture.binding.store.read(model: "Note", recordId: "n1"))
        XCTAssertFalse(
            try fixture.binding.store.hasQueryProjection(model: "Note"),
            "the mark goes with the rows — it is what makes the next load "
                + "project again instead of returning early"
        )
        XCTAssertThrowsError(try fixture.note.count()) { error in
            XCTAssertEqual(
                (error as? JsBaoError)?.code, .format2ModelNotHydrated,
                "and until it has, a filtered read refuses BY NAME rather than "
                    + "answering from rows the merged view no longer holds"
            )
        }
        // The rows really went, not only the mark: a projection run over the
        // emptied store leaves the tables empty, which they could not be if
        // the discard had left yesterday's rows in them (finding 3437-SO-05).
        fixture.binding.projection.reprojectAll(store: fixture.binding.store)
        XCTAssertEqual(try fixture.note.count(), 0)
        XCTAssertEqual(
            try fixture.note.query(["title": .string("kept")], options: nil).count, 0
        )
        XCTAssertEqual(
            try fixture.binding.store.pendingOps().count, owedBefore,
            "the writes this client owes are still owed"
        )
        XCTAssertEqual(try fixture.binding.store.discontinuityEpochs(), [3])
    }

    // MARK: - Behavior 22 — a refused chain reloads from the offered base

    func testARefusedChainReloadsFromTheOfferedBaseAndAppliesTheChainAboveIt() async throws {
        let fixture = try await makeFixture(heldEpoch: 4)
        // Two records the old view holds and the replacement base does not.
        // Acknowledged, so they are only in the merged view: a write the
        // server still owed an ack for would be replayed and come back.
        _ = try fixture.note.create(id: "stale", values: ["title": .string("from epoch 4")])
        _ = try fixture.task.create(id: "t-stale", values: ["label": .string("old")])
        fixture.binding.settleFolds()
        try fixture.binding.store.prunePendingOps(
            maxContiguousSeq: try fixture.binding.store.nextSeq() - 1
        )
        // And one write of this client's that the server never acknowledged.
        _ = try fixture.note.create(id: "mine", values: ["title": .string("mine")])
        fixture.binding.settleFolds()
        XCTAssertEqual(try fixture.note.count(), 2)

        let base = try buildBase(epoch: 6, models: [
            (model: "Note", rows: [(id: "n1", data: #"{"title":"from the base"}"#)]),
            (model: "Task", rows: [(id: "t1", data: #"{"label":"from the base"}"#)]),
        ])

        let outcome = try await fixture.coordinator.runRebuild(
            documentId: fixture.documentId,
            base: Format2Coordinator.BaseToLoad(
                epoch: 6, grantPath: base.grantPath, rows: 2
            ),
            source: source(base),
            reported: 8,
            sealed: [chainEntry(6), chainEntry(7)],
            reason: .refusedChain,
            fetch: { step in
                self.archive([("n2/title", .string("sealed at \(step.epoch)"))])
            },
            now: 9_000
        )
        guard case .rebuilt(let epoch, let applied) = outcome else {
            return XCTFail("the rebuild did not run: \(outcome)")
        }
        XCTAssertEqual(epoch, 8)
        XCTAssertEqual(
            applied, [6, 7],
            "a base cut at epoch 6 while the room is on 8 is two sealed "
                + "overlays short of the document (finding 3437-SO-04)"
        )
        XCTAssertEqual(try fixture.binding.store.epoch(), 8)

        XCTAssertNotNil(try fixture.binding.store.read(model: "Note", recordId: "n1"))
        XCTAssertNotNil(
            try fixture.binding.store.read(model: "Note", recordId: "n2"),
            "the write that lives only in a sealed overlay above the base is "
                + "in the reloaded view"
        )
        XCTAssertNil(try fixture.binding.store.read(model: "Note", recordId: "stale"))
        XCTAssertEqual(
            try fixture.note.query(["title": .string("from epoch 4")], options: nil).count, 0,
            "and `query` agrees with `find` about it"
        )
        XCTAssertEqual(try fixture.task.count(), 1)
        XCTAssertEqual(
            try fixture.task.query(["label": .string("old")], options: nil).count, 0
        )

        let event = try XCTUnwrap(fixture.resolved.value.first)
        XCTAssertEqual(event.epoch, 8)
        XCTAssertTrue(
            event.notices.allSatisfy { $0.reason == .unverifiable },
            "the chain that would have said whether these writes were beaten "
                + "is the chain that was refused, so they are kept and said to "
                + "be unverifiable rather than silently trusted"
        )
        XCTAssertTrue(event.notices.allSatisfy { $0.outcome == .keptAmbiguous })
        XCTAssertFalse(
            try fixture.binding.store.pendingOps().isEmpty,
            "kept means kept: the writes are still owed"
        )
        XCTAssertNotNil(
            try fixture.binding.store.read(model: "Note", recordId: "mine"),
            "and a KEPT write is back in the merged view — a reload that "
                + "published it without folding it would leave the app's own "
                + "write invisible to the app that made it"
        )
        XCTAssertEqual(
            try fixture.note.count(), 3,
            "which `query` agrees with: the base's record, the one from the "
                + "sealed overlay above it, and this client's own"
        )
    }

    /// The shape a real reload takes: the base is cut for the room's CURRENT
    /// epoch, so there is no chain above it at all, and the client held an
    /// epoch far below.
    ///
    /// The base load moves the epoch mark onto the base's epoch before the
    /// swap can run, so a move guarded on "is the mark below the target" would
    /// read this document as already current and leave the stale overlay
    /// installed. What happens then is the failure this case exists for: the
    /// kept write is published — stating it onto the overlay it was written on
    /// changes no key — and never folded, so the app's own write is invisible
    /// to the app that made it. Found live.
    func testAReloadOntoTheRoomsOwnEpochStillInstallsAFreshOverlay() async throws {
        let fixture = try await makeFixture(heldEpoch: 1)
        _ = try fixture.note.create(id: "acked", values: ["title": .string("seed")])
        fixture.binding.settleFolds()
        try fixture.binding.store.prunePendingOps(
            maxContiguousSeq: try fixture.binding.store.nextSeq() - 1
        )
        _ = try fixture.note.create(id: "owed", values: ["title": .string("owed while away")])
        fixture.binding.settleFolds()

        let base = try buildBase(epoch: 3, models: [
            (model: "Note", rows: [(id: "acked", data: #"{"title":"seed"}"#)]),
        ])
        let outcome = try await fixture.coordinator.runRebuild(
            documentId: fixture.documentId,
            base: Format2Coordinator.BaseToLoad(
                epoch: 3, grantPath: base.grantPath, rows: 1
            ),
            source: source(base),
            reported: 3,
            sealed: [],
            reason: .refusedChain,
            fetch: { _ in Data() },
            now: 9_000
        )
        XCTAssertEqual(outcome, .rebuilt(epoch: 3, applied: []))
        XCTAssertEqual(
            fixture.coordinator.binding(fixture.documentId)?.overlay
                .value(model: "Note", key: "owed/title"),
            .string("owed while away"),
            "the kept write is stated on a FRESH overlay, which is what makes "
                + "it a change the observer can see"
        )
        XCTAssertNotNil(
            try fixture.binding.store.read(model: "Note", recordId: "owed"),
            "and so it is folded into the merged view: an owed write that is "
                + "published without being folded is invisible to the app that "
                + "made it"
        )
        XCTAssertNotNil(try fixture.binding.store.read(model: "Note", recordId: "acked"))
        XCTAssertEqual(try fixture.note.count(), 2, "and `query` agrees")
    }

    func testWithNoBaseOnOfferARefusedChainStopsAndALaterSnapshotReadyOffersOne()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 4)
        let refused = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId,
            target: 8,
            // Epoch 5 is missing from the chain: a gap, which no download fixes.
            sealed: [chainEntry(6), chainEntry(7)],
            fetch: { _ in Data() },
            now: 1_000
        )
        XCTAssertEqual(refused, .reload(reason: .gap, epoch: 4))
        XCTAssertNil(
            fixture.coordinator.rebuildBaseOnOffer(fixture.documentId),
            "nothing was offered, so there is nothing to reload from"
        )
        XCTAssertTrue(fixture.coordinator.hold.isHeld(fixture.documentId))

        // A build completing later is the retry: `snapshot.ready` offers a base
        // to a document that is waiting for exactly that.
        XCTAssertTrue(fixture.coordinator.handleSnapshotInfo([
            "type": "snapshot.ready",
            "documentId": fixture.documentId,
            "snapshot": [
                "epoch": 8, "buildId": "b8", "rows": 1, "manifestVersion": 2,
                "download": ["path": "/artifact/base-8", "expiresAt": 0],
            ],
        ]))
        let offered = try XCTUnwrap(
            fixture.coordinator.rebuildBaseOnOffer(fixture.documentId),
            "a document stopped for a refused chain retries from the base the "
                + "room has just built"
        )
        XCTAssertEqual(offered.epoch, 8)
        XCTAssertEqual(offered.grantPath, "/artifact/base-8")
    }

    // MARK: - Behavior 21 — a resolution that would drop a delete

    func testAResolutionThatWouldDropADeleteAsksForARebuildRatherThanApplyingIt()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 4)
        _ = try fixture.note.create(id: "n1", values: ["title": .string("seed")])
        fixture.binding.settleFolds()
        try fixture.binding.store.prunePendingOps(
            maxContiguousSeq: try fixture.binding.store.nextSeq() - 1
        )

        // Offline, this client deleted a record; online, somebody wrote it
        // afterwards. The delete loses on recency — and a merged view the
        // delete has already been folded into cannot put the record back.
        fixture.note.delete(id: "n1")
        fixture.binding.settleFolds()

        // The chain the catch-up applied on its way to epoch 6: epoch 5 wrote
        // the record after the delete was made, and its window starts after
        // the delete's timestamp, so the delete is clearly the older of the two.
        let clock = Int(Date().timeIntervalSince1970 * 1000)
        let ledger = fixture.coordinator.conflictLedgerForUpdate(fixture.documentId)
        ledger.noteSealTimes([
            (epoch: 4, sealedAt: clock + 60_000), (epoch: 5, sealedAt: clock + 120_000),
        ])
        ledger.noteEpoch(4)
        let later = OverlayDocument()
        later.applyRawEntries([("n1/title", .string("written online"))], model: "Note")
        ledger.noteOverlay(epoch: 5, later, models: ["Note"])

        // The catch-up applied the chain and moved, deferring the carry — the
        // state behavior 20 leaves behind for the judgement to run in.
        try fixture.binding.store.setEpoch(6)
        try fixture.binding.store.noteDeferredReplay(
            throughSeq: try fixture.binding.store.nextSeq() - 1,
            fromEpoch: 4, toEpoch: 6, kind: .ordinary
        )
        let judged = try XCTUnwrap(fixture.coordinator.completeDeferredReplay(
            documentId: fixture.documentId, now: clock + 180_000
        ))
        XCTAssertTrue(
            judged.rebuildRequired,
            "a dropped delete is the one verdict a replay cannot carry out on "
                + "its own: the record has to come back from a base"
        )
        XCTAssertTrue(judged.dropped.isEmpty)
        XCTAssertTrue(judged.notices.isEmpty)
        XCTAssertNotNil(
            try fixture.binding.store.deferredReplay(),
            "and nothing is settled until the rebuild has run — the note "
                + "stays, so a restart in between still knows a judgement is owed"
        )
        XCTAssertTrue(fixture.resolved.value.isEmpty)
    }

    func testTheRebuildThatFollowsDropsTheDeleteAndSurfacesIt() async throws {
        let fixture = try await makeFixture(heldEpoch: 4)
        _ = try fixture.note.create(id: "n1", values: ["title": .string("seed")])
        fixture.binding.settleFolds()
        try fixture.binding.store.prunePendingOps(
            maxContiguousSeq: try fixture.binding.store.nextSeq() - 1
        )
        fixture.note.delete(id: "n1")
        fixture.binding.settleFolds()

        let clock = Int(Date().timeIntervalSince1970 * 1000)
        let ledger = fixture.coordinator.conflictLedgerForUpdate(fixture.documentId)
        ledger.noteSealTimes([
            (epoch: 4, sealedAt: clock + 60_000), (epoch: 5, sealedAt: clock + 120_000),
        ])
        ledger.noteEpoch(4)
        let later = OverlayDocument()
        later.applyRawEntries([("n1/title", .string("written online"))], model: "Note")
        ledger.noteOverlay(epoch: 5, later, models: ["Note"])
        try fixture.binding.store.setEpoch(6)
        try fixture.binding.store.noteDeferredReplay(
            throughSeq: try fixture.binding.store.nextSeq() - 1,
            fromEpoch: 4, toEpoch: 6, kind: .ordinary
        )

        let base = try buildBase(epoch: 6, models: [
            (model: "Note", rows: [(id: "n1", data: #"{"title":"written online"}"#)]),
        ])
        let outcome = try await fixture.coordinator.runRebuild(
            documentId: fixture.documentId,
            base: Format2Coordinator.BaseToLoad(
                epoch: 6, grantPath: base.grantPath, rows: 1
            ),
            source: source(base),
            reported: 6,
            sealed: [],
            reason: .droppedDelete,
            fetch: { _ in Data() },
            now: clock + 180_000
        )
        guard case .rebuilt = outcome else {
            return XCTFail("the rebuild did not run: \(outcome)")
        }
        XCTAssertNotNil(
            try fixture.binding.store.read(model: "Note", recordId: "n1"),
            "the record the delete would have taken is back, from the base"
        )
        let event = try XCTUnwrap(fixture.resolved.value.first)
        XCTAssertTrue(
            event.notices.contains { $0.op == .delete && $0.outcome == .dropped },
            "and the delete is dropped and surfaced on this pass, because a "
                + "rebuild is what `rebuildRequired` was asking for"
        )
        XCTAssertNil(try fixture.binding.store.deferredReplay())
    }

    // MARK: - Edge E11 — a snapshot.ready during a rebuild in flight

    func testASnapshotReadyNamingAnOlderBuildIsIgnored() async throws {
        let fixture = try await makeFixture(heldEpoch: 4)
        XCTAssertTrue(fixture.coordinator.handleSnapshotInfo([
            "type": "snapshot.ready",
            "documentId": fixture.documentId,
            "snapshot": [
                "epoch": 8, "buildId": "b8", "rows": 1,
                "download": ["path": "/artifact/base-8", "expiresAt": 0],
            ],
        ]))
        XCTAssertFalse(
            fixture.coordinator.handleSnapshotInfo([
                "type": "snapshot.ready",
                "documentId": fixture.documentId,
                "snapshot": [
                    "epoch": 5, "buildId": "b5", "rows": 1,
                    "download": ["path": "/artifact/base-5", "expiresAt": 0],
                ],
            ]),
            "a build older than the one already offered is not news"
        )
        XCTAssertEqual(fixture.coordinator.snapshotInfo(fixture.documentId)?.epoch, 8)
    }

    /// A reload runs with the document's refusal still SET — the refusal is
    /// what it is answering — so "is this document stuck?" is true for the
    /// whole of it. A second reload started over the first would discard the
    /// merged view again and take with it the writes the first had just judged
    /// and stated. Found live, on a build that completed while the reload it
    /// had triggered was still running.
    func testOnlyOneReloadOfADocumentRunsAtATime() async throws {
        let fixture = try await makeFixture(heldEpoch: 4)
        XCTAssertTrue(fixture.coordinator.beginRebuild(fixture.documentId))
        XCTAssertTrue(fixture.coordinator.isRebuilding(fixture.documentId))
        XCTAssertFalse(
            fixture.coordinator.beginRebuild(fixture.documentId),
            "a second caller is told there is nothing for it to do"
        )
        XCTAssertTrue(
            fixture.coordinator.beginRebuild("another-document"),
            "and it is per document, not a global gate"
        )
        fixture.coordinator.endRebuild(fixture.documentId)
        XCTAssertFalse(fixture.coordinator.isRebuilding(fixture.documentId))
        XCTAssertTrue(
            fixture.coordinator.beginRebuild(fixture.documentId),
            "the next one may run: a reload that ended released its claim"
        )
    }

    func testARebuildInFlightRecordsALaterOfferWithoutRestartingTheLoad() async throws {
        let fixture = try await makeFixture(heldEpoch: 4)
        let base = try buildBase(epoch: 6, models: [
            (model: "Note", rows: [(id: "n1", data: #"{"title":"from the base"}"#)]),
        ])
        let attempt = fixture.coordinator.beginBaseLoad(fixture.documentId)
        XCTAssertTrue(
            fixture.coordinator.baseLoadIsCurrent(fixture.documentId, attempt: attempt)
        )
        _ = fixture.coordinator.handleSnapshotInfo([
            "type": "snapshot.ready",
            "documentId": fixture.documentId,
            "snapshot": [
                "epoch": 9, "buildId": "b9", "rows": 1,
                "download": ["path": "/artifact/base-9", "expiresAt": 0],
            ],
        ])
        XCTAssertTrue(
            fixture.coordinator.baseLoadIsCurrent(fixture.documentId, attempt: attempt),
            "a base announced while one is streaming is RECORDED, not acted "
                + "on: restarting the load would throw away every chunk that "
                + "has landed (edge E11)"
        )
        // And the load in flight still completes the document it was started for.
        let outcome = try await fixture.coordinator.runRebuild(
            documentId: fixture.documentId,
            base: Format2Coordinator.BaseToLoad(
                epoch: 6, grantPath: base.grantPath, rows: 1
            ),
            source: source(base),
            reported: 6,
            sealed: [],
            reason: .refusedChain,
            fetch: { _ in Data() },
            now: 12_000,
            attempt: attempt
        )
        guard case .rebuilt = outcome else {
            return XCTFail("the rebuild did not run: \(outcome)")
        }
    }
    // MARK: - Finding 3437-REVIEW-008 — a chain above the base that cannot be applied

    func testARebuildWhoseChainHasAGapHoldsTheDocumentInsteadOfCallingItCurrent()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 4)
        _ = try fixture.note.create(id: "mine", values: ["title": .string("mine")])
        fixture.binding.settleFolds()
        let owed = try fixture.binding.store.pendingOps().map(\.seq)
        XCTAssertFalse(owed.isEmpty)

        let base = try buildBase(epoch: 6, models: [
            (model: "Note", rows: [(id: "n1", data: #"{"title":"from the base"}"#)]),
        ])

        // The room is on 9 and the chain the handshake reported is missing
        // epoch 7 altogether: the base plus what IS readable does not reach the
        // room's epoch.
        let outcome = try await fixture.coordinator.runRebuild(
            documentId: fixture.documentId,
            base: Format2Coordinator.BaseToLoad(
                epoch: 6, grantPath: base.grantPath, rows: 1
            ),
            source: source(base),
            reported: 9,
            sealed: [chainEntry(6), chainEntry(8)],
            reason: .refusedChain,
            fetch: { step in
                self.archive([("n2/title", .string("sealed at \(step.epoch)"))])
            },
            now: 9_000
        )
        guard case .refused(let error) = outcome else {
            return XCTFail(
                "a rebuild that cannot reach the room's epoch must refuse, not "
                    + "finish: \(outcome)"
            )
        }
        XCTAssertEqual(error.code, .format2ReloadRequired)
        XCTAssertNotEqual(
            try fixture.binding.store.epoch(), 9,
            "and it must not have marked this client current: every write that "
                + "lives only in the missing overlay would be gone with nothing "
                + "left to say so (finding 3437-REVIEW-008)"
        )
        XCTAssertTrue(fixture.binding.reloadRequired)
        XCTAssertEqual(
            try fixture.binding.store.pendingOps().map(\.seq), owed,
            "the writes this client owes are still owed"
        )
    }

    func testARebuildWhoseBaseIsBelowAFurtherBulkLoadWaitsForABasePastThatOne()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 4)
        let base = try buildBase(epoch: 6, models: [
            (model: "Note", rows: [(id: "n1", data: #"{"title":"from the base"}"#)]),
        ])

        let outcome = try await fixture.coordinator.runRebuild(
            documentId: fixture.documentId,
            base: Format2Coordinator.BaseToLoad(
                epoch: 6, grantPath: base.grantPath, rows: 1
            ),
            source: source(base),
            reported: 9,
            sealed: [
                chainEntry(6),
                SealedEpochChainEntry(
                    epoch: 7, sealedAt: 7_000, baseDiscontinuity: true,
                    downloadPath: "/grants/epoch-7"
                ),
                chainEntry(8),
            ],
            reason: .refusedChain,
            fetch: { step in
                self.archive([("n2/title", .string("sealed at \(step.epoch)"))])
            },
            now: 9_000
        )
        guard case .refused = outcome else {
            return XCTFail("a base below a further bulk load must refuse: \(outcome)")
        }
        XCTAssertEqual(
            try fixture.binding.store.discontinuityEpochs(), [7],
            "and the bulk load it found on the way is recorded, so the base "
                + "that finally arrives is weighed against it"
        )
        XCTAssertNotEqual(try fixture.binding.store.epoch(), 9)
    }

    // MARK: - Finding 3437-REVIEW-005 — the base alone does not make it current

    func testTheBaseLoadOfARebuildLeavesTheMarkAndTheHoldToTheRebuild() async throws {
        let fixture = try await makeFixture(heldEpoch: 4)
        fixture.coordinator.hold.hold(fixture.documentId, reason: "awaiting a base past a bulk load")
        let base = try buildBase(epoch: 6, models: [
            (model: "Note", rows: [(id: "n1", data: #"{"title":"from the base"}"#)]),
        ])
        let outcome = try fixture.coordinator.runBaseLoad(
            documentId: fixture.documentId,
            base: Format2Coordinator.BaseToLoad(
                epoch: 6, grantPath: base.grantPath, rows: 1
            ),
            source: source(base),
            refoldOpenOverlay: false,
            finalizes: false
        )
        XCTAssertEqual(outcome.plan, .join)
        XCTAssertNotNil(
            try fixture.binding.store.read(model: "Note", recordId: "n1"),
            "the rows landed"
        )
        XCTAssertEqual(
            try fixture.binding.store.epoch(), 4,
            "and the mark did NOT move: a crash between the base landing and "
                + "the fresh overlay being persisted would otherwise restart "
                + "with the OLD epoch's Y.Doc under the NEW mark (finding "
                + "3437-REVIEW-005)"
        )
        XCTAssertTrue(
            fixture.coordinator.hold.isHeld(fixture.documentId),
            "and the hold stands, so nothing this client writes meanwhile "
                + "escapes as a delta against the view that has just been "
                + "replaced whole"
        )
    }
    // MARK: - Finding 3437-REVIEW-010 — a reload plans hydration too

    func testAReloadPlansTheReplacementBaseAgainstTheDeviceRatherThanTrustingTheScope()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 4)
        // A previous capped load left "Note" as the scope this device holds.
        try fixture.binding.store.setHydrationScope(["Note"])

        // And the device has since filled up: even "Note" alone does not fit
        // in what is left.
        fixture.coordinator.storageOptions = LargeDocumentStorageOptions(
            capability: StorageCapability(persistent: true, quotaBytes: 8)
        )

        let base = try buildBase(epoch: 6, models: [
            (model: "Note", rows: [(id: "n1", data: #"{"title":"from the base"}"#)]),
            (model: "Task", rows: [(id: "t1", data: #"{"label":"from the base"}"#)]),
        ])

        do {
            _ = try await fixture.coordinator.runRebuild(
                documentId: fixture.documentId,
                base: Format2Coordinator.BaseToLoad(
                    epoch: 6, grantPath: base.grantPath, rows: 2
                ),
                source: source(base),
                reported: 6,
                sealed: [],
                reason: .refusedChain,
                fetch: { _ in Data() },
                permittedModels: try fixture.binding.store.hydrationScope(),
                now: 9_000
            )
            XCTFail(
                "the recorded scope is what this device is PERMITTED to hold, "
                    + "not a plan: handing it back unplanned skips the probe "
                    + "and writes a base the device has no room for "
                    + "(finding 3437-REVIEW-010)"
            )
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .format2StorageUnavailable)
            XCTAssertEqual(error.details?["reason"], .string("over-quota"))
        }

        XCTAssertNil(
            try fixture.binding.store.read(model: "Note", recordId: "n1"),
            "and it refused BEFORE the first chunk was fetched"
        )
    }
}
