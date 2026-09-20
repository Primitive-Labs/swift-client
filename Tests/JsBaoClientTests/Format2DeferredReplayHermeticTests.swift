import XCTest
@testable import JsBaoClient
import YSwift

/// A returning client's owed writes are judged before they are published
/// (#3437, behaviors 20 and 20a).
///
/// The carry a move makes is unconditional: it puts every unacknowledged write
/// onto the fresh overlay, which publishes it. For a client that was AWAY that
/// is the original D1 — it silently overwrites whatever anyone else wrote in
/// between, including writes made days later. So the move of a returning client
/// DEFERS the carry: the fresh overlay is installed without those writes, the
/// sequences they hold are withheld from every claim, and the judgement runs
/// once the joined epoch's content has arrived.
///
/// Two things make that safe rather than merely later:
///
/// - the withhold (behavior 27). Swift's whole-state claim reads the DURABLE
///   acked mark, so a frame going out between the move and the judgement would
///   otherwise claim sequences whose content is on no frame at all — the room
///   would acknowledge them and the client would prune them unsent.
/// - the durable note (finding 3437-SO-03). The move persists the fresh overlay
///   and advances the mark BEFORE the judgement has run, so a restart in that
///   window would restore the owed writes by #3431's key rule alone and publish
///   an outdated one, with recency never consulted. The JS client has the same
///   window and holds its deferral in memory; Swift writes `_deferred_replay`
///   in the same transaction as the mark.
final class Format2DeferredReplayHermeticTests: XCTestCase {

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
        let directory: String
        let resolved: LockedBox<[DocumentOfflineWritesResolvedEvent]>
    }

    /// A client on `heldEpoch` over its own database file.
    private func makeFixture(
        heldEpoch: Int,
        directory: String? = nil,
        documentId: String? = nil,
        clientId: String = "me"
    ) async throws -> Fixture {
        let directory = try directory ?? {
            let path = NSTemporaryDirectory() + "/f2-defer-\(UUID().uuidString)"
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true
            )
            directories.append(path)
            return path
        }()
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")

        let documentId = documentId ?? "defer-\(UUID().uuidString.prefix(8))"
        let document = YDocument()
        let coordinator = Format2Coordinator(
            host: provider, clientId: clientId, logger: Logger(level: .none)
        )
        let resolved = LockedBox<[DocumentOfflineWritesResolvedEvent]>([])
        coordinator.onOfflineWritesResolved = { event in
            resolved.withValue { $0.append(event) }
        }
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: document
        )
        let shared = MultiDocModel(schema: Self.schema)
        let model = shared.connect(docId: documentId, doc: document)
        model.bindFormat2(binding)
        if heldEpoch > 0 { try binding.store.setEpoch(heldEpoch) }
        // Inside the offline window, so writes are accepted. Measured on the
        // REAL clock, because that is the one the window gate reads; the
        // recency judgement below runs on its own explicit numbers.
        try binding.store.noteSync(at: Int(Date().timeIntervalSince1970 * 1000))
        // And a measured server offset, or nothing is ever "clearly older":
        // with no offset the client's clock says nothing comparable and every
        // verdict degrades to the ambiguous case (edge E9).
        try binding.store.noteClockOffset(0)
        return Fixture(
            coordinator: coordinator, binding: binding, model: model,
            documentId: documentId, directory: directory, resolved: resolved
        )
    }

    /// The one timeline every case in this file is written against.
    ///
    /// Epoch 4's archive wrote `r1/title`, so its window is
    /// `(sealOfThree, sealOfFour]`: an offline write stamped `olderThanFour`
    /// is clearly before it and one stamped `newerThanFour` clearly after.
    private static let olderThanFour = 500_000
    private static let sealOfThree = 1_000_000
    private static let sealOfFour = 2_000_000
    private static let newerThanFour = 2_500_000
    private static let now = 3_000_000

    /// Commit one write with an exact timestamp.
    ///
    /// Through the write path rather than the model, because the recency rule
    /// is about the op's `ts` and `Model.create` stamps it from the clock.
    @discardableResult
    private func write(
        _ fixture: Fixture,
        id: String,
        kind: OverlayMutation.Kind = .create,
        fields: [String: JSONValue],
        at ts: Int
    ) throws -> Int {
        try fixture.binding.writePath.write(
            model: "Note",
            mutation: OverlayMutation(id: id, kind: kind, fields: fields),
            fields: fields.keys.sorted(),
            at: ts
        )
    }

    private func chain() -> [SealedEpochChainEntry] {
        [
            SealedEpochChainEntry(
                epoch: 3, sealedAt: Self.sealOfThree, downloadPath: "/g/3"
            ),
            SealedEpochChainEntry(
                epoch: 4, sealedAt: Self.sealOfFour, downloadPath: "/g/4"
            ),
        ]
    }

    private func archive(_ entries: [(String, JSONValue)]) -> Data {
        let overlay = OverlayDocument()
        overlay.applyRawEntries(entries, model: "Note")
        return Data(overlay.encodeStateAsUpdate())
    }

    /// Epoch 4 wrote `r1/title` — so an offline write to that field made before
    /// epoch 3's seal is clearly older, and one made after epoch 4's seal is
    /// clearly newer.
    private func archives() -> [Int: Data] {
        [
            3: archive([]),
            4: archive([("r1/title", .string("a peer's, later"))]),
        ]
    }

    // MARK: - Behavior 20 — the move defers, and withholds while it does

    func testTheMoveOfAReturningClientDefersTheCarryAndWithholdsItsSequences()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 3)
        // Written offline, against the epoch this client holds, before epoch
        // 3 was even sealed: clearly older than epoch 4's write.
        try write(
            fixture, id: "r1", fields: ["title": .string("mine, older")],
            at: Self.olderThanFour
        )
        XCTAssertEqual(try fixture.binding.store.pendingOps().map(\.seq), [1])

        let caughtUp = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId, target: 5, sealed: chain(),
            fetch: { [archives = archives()] in archives[$0.epoch] ?? Data() }, now: Self.now
        )
        XCTAssertEqual(caughtUp, .caughtUp(applied: [3, 4], epoch: 5))

        XCTAssertNil(
            fixture.binding.overlay.value(model: "Note", key: "r1/title"),
            "the fresh overlay is installed WITHOUT the owed write: publishing "
                + "it is exactly what the judgement is for"
        )
        XCTAssertEqual(
            fixture.coordinator.outbound.withheldCeiling(fixture.documentId), 1,
            "and no claim may cover it meanwhile — its content is on no frame "
                + "this client has sent"
        )
        let note = try XCTUnwrap(
            fixture.binding.store.deferredReplay(),
            "the debt is durable: a restart before the judgement must not "
                + "publish the write by the key rule alone (finding 3437-SO-03)"
        )
        XCTAssertEqual(note.throughSeq, 1)
        XCTAssertEqual(note.fromEpoch, 3)
        XCTAssertEqual(note.toEpoch, 5)
        XCTAssertEqual(note.kind, .ordinary)
        XCTAssertEqual(
            try fixture.binding.store.pendingOps().map(\.seq), [1],
            "the write is still owed — it has been judged by nobody yet"
        )

        // And a frame built in the window claims nothing.
        let resend = try XCTUnwrap(
            fixture.coordinator.wholeStateResend(documentId: fixture.documentId)
        )
        XCTAssertNil(
            resend.claim.stamps,
            "a whole-state frame between the move and the judgement claims no "
                + "span at all, so the room's update.ack cannot cover the owed "
                + "sequence (finding 3437-SO-02)"
        )
    }

    func testTheJudgementDropsTheOutdatedWriteAndSurfacesItExactlyOnce()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 3)
        try write(
            fixture, id: "r1", fields: ["title": .string("mine, older")],
            at: Self.olderThanFour
        )
        _ = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId, target: 5, sealed: chain(),
            fetch: { [archives = archives()] in archives[$0.epoch] ?? Data() }, now: Self.now
        )

        let outcome = try XCTUnwrap(
            fixture.coordinator.completeDeferredReplay(
                documentId: fixture.documentId, now: Self.now
            )
        )
        XCTAssertEqual(outcome.epoch, 5)
        XCTAssertEqual(outcome.dropped, [1])
        XCTAssertTrue(outcome.stated.isEmpty)
        // TWO notices, as js-bao gives: the field the online side beat, and
        // the record-level verdict that drops the create carrying it. Held to
        // the harness in `Format2OfflineReplayHermeticTests`; a create's
        // `_replace` discards the whole row, so losing the record-level race
        // is a separate fact from losing any one field.
        XCTAssertEqual(outcome.notices.map(\.reason), [.outdated, .outdated])
        XCTAssertEqual(outcome.notices.map(\.outcome), [.dropped, .dropped])
        XCTAssertEqual(outcome.notices.map(\.field), ["title", nil])
        XCTAssertEqual(outcome.notices.first?.epoch, 4)

        XCTAssertTrue(
            try fixture.binding.store.pendingOps().isEmpty,
            "a dropped write is forgotten from the durable log: leaving it "
                + "would replay it at the next open"
        )
        XCTAssertNil(
            fixture.binding.overlay.value(model: "Note", key: "r1/title"),
            "and it was never published"
        )
        XCTAssertEqual(
            try fixture.binding.store.read(model: "Note", recordId: "r1")?["title"],
            .string("a peer's, later"),
            "the online write stands"
        )
        XCTAssertNil(
            try fixture.binding.store.deferredReplay(),
            "the debt is settled"
        )
        XCTAssertEqual(
            fixture.coordinator.outbound.withheldCeiling(fixture.documentId), 0,
            "and the ordinary floor applies again"
        )

        XCTAssertEqual(fixture.resolved.value.count, 1)
        XCTAssertEqual(fixture.resolved.value.first?.documentId, fixture.documentId)
        XCTAssertEqual(fixture.resolved.value.first?.epoch, 5)
        XCTAssertEqual(fixture.resolved.value.first?.notices.count, 2)

        XCTAssertNil(
            try fixture.coordinator.completeDeferredReplay(
                documentId: fixture.documentId, now: Self.now
            ),
            "and a second call has nothing to judge"
        )
        XCTAssertEqual(
            fixture.resolved.value.count, 1, "exactly once when there are notices"
        )
    }

    func testASurvivingWriteIsStatedOnTheJoinedEpochAndClaimedAfterwards()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 3)
        // Written AFTER epoch 4 was sealed: clearly newer than the online
        // write it raced.
        try write(
            fixture, id: "r1", fields: ["title": .string("mine, newer")],
            at: Self.newerThanFour
        )
        _ = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId, target: 5, sealed: chain(),
            fetch: { [archives = archives()] in archives[$0.epoch] ?? Data() }, now: Self.now
        )

        let outcome = try XCTUnwrap(
            fixture.coordinator.completeDeferredReplay(
                documentId: fixture.documentId, now: Self.now
            )
        )
        XCTAssertEqual(outcome.stated, [1])
        XCTAssertTrue(outcome.dropped.isEmpty)
        XCTAssertTrue(
            outcome.notices.isEmpty,
            "a write that clearly won needs no notice: silence means every "
                + "offline write replayed cleanly"
        )
        XCTAssertEqual(
            fixture.binding.overlay.value(model: "Note", key: "r1/title"),
            .string("mine, newer"),
            "stated on the LIVE overlay, which is what publishes it"
        )
        XCTAssertTrue(
            fixture.resolved.value.isEmpty,
            "and no event with nothing to report"
        )

        let resend = try XCTUnwrap(
            fixture.coordinator.wholeStateResend(documentId: fixture.documentId)
        )
        XCTAssertEqual(
            resend.claim.stamps?.seqFrom, 1,
            "the withhold released, so the frame that carries the survivor may "
                + "claim it"
        )
        XCTAssertEqual(resend.claim.stamps?.seq, 1)
    }

    func testACreateTheRecordLevelRaceWentAgainstIsDroppedWhole() async throws {
        let fixture = try await makeFixture(heldEpoch: 3)
        try write(
            fixture, id: "r1",
            fields: ["title": .string("mine, older"), "body": .string("untouched")],
            at: Self.olderThanFour
        )
        _ = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId, target: 5, sealed: chain(),
            fetch: { [archives = archives()] in archives[$0.epoch] ?? Data() }, now: Self.now
        )
        let outcome = try XCTUnwrap(
            fixture.coordinator.completeDeferredReplay(
                documentId: fixture.documentId, now: Self.now
            )
        )

        // A create is never NARROWED: its `_replace` discards the base row, so
        // replaying part of it would state a record whose other fields the
        // create never had. It stands whole or not at all, and here the
        // record-level race went against it.
        XCTAssertEqual(outcome.dropped, [1])
        XCTAssertTrue(outcome.stated.isEmpty)
        XCTAssertTrue(outcome.narrowed.isEmpty)
        XCTAssertNil(
            fixture.binding.overlay.value(model: "Note", key: "r1/body"),
            "including the field nobody raced: a create is one write"
        )
    }

    func testAPatchLosesOnlyTheFieldTheOnlineSideBeatAndSaysSoDurably()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 3)
        // The record already exists locally, so the write is a PATCH — which
        // is the op the narrowing is about.
        try write(
            fixture, id: "r1",
            fields: ["title": .string("seed"), "body": .string("seed")],
            at: 100_000
        )
        try fixture.coordinator.handleUpdateAck(
            ["documentId": fixture.documentId, "maxContiguousSeq": 1]
        )
        try write(
            fixture, id: "r1", kind: .patch,
            fields: ["title": .string("mine, older"), "body": .string("mine, older")],
            at: Self.olderThanFour
        )
        XCTAssertEqual(try fixture.binding.store.pendingOps().map(\.seq), [2])

        _ = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId, target: 5, sealed: chain(),
            fetch: { [archives = archives()] in archives[$0.epoch] ?? Data() }, now: Self.now
        )
        let outcome = try XCTUnwrap(
            fixture.coordinator.completeDeferredReplay(
                documentId: fixture.documentId, now: Self.now
            )
        )

        XCTAssertEqual(outcome.stated, [2])
        XCTAssertEqual(outcome.narrowed, [2])
        XCTAssertEqual(outcome.notices.map(\.field), ["title"])
        XCTAssertEqual(outcome.notices.map(\.outcome), [.dropped])

        let row = try XCTUnwrap(
            fixture.binding.store.pendingOps().first { $0.seq == 2 }
        )
        XCTAssertEqual(
            row.fields, ["body"],
            "the DURABLE row is narrowed too, or a crash before the replay is "
                + "acknowledged would put the whole mutation back"
        )
        XCTAssertEqual(row.mutation?.fields.keys.sorted(), ["body"])
        XCTAssertEqual(
            fixture.binding.overlay.value(model: "Note", key: "r1/body"),
            .string("mine, older")
        )
        XCTAssertNil(
            fixture.binding.overlay.value(model: "Note", key: "r1/title"),
            "the field the online side beat is not published"
        )
    }

    // MARK: - Behavior 20a — a restart between the move and the judgement

    func testARestartKeepsTheOwedWritesOffTheOverlayUntilTheChainHasJudgedThem()
        async throws
    {
        let first = try await makeFixture(heldEpoch: 3)
        try write(
            first, id: "r1", fields: ["title": .string("mine, older")],
            at: Self.olderThanFour
        )
        try write(
            first, id: "r2", fields: ["title": .string("nobody raced this")],
            at: Self.olderThanFour
        )
        _ = try await first.coordinator.runCatchUp(
            documentId: first.documentId, target: 5, sealed: chain(),
            fetch: { [archives = archives()] in archives[$0.epoch] ?? Data() }, now: Self.now
        )
        XCTAssertEqual(try first.binding.store.deferredReplay()?.throughSeq, 2)
        // And the process stops HERE: after the mark moved, before the
        // judgement ran.
        first.coordinator.unbind(documentId: first.documentId)

        // A relaunch over the same file. A new instance means a new client id,
        // so the previous one's writes are adopted — under new sequences.
        let second = try await makeFixture(
            heldEpoch: 0, directory: first.directory,
            documentId: first.documentId, clientId: "me-restarted"
        )
        let adoption = try second.binding.adoptAndRestore()
        XCTAssertEqual(
            adoption.adopted.count, 2, "both owed writes were taken over"
        )
        XCTAssertEqual(
            adoption.restored, [],
            "and NONE of them was restored: the note holds every op it covers "
                + "off the overlay until recency has had its say"
        )
        XCTAssertEqual(
            adoption.deferred.sorted(), adoption.adopted.sorted(),
            "the note's span was re-mapped onto the sequences adoption gave them"
        )
        XCTAssertNil(
            second.binding.overlay.value(model: "Note", key: "r1/title"),
            "so the outdated write is on no overlay and has been published by "
                + "nobody"
        )
        XCTAssertEqual(
            second.coordinator.outbound.withheldCeiling(second.documentId),
            adoption.adopted.max(),
            "and the ceiling the session that deferred had set is back: the "
                + "join's whole-state frame carries none of their content, so "
                + "a claim over them would have them acknowledged unsent "
                + "(finding 3437-REVIEW-004)"
        )

        // The next handshake re-reads the chain the judgement needs. The
        // archives are decoded into a fresh ledger and NEVER folded: the
        // merged view already holds them.
        let folds = LockedBox(0)
        second.binding.onFolded(model: "Note") { folds.withValue { $0 += 1 } }
        XCTAssertTrue(
            try second.coordinator.resumeDeferredReplay(
                documentId: second.documentId, sealed: chain(),
                fetch: { [archives = archives()] in archives[$0.epoch] ?? Data() }, now: Self.now
            ),
            "the evidence is ready"
        )
        XCTAssertNotNil(
            try second.binding.store.deferredReplay(),
            "and nothing has been judged yet: `epoch.info` arrives BEFORE the "
                + "`syncStep2` carrying the joined epoch's content, and a "
                + "judgement against an empty overlay would miss every "
                + "conflict made in the open epoch (finding 3437-REVIEW-002)"
        )
        XCTAssertNil(
            second.binding.overlay.value(model: "Note", key: "r2/title"),
            "so not even the survivor is stated until the content is in"
        )

        // The joined epoch's `syncComplete`, which is where every deferral is
        // judged — one this session made, and one it inherited alike.
        let outcome = try XCTUnwrap(
            second.coordinator.completeDeferredReplay(
                documentId: second.documentId, now: Self.now
            )
        )
        XCTAssertTrue(outcome.resumed)
        XCTAssertEqual(
            outcome.notices.map(\.reason), [.outdated, .outdated],
            "the field the online side beat, and the create carrying it"
        )
        XCTAssertEqual(Set(outcome.notices.map(\.recordId)), ["r1"])
        XCTAssertEqual(
            try second.binding.store.pendingOps().map(\.seq),
            outcome.stated,
            "the outdated write was forgotten and the other one stands"
        )
        XCTAssertNil(
            second.binding.overlay.value(model: "Note", key: "r1/title"),
            "the outdated write was dropped and never claimed"
        )
        XCTAssertEqual(
            second.binding.overlay.value(model: "Note", key: "r2/title"),
            .string("nobody raced this"),
            "and the one nobody raced is stated on the joined epoch"
        )
        XCTAssertNil(try second.binding.store.deferredReplay())
        XCTAssertEqual(
            second.coordinator.outbound.withheldCeiling(second.documentId), 0
        )
    }

    func testAChainThatNoLongerCoversTheSpanKeepsTheWritesAsUnverifiable()
        async throws
    {
        let first = try await makeFixture(heldEpoch: 3)
        try write(
            first, id: "r1", fields: ["title": .string("mine, older")],
            at: Self.olderThanFour
        )
        _ = try await first.coordinator.runCatchUp(
            documentId: first.documentId, target: 5, sealed: chain(),
            fetch: { [archives = archives()] in archives[$0.epoch] ?? Data() }, now: Self.now
        )
        first.coordinator.unbind(documentId: first.documentId)

        let second = try await makeFixture(
            heldEpoch: 0, directory: first.directory,
            documentId: first.documentId, clientId: "me-restarted"
        )
        _ = try second.binding.adoptAndRestore()

        // Retention has taken epoch 4's archive since the move.
        let pruned = [
            SealedEpochChainEntry(epoch: 3, sealedAt: Self.sealOfThree, downloadPath: "/g/3"),
            SealedEpochChainEntry(epoch: 4, sealedAt: Self.sealOfFour, downloadPath: nil),
        ]
        XCTAssertTrue(
            try second.coordinator.resumeDeferredReplay(
                documentId: second.documentId, sealed: pruned,
                fetch: { [archives = archives()] in archives[$0.epoch] ?? Data() }, now: Self.now
            )
        )
        let outcome = try XCTUnwrap(
            second.coordinator.completeDeferredReplay(
                documentId: second.documentId, now: Self.now
            )
        )
        XCTAssertEqual(outcome.notices.map(\.reason), [.unverifiable])
        XCTAssertEqual(outcome.notices.map(\.outcome), [.keptAmbiguous])
        XCTAssertEqual(
            outcome.stated.count, 1,
            "nothing available says who else touched the field, so the write "
                + "replays whole and the app is told the check could not be made"
        )
        XCTAssertNil(try second.binding.store.deferredReplay())
        XCTAssertEqual(second.resolved.value.count, 1)
    }
    // MARK: - Finding 3437-REVIEW-003 — a later write owns KEYS, not records

    func testASurvivorWhoseRecordALaterWriteTouchedIsStatedInTheFieldsItOwns()
        async throws
    {
        let fixture = try await makeFixture(heldEpoch: 3)
        // A record the server already has, so only the patch below is owed.
        try write(
            fixture, id: "r1",
            fields: ["title": .string("seed"), "body": .string("seed")],
            at: Self.olderThanFour
        )
        try fixture.binding.store.prunePendingOps(
            maxContiguousSeq: try fixture.binding.store.nextSeq() - 1
        )
        // Made offline, to a field nobody else touched: it survives the
        // judgement.
        try write(
            fixture, id: "r1", kind: .patch,
            fields: ["body": .string("mine, owed")], at: Self.olderThanFour
        )
        _ = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId, target: 5, sealed: chain(),
            fetch: { [archives = archives()] in archives[$0.epoch] ?? Data() },
            now: Self.now
        )
        // The catch-up earned the sync mark on the judgement's own timeline
        // (1970), which is outside the offline window measured on the real
        // clock the write gate reads. Put it back, or the write below is
        // refused for a reason that has nothing to do with this case.
        try fixture.binding.store.noteSync(at: Int(Date().timeIntervalSince1970 * 1000))

        // And then, on the joined epoch, a write to a DIFFERENT field of the
        // same record — the ordinary case of an app going on working while the
        // judgement is owed.
        try write(
            fixture, id: "r1", kind: .patch,
            fields: ["title": .string("mine, newest")], at: Self.now
        )
        fixture.binding.settleFolds()

        let outcome = try XCTUnwrap(
            fixture.coordinator.completeDeferredReplay(
                documentId: fixture.documentId, now: Self.now
            )
        )
        XCTAssertEqual(
            outcome.stated.count, 1,
            "the survivor IS stated. Suppressing it per RECORD would leave its "
                + "content on no overlay while the whole-state claim that "
                + "follows covers its sequence — the field gone and reported "
                + "durable (finding 3437-REVIEW-003)"
        )
        XCTAssertEqual(
            fixture.binding.overlay.value(model: "Note", key: "r1/body"),
            .string("mine, owed"),
            "the field nobody else owns is put back"
        )
        XCTAssertEqual(
            fixture.binding.overlay.value(model: "Note", key: "r1/title"),
            .string("mine, newest"),
            "and the one the later local write owns is left exactly where that "
                + "write left it — reverting it would undo an edit the "
                + "application has already been told was saved"
        )
        XCTAssertNil(try fixture.binding.store.deferredReplay())
        XCTAssertEqual(
            fixture.coordinator.outbound.withheldCeiling(fixture.documentId), 0
        )
    }

    func testAnOlderOwedDeleteIsNotStatedOverALaterLocalRecreation() async throws {
        let fixture = try await makeFixture(heldEpoch: 3)
        try write(
            fixture, id: "r2", kind: .delete, fields: [:], at: Self.olderThanFour
        )
        _ = try await fixture.coordinator.runCatchUp(
            documentId: fixture.documentId, target: 5, sealed: chain(),
            fetch: { [archives = archives()] in archives[$0.epoch] ?? Data() },
            now: Self.now
        )
        try fixture.binding.store.noteSync(at: Int(Date().timeIntervalSince1970 * 1000))
        // The user made the record again on the joined epoch.
        try write(
            fixture, id: "r2", fields: ["title": .string("back again")], at: Self.now
        )
        fixture.binding.settleFolds()

        _ = try XCTUnwrap(
            fixture.coordinator.completeDeferredReplay(
                documentId: fixture.documentId, now: Self.now
            )
        )
        XCTAssertNotEqual(
            fixture.binding.overlay.value(model: "Note", key: "r2/_deleted"),
            .bool(true),
            "a tombstone is a whole record rather than a key: a later write "
                + "that is not itself a delete means the record lives now, and "
                + "the delete no longer describes anything "
                + "(finding 3437-REVIEW-003)"
        )
        XCTAssertEqual(
            fixture.binding.overlay.value(model: "Note", key: "r2/title"),
            .string("back again")
        )
    }
}
