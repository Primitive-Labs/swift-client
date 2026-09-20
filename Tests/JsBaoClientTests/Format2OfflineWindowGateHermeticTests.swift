import XCTest
@testable import JsBaoClient
import YSwift

/// The read-only window's gate (#3437, behaviors 2, 2a and 3).
///
/// Past the window the document keeps ANSWERING and stops ACCEPTING. The gate
/// sits at the shared commit boundary — `Format2WritePath.commitInsideOperation`
/// — rather than in `write`, because `addMember` and `removeMember` reach the
/// commit directly (finding 3437-SO-07): a gate in `write` alone would leave
/// stringset members writable past the window, recording writes outside the
/// period the server can replay them across. `write` refuses a second time,
/// early, before it takes the operation lock, so the common case never queues
/// behind a fold to be refused.
///
/// The throwing verbs throw. The public mutations that CANNOT throw —
/// `delete(id:)`, a `PrimitiveRecord` field setter, an explicit clear — refuse
/// without writing and report through `DocumentWriteRefusedEvent`, because
/// `DynamicModel.delete(id:)` is declared without `throws` and swallows the
/// delegate's error with `try?` (finding 3437-SO-08). Adding a throwing form
/// of those verbs would break every existing caller, so the event is the
/// compatible channel.
final class Format2OfflineWindowGateHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let dayMs = 24 * 60 * 60 * 1000

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "views": FieldDescriptor(type: .number),
            "tags": FieldDescriptor(type: .stringset),
        ]
    )

    private struct Fixture {
        let coordinator: Format2Coordinator
        let binding: Format2DocumentBinding
        let model: DynamicModel
        let doc: YDocument
        let documentId: String
        let refusals: LockedBox<[DocumentWriteRefusedEvent]>
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/f2-gate-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeFixture(host: (any Format2SqlHost)? = nil) async throws -> Fixture {
        let sqlHost: any Format2SqlHost
        if let host { sqlHost = host } else { sqlHost = try await makeProvider() }
        let documentId = "gate-\(UUID().uuidString.prefix(8))"
        let doc = YDocument()
        let coordinator = Format2Coordinator(
            host: sqlHost, clientId: "me", logger: Logger(level: .none)
        )
        let refusals = LockedBox<[DocumentWriteRefusedEvent]>([])
        coordinator.onWriteRefused = { event in
            refusals.withValue { $0.append(event) }
        }
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: doc
        )
        let shared = MultiDocModel(schema: Self.schema)
        let model = shared.connect(docId: documentId, doc: doc)
        model.bindFormat2(binding)
        return Fixture(
            coordinator: coordinator, binding: binding, model: model,
            doc: doc, documentId: documentId, refusals: refusals
        )
    }

    /// Put the document past its window: a mark `days` old against a 7-day
    /// window, which is what a client that has been away looks like.
    private func backDate(_ fixture: Fixture, days: Int = 30) throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        try fixture.binding.store.noteSync(
            at: now - days * Self.dayMs, windowDays: 7
        )
    }

    private func expectWindowRefusal(
        _ label: String, _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("\(label) should have been refused past the offline window")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .documentOfflineWindowExpired, label)
            XCTAssertNotNil(error.details?["lastSyncAt"], label)
            XCTAssertNotNil(error.details?["windowDays"], label)
            XCTAssertNotNil(error.details?["overdueMs"], label)
        } catch {
            XCTFail("\(label) threw \(error) rather than the typed window refusal")
        }
    }

    // MARK: - Behavior 2 — the gate at the shared commit boundary

    func testTheCommitBoundaryRefusesPastTheWindowAndLeavesNothing() async throws {
        let fixture = try await makeFixture()
        try backDate(fixture)

        // `commitInsideOperation` is the boundary every door runs through, so
        // it is asserted directly rather than only through one caller.
        try fixture.binding.writePath.withOperation {
            expectWindowRefusal("the commit boundary") {
                _ = try fixture.binding.writePath.commitInsideOperation(
                    model: "Note",
                    mutation: OverlayMutation(
                        id: "r1", kind: .create, fields: ["title": .string("x")]
                    ),
                    fields: ["title"]
                )
            }
        }

        XCTAssertNil(try fixture.binding.store.read(model: "Note", recordId: "r1"))
        XCTAssertEqual(try fixture.binding.store.pendingOps().count, 0)
        XCTAssertEqual(
            fixture.binding.overlay.entries(model: "Note").count, 0,
            "a refused write publishes nothing, so the refusal cannot itself "
            + "become a write that replays later"
        )
    }

    func testWriteRefusesEarlyBeforeItTakesTheOperationLock() async throws {
        let fixture = try await makeFixture()
        try backDate(fixture)

        // Held from another thread, so a refusal that waited for the lock
        // would block rather than return. The early check is what makes the
        // common case cheap AND what makes this return at all.
        let holding = expectation(description: "the operation is held")
        let release = expectation(description: "the refusal came back")
        Thread.detachNewThread {
            try? fixture.binding.writePath.withOperation {
                holding.fulfill()
                XCTAssertEqual(XCTWaiter.wait(for: [release], timeout: 5), .completed)
            }
        }
        await fulfillment(of: [holding], timeout: 5)

        expectWindowRefusal("write") {
            _ = try fixture.binding.writePath.write(
                model: "Note",
                mutation: OverlayMutation(id: "r2", kind: .create),
                fields: []
            )
        }
        release.fulfill()
    }

    func testTheStopAndFoldBrokenChecksComeFirst() async throws {
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let fixture = try await makeFixture(host: failing)
        try backDate(fixture)

        // A document that is BOTH stopped and past its window reports the
        // stop: the gate runs after the stop check, so a reload-required
        // document does not start reporting a window problem instead.
        fixture.binding.requireReload(
            Format2Coordinator.reloadRequired(documentId: fixture.documentId, plan: "epoch.seal")
        )
        do {
            _ = try fixture.binding.writePath.write(
                model: "Note", mutation: OverlayMutation(id: "r1", kind: .create), fields: []
            )
            XCTFail("a stopped document should refuse")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .format2ReloadRequired)
        }
        fixture.binding.clearReload()

        // And a fold-broken one reports the broken fold, for the same reason.
        failing.failStatementsContaining = "INSERT INTO records_f2_"
        fixture.binding.overlay.apply(
            OverlayMutation(id: "remote", kind: .create, fields: ["title": .string("r")]),
            model: "Note"
        )
        fixture.binding.settleFolds()
        _ = try? fixture.binding.writePath.foldPendingUnderOperation()
        failing.failStatementsContaining = nil

        do {
            _ = try fixture.binding.writePath.write(
                model: "Note", mutation: OverlayMutation(id: "r1", kind: .create), fields: []
            )
            XCTFail("a fold-broken document should refuse")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .format2FoldBroken)
        }
    }

    /// The check reads an in-memory mirror, not SQL: it runs on the declared
    /// hot path, once per write, and the numbers it needs change only when a
    /// frame arrives.
    func testTheCheckReadsNoSqlAtAll() async throws {
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let fixture = try await makeFixture(host: failing)
        try backDate(fixture)

        // Every read of the epoch row now fails. A gate that asked SQL for the
        // mark would report that failure instead of the window.
        failing.failStatementsContaining = "FROM _epoch"
        expectWindowRefusal("a write with the epoch row unreadable") {
            _ = try fixture.binding.writePath.write(
                model: "Note", mutation: OverlayMutation(id: "r1", kind: .create), fields: []
            )
        }
        failing.failStatementsContaining = nil
    }

    // MARK: - Behavior 2 — the throwing doors

    func testEveryThrowingModelVerbRefusesAndLeavesNothing() async throws {
        let fixture = try await makeFixture()

        // Seeded INSIDE the window, so the refusals below are about the window
        // and not about a record that does not exist.
        _ = try fixture.model.create(id: "n1", values: ["title": .string("seed")])
        try fixture.model.addStringsetMember(id: "n1", fieldName: "tags", member: "keep")
        let pendingBefore = try fixture.binding.store.pendingOps().count
        let rowBefore = try fixture.binding.store.read(model: "Note", recordId: "n1")
        let keysBefore = fixture.binding.overlay.entries(model: "Note").count

        try backDate(fixture)

        expectWindowRefusal("create") {
            _ = try fixture.model.create(id: "n2", values: ["title": .string("x")])
        }
        expectWindowRefusal("update") {
            try fixture.model.update(id: "n1", values: ["title": .string("x")])
        }
        expectWindowRefusal("save") {
            _ = try fixture.model.save(id: "n3", values: ["title": .string("x")])
        }
        expectWindowRefusal("addMember") {
            try fixture.model.addStringsetMember(id: "n1", fieldName: "tags", member: "new")
        }
        expectWindowRefusal("removeMember") {
            try fixture.model.removeStringsetMember(id: "n1", fieldName: "tags", member: "keep")
        }

        // Nothing moved: no merged row, no pending op, no overlay key.
        XCTAssertEqual(try fixture.binding.store.read(model: "Note", recordId: "n1"), rowBefore)
        XCTAssertNil(try fixture.binding.store.read(model: "Note", recordId: "n2"))
        XCTAssertNil(try fixture.binding.store.read(model: "Note", recordId: "n3"))
        XCTAssertEqual(try fixture.binding.store.pendingOps().count, pendingBefore)
        XCTAssertEqual(fixture.binding.overlay.entries(model: "Note").count, keysBefore)
        XCTAssertEqual(
            try fixture.binding.store.members(model: "Note", recordId: "n1", field: "tags"),
            ["keep"]
        )
        XCTAssertTrue(
            fixture.refusals.value.isEmpty,
            "a throwing verb throws; the event is the channel for the verbs that cannot"
        )
    }

    func testReadsKeepAnsweringPastTheWindow() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: [
            "title": .string("readable"), "views": .number(2),
        ])
        try backDate(fixture)

        let found = try XCTUnwrap(fixture.model.find(id: "n1"))
        XCTAssertEqual(found["title"], .string("readable"))
        XCTAssertEqual(try fixture.model.count(), 1)
        XCTAssertEqual(
            try fixture.model.query(["title": .string("readable")]).count,
            1
        )
    }

    func testASyncRestoresWrites() async throws {
        let fixture = try await makeFixture()
        try backDate(fixture)
        expectWindowRefusal("create before the sync") {
            _ = try fixture.model.create(id: "n1", values: ["title": .string("x")])
        }

        try fixture.binding.store.noteSync(at: Int(Date().timeIntervalSince1970 * 1000))

        _ = try fixture.model.create(id: "n1", values: ["title": .string("x")])
        XCTAssertNotNil(try fixture.binding.store.read(model: "Note", recordId: "n1"))
    }

    // MARK: - Behavior 2a — the doors that cannot throw

    func testDeleteRefusesWithoutWritingAndReportsTheEvent() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: ["title": .string("seed")])
        let pendingBefore = try fixture.binding.store.pendingOps().count
        try backDate(fixture)

        fixture.model.delete(id: "n1")

        // The record is still there — the delete wrote nothing at all.
        XCTAssertNotNil(try fixture.binding.store.read(model: "Note", recordId: "n1"))
        XCTAssertEqual(try fixture.binding.store.pendingOps().count, pendingBefore)

        let events = fixture.refusals.value
        XCTAssertEqual(events.count, 1, "exactly one refusal event")
        XCTAssertEqual(events.first?.documentId, fixture.documentId)
        XCTAssertEqual(events.first?.model, "Note")
        XCTAssertEqual(events.first?.recordId, "n1")
        XCTAssertEqual(events.first?.error.code, .documentOfflineWindowExpired)
        XCTAssertNotNil(events.first?.error.details?["overdueMs"])
    }

    func testARecordFieldSetterAndAnExplicitClearRefuseAndReportTheEvent()
        async throws
    {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: [
            "title": .string("seed"), "views": .number(1),
        ])
        let record = try XCTUnwrap(fixture.model.find(id: "n1"))
        try backDate(fixture)

        record["title"] = .string("assigned")
        record["views"] = nil

        XCTAssertEqual(
            try fixture.binding.store.read(model: "Note", recordId: "n1")?["title"],
            .string("seed"),
            "the assignment wrote nothing"
        )
        XCTAssertEqual(
            try fixture.binding.store.read(model: "Note", recordId: "n1")?["views"],
            .number(1),
            "the clear wrote nothing"
        )

        let events = fixture.refusals.value
        XCTAssertEqual(events.count, 2, "one per refused mutation")
        XCTAssertEqual(Set(events.map { $0.recordId }), ["n1"])
        for event in events {
            XCTAssertEqual(event.error.code, .documentOfflineWindowExpired)
            XCTAssertEqual(event.model, "Note")
        }
    }

    /// Every OTHER error on a non-throwing path keeps the handling #3436 left
    /// it: swallowed, with no refusal event — the event is about the window,
    /// not a second reporting channel for everything.
    func testAnotherErrorOnANonThrowingPathIsStillHandledAsBefore() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: ["title": .string("seed")])

        fixture.binding.requireReload(
            Format2Coordinator.reloadRequired(documentId: fixture.documentId, plan: "epoch.seal")
        )
        fixture.model.delete(id: "n1")

        XCTAssertNotNil(
            try fixture.binding.store.read(model: "Note", recordId: "n1"),
            "a stopped document's delete writes nothing, as #3436 left it"
        )
        XCTAssertTrue(
            fixture.refusals.value.isEmpty,
            "a reload-required refusal is not a window refusal and raises no event"
        )
    }

    // MARK: - Behavior 3 — where the mark is earned

    func testAJoinEarnsTheMarkAndRestoresWrites() async throws {
        let fixture = try await makeFixture()
        try backDate(fixture)
        expectWindowRefusal("create before the join") {
            _ = try fixture.model.create(id: "n1", values: ["title": .string("x")])
        }

        let now = Int(Date().timeIntervalSince1970 * 1000)
        _ = try fixture.coordinator.handleEpochInfo(
            [
                "documentId": fixture.documentId, "epoch": 0,
                "sealedEpochs": [], "offlineWindowDays": 7,
            ],
            now: now
        )

        XCTAssertEqual(try fixture.binding.store.lastSyncAt(), now)
        _ = try fixture.model.create(id: "n1", values: ["title": .string("x")])
    }

    func testAnUpdateAckEarnsTheMarkAndRestoresWrites() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: ["title": .string("seed")])
        try backDate(fixture)
        expectWindowRefusal("create before the ack") {
            _ = try fixture.model.create(id: "n2", values: ["title": .string("x")])
        }

        // An `update.ack` is the server speaking about THIS client's writes:
        // proof of contact as good as a handshake's, and the JS client earns
        // the mark on it for that reason.
        let now = Int(Date().timeIntervalSince1970 * 1000)
        _ = try fixture.coordinator.handleUpdateAck(
            ["documentId": fixture.documentId, "maxContiguousSeq": 1], now: now
        )

        XCTAssertEqual(try fixture.binding.store.lastSyncAt(), now)
        _ = try fixture.model.create(id: "n2", values: ["title": .string("x")])
    }
}
