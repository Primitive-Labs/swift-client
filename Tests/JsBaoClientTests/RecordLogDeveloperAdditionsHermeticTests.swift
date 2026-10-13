import XCTest
import YSwift
@testable import JsBaoClient

/// The three developer additions on a record-log (format-3) document, without
/// a server: `save(…, confirm:)`, `PrimitiveRecord.syncState`, and `transact`
/// landing a document's saves as one entry. The room's acknowledgements and
/// refusals are applied to the binding as the session applies them.
final class RecordLogDeveloperAdditionsHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static let note = PrimitiveSchema(
        name: "Note",
        fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "tags": FieldDescriptor(type: .stringset)]
    )
    private static let tag = PrimitiveSchema(
        name: "Tag",
        fields: ["id": FieldDescriptor(type: .id), "label": FieldDescriptor(type: .string)]
    )

    private struct Fixture {
        let binding: RecordLogDocumentBinding
        let notes: DynamicModel
        let tags: DynamicModel
    }

    private func makeFixture() async throws -> Fixture {
        let directory = NSTemporaryDirectory() + "/rl-additions-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let binding = try RecordLogDocumentBinding(
            host: provider, documentId: "doc-1", clientId: "client-1", engine: BaoModelQueryEngine(host: provider)
        )
        let doc = YDocument()
        let notes = MultiDocModel(schema: Self.note).connect(docId: "doc-1", doc: doc)
        try notes.bindRecordLog(binding)
        let tags = MultiDocModel(schema: Self.tag).connect(docId: "doc-1", doc: doc)
        try tags.bindRecordLog(binding)
        return Fixture(binding: binding, notes: notes, tags: tags)
    }

    /// What the session does when the room acknowledges `seqs`.
    private func acknowledge(_ binding: RecordLogDocumentBinding, _ seqs: [Int]) {
        binding.notify(binding.acknowledged(seqs))
    }

    private func pending(_ binding: RecordLogDocumentBinding) throws -> [RecordLogPendingEntry] {
        try binding.store.pendingOf(binding.writer)
    }

    // MARK: - Behavior 28: syncState

    func testSyncStateIsNilOffFormatThreeAndMovesPendingConfirmedOrRefused() async throws {
        let ordinary = MultiDocModel(schema: Self.note).connect(docId: "ordinary", doc: YDocument())
        XCTAssertNil(try ordinary.create(id: "o1", values: ["title": .string("format 1")]).syncState)

        let fixture = try await makeFixture()
        let heard = LockedBox(0)
        let unsubscribe = fixture.notes.subscribe { heard.withValue { $0 += 1 } }
        defer { unsubscribe() }
        let first = try fixture.notes.create(id: "n1", values: ["title": .string("one")])
        XCTAssertEqual(first.recordLogSeq, 1)
        XCTAssertEqual(first.syncState, .pending)
        let before = heard.value
        acknowledge(fixture.binding, [1])
        XCTAssertEqual(first.syncState, .confirmed)
        XCTAssertEqual(fixture.notes.find(id: "n1")?.syncState, .confirmed)
        let deadline = Date().addingTimeInterval(2)
        while heard.value == before && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThan(heard.value, before, "the model's listeners heard the confirmation")

        let second = try fixture.notes.save(id: "n2", values: ["title": .string("two")])
        fixture.binding.handBack([second.recordLogSeq ?? 0], error: JsBaoError(code: .documentConstraintViolated))
        XCTAssertEqual(second.syncState, .refused, "the handle whose save was handed back")
    }

    // MARK: - Behavior 27 and edge 47: confirm

    func testConfirmResolvesOnTheAcknowledgementAndThrowsTheHandBack() async throws {
        let fixture = try await makeFixture()
        let binding = fixture.binding
        let quick = try await fixture.notes.save(id: "q", values: ["title": .string("quick")], confirm: false)
        XCTAssertEqual(quick.syncState, .pending, "confirm: false returns at once")

        let resolved = LockedBox(false)
        let confirmed = Task {
            let record = try await fixture.notes.save(id: "c", values: ["title": .string("confirmed")], confirm: true)
            resolved.withValue { $0 = true }
            return record
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(resolved.value, "not before the room acknowledges")
        let seq = try XCTUnwrap(try pending(binding).last?.seq)
        acknowledge(binding, [seq])
        let record = try await confirmed.value
        XCTAssertEqual(record.syncState, .confirmed)

        let refused = Task { try await fixture.notes.save(id: "r", values: ["title": .string("refused")], confirm: true) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let refusedSeq = try XCTUnwrap(try pending(binding).last?.seq)
        binding.handBack([refusedSeq], error: JsBaoError(code: .documentConstraintViolated, message: "taken"))
        do {
            _ = try await refused.value
            XCTFail("a refused save throws the hand-back's error")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .documentConstraintViolated)
        }

        // Edge 47: the document closes before the acknowledgement.
        let closing = Task { try await fixture.notes.save(id: "z", values: ["title": .string("closing")], confirm: true) }
        try await Task.sleep(nanoseconds: 50_000_000)
        binding.close()
        do {
            _ = try await closing.value
            XCTFail("a save waiting on a closed document throws")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertEqual(error.details?["documentId"], "doc-1")
        }
    }

    func testConfirmIsANoOpOnAFormatOneMember() async throws {
        let ordinary = MultiDocModel(schema: Self.note).connect(docId: "ordinary", doc: YDocument())
        let record = try await ordinary.save(id: "o1", values: ["title": .string("format 1")], confirm: true)
        XCTAssertEqual(record["title"], .string("format 1"))
        XCTAssertNil(record.syncState)
    }

    // MARK: - Edge 39: transact

    func testTransactLandsTheDocumentsSavesAsOneEntryAcrossModels() async throws {
        let fixture = try await makeFixture()
        try fixture.notes.transact {
            _ = try fixture.notes.create(id: "n1", values: ["title": .string("first")])
            try fixture.notes.update(id: "n1", values: ["title": .string("second")])
            try fixture.notes.addStringsetMember(id: "n1", fieldName: "tags", member: "x")
            _ = try fixture.tags.create(id: "t1", values: ["label": .string("red")])
            try fixture.notes.transact {
                _ = try fixture.notes.create(id: "n2", values: ["title": .string("nested")])
            }
            XCTAssertEqual(try pending(fixture.binding).count, 0, "nothing commits before the outermost exit")
            XCTAssertEqual(fixture.notes.find(id: "n1")?["title"], .string("second"), "reads inside see the transaction's saves")
        }
        let entries = try pending(fixture.binding)
        XCTAssertEqual(entries.count, 1, "one entry")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.m.id, "n1")
        XCTAssertEqual(entry.m.kind, .create, "a later patch merged into the create")
        XCTAssertEqual(entry.m.fields?["title"], "second")
        XCTAssertEqual(entry.m.stringSetDeltas?["tags"], ["x": true])
        XCTAssertEqual(entry.also?.map(\.id), ["t1", "n2"], "every record of the document, m plus also")
        XCTAssertEqual(fixture.notes.find(id: "n2")?["title"], .string("nested"))
        XCTAssertEqual(fixture.tags.find(id: "t1")?["label"], .string("red"))
    }

    func testATransactWhoseBodyThrowsStillCommitsWhatItSavedAndLeavesFormatOneAlone() async throws {
        let fixture = try await makeFixture()
        let ordinary = MultiDocModel(schema: Self.note).connect(docId: "ordinary", doc: YDocument())
        struct Stop: Error {}
        XCTAssertThrowsError(try fixture.notes.transact {
            _ = try fixture.notes.create(id: "n1", values: ["title": .string("before the throw")])
            _ = try ordinary.create(id: "o1", values: ["title": .string("format 1 inside")])
            throw Stop()
        }) { error in
            XCTAssertTrue(error is Stop, "the body's error comes back")
        }
        XCTAssertEqual(try pending(fixture.binding).map(\.m.id), ["n1"], "the saves before the throw, as one entry")
        XCTAssertEqual(ordinary.find(id: "o1")?["title"], .string("format 1 inside"), "a format-1 save is unaffected")
        XCTAssertNil(ordinary.find(id: "o1")?.syncState)
    }

    // MARK: - transact: uniqueness and notifications see the batch (4309-C2-05, C2-06)

    private static let item = PrimitiveSchema(
        name: "Item",
        fields: ["id": FieldDescriptor(type: .id), "slug": FieldDescriptor(type: .string, unique: true)]
    )

    func testUniquenessInsideTransactSeesTheTransactionsOwnSaves() async throws {
        let fixture = try await makeFixture()
        let items = MultiDocModel(schema: Self.item).connect(docId: "doc-1", doc: YDocument())
        try items.bindRecordLog(fixture.binding)

        // Two creates with one key in one transaction: the second is refused.
        XCTAssertThrowsError(try items.transact {
            _ = try items.create(id: "a", values: ["slug": .string("k")])
            _ = try items.create(id: "b", values: ["slug": .string("k")])
        }) { error in
            XCTAssertTrue(error is UniqueConstraintViolationError, "\(error)")
            XCTAssertEqual((error as? UniqueConstraintViolationError)?.existingRecordId, "a")
        }
        XCTAssertEqual(try pending(fixture.binding).map(\.m.id), ["a"], "only the first save lands")
        XCTAssertEqual(items.find(id: "a")?["slug"], .string("k"))
        XCTAssertNil(items.find(id: "b"))

        // Deleting the holder and reusing its key in one transaction is allowed.
        try items.transact {
            items.delete(id: "a")
            _ = try items.create(id: "c", values: ["slug": .string("k")])
        }
        XCTAssertNil(items.find(id: "a"))
        XCTAssertEqual(items.find(id: "c")?["slug"], .string("k"))
        let entry = try XCTUnwrap(try pending(fixture.binding).last)
        XCTAssertEqual([entry.m.id] + (entry.also ?? []).map(\.id), ["a", "c"], "one entry: the delete and the create")

        // Changing the holder's key inside the transaction frees the old one.
        try items.transact {
            try items.update(id: "c", values: ["slug": .string("moved")])
            _ = try items.create(id: "d", values: ["slug": .string("k")])
        }
        XCTAssertEqual(items.find(id: "d")?["slug"], .string("k"))
    }

    func testATransactNotifiesEachModelOnceAfterItsEntryIsApplied() async throws {
        let fixture = try await makeFixture()
        let heard = LockedBox(0)
        let unsubscribe = fixture.notes.subscribe { heard.withValue { $0 += 1 } }
        defer { unsubscribe() }
        try fixture.notes.transact {
            _ = try fixture.notes.create(id: "n1", values: ["title": .string("first")])
            try fixture.notes.update(id: "n1", values: ["title": .string("second")])
            _ = try fixture.notes.create(id: "n2", values: ["title": .string("other")])
            XCTAssertEqual(heard.value, 0, "nothing is heard before the entry is applied")
        }
        XCTAssertEqual(heard.value, 1, "one notification for the batch")
        XCTAssertEqual(try fixture.notes.query(["title": "second"]).count, 1, "a listener reads the applied entry")

        struct Stop: Error {}
        XCTAssertThrowsError(try fixture.notes.transact {
            _ = try fixture.notes.create(id: "n3", values: ["title": .string("before the throw")])
            XCTAssertEqual(heard.value, 1)
            throw Stop()
        })
        XCTAssertEqual(heard.value, 2, "the saves before a throw are applied and heard once")
    }
}
