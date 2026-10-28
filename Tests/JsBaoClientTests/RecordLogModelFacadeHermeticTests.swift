import XCTest
import JsBaoSQLite
import YSwift
@testable import JsBaoClient

/// A model bound to a record-log (format-3) document, used through the same
/// `DynamicModel` / `MultiDocModel` facade as any document: reads from the
/// document's view, filtered reads from its view too (its query tables until
/// #4700), writes as entries.
/// No server: the binding runs over a real `SQLiteStorageProvider`, and what
/// the room would send is applied through the binding's store.
final class RecordLogModelFacadeHermeticTests: XCTestCase {

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
            "title": FieldDescriptor(type: .string, required: true),
            "slug": FieldDescriptor(type: .string, unique: true),
            "views": FieldDescriptor(type: .number, indexed: true),
            "tags": FieldDescriptor(type: .stringset),
        ]
    )

    private static let tagSchema = PrimitiveSchema(
        name: "Tag",
        fields: ["id": FieldDescriptor(type: .id), "label": FieldDescriptor(type: .string)]
    )

    private struct Fixture {
        let provider: SQLiteStorageProvider
        let binding: RecordLogDocumentBinding
        let shared: MultiDocModel
        let model: DynamicModel
        let doc: YDocument
        let documentId: String
    }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/record-log-facade-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private func makeFixture(provider existing: SQLiteStorageProvider? = nil) async throws -> Fixture {
        let provider: SQLiteStorageProvider
        if let existing { provider = existing } else { provider = try await makeProvider() }
        let documentId = "rl-\(UUID().uuidString.prefix(8))"
        let binding = try RecordLogDocumentBinding(
            host: provider, documentId: documentId, clientId: "client-1",
            logger: Logger(level: .none)
        )
        let doc = YDocument()
        let shared = MultiDocModel(schema: Self.schema)
        let model = shared.connect(docId: documentId, doc: doc)
        try model.bindRecordLog(binding)
        return Fixture(provider: provider, binding: binding, shared: shared, model: model, doc: doc, documentId: documentId)
    }

    private func result(_ l: Int, _ changes: [RecordLogChange], w: String? = nil, seq: Int? = nil) -> RecordLogResultItem {
        .result(RecordLogResult(l: l, e: 1, changes: changes, w: w, seq: seq))
    }

    // MARK: - The facade over the view

    func testCreateUpdateMembersAndDeleteGoThroughTheStoreAndAnswerFromTheView() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let created = try model.create(id: "n1", values: [
            "title": .string("first"), "slug": .string("one"), "views": .number(3), "tags": .stringset(["b", "a"]),
        ])
        XCTAssertEqual(created["title"], .string("first"))
        XCTAssertEqual(created["views"], .number(3))
        XCTAssertEqual(created["tags"], .stringset(["a", "b"]))
        try model.update(id: "n1", values: ["title": .string("second")])
        try model.addStringsetMember(id: "n1", fieldName: "tags", member: "c")
        try model.removeStringsetMember(id: "n1", fieldName: "tags", member: "a")
        _ = try model.create(id: "n2", values: ["title": .string("other"), "views": .number(10)])

        let row = try XCTUnwrap(try fixture.binding.store.read(model: "Note", id: "n1"))
        XCTAssertEqual(row["title"], "second")
        XCTAssertEqual(row["tags"], ["b", "c"])
        XCTAssertEqual(try fixture.binding.store.pendingOf(fixture.binding.writer).map(\.m.kind),
                       [.create, .patch, .patch, .patch, .create])

        XCTAssertNotNil(model.find(id: "n1"))
        XCTAssertEqual(model.findAll().map(\.id).sorted(), ["n1", "n2"])
        XCTAssertEqual(try model.findByUnique(constraint: try XCTUnwrap(Self.schema.resolvedUniqueConstraints.first?.name),
                                              values: [.string("one")])?.id, "n1")
        XCTAssertEqual(try model.query(["views": .object(["$gt": .number(5)])]).compactMap { $0["id"]?.stringValue }, ["n2"])
        XCTAssertEqual(try model.count(), 2)
        let sums = try model.aggregate(AggregateOptions(operations: [AggregateOperation(type: .sum, field: "views")]))
        XCTAssertEqual(sums.first?["sum_views"]?.numberValue, 13)
        XCTAssertEqual(fixture.shared.find(id: "n1")?.docId, fixture.documentId)
        XCTAssertEqual(fixture.shared.findAll().count, 2)
        XCTAssertEqual(try fixture.shared.query(["title": "second"]).count, 1)

        created["title"] = .string("by subscript")
        XCTAssertEqual(try fixture.binding.store.read(model: "Note", id: "n1")?["title"], "by subscript")
        created["slug"] = nil
        XCTAssertEqual(try fixture.binding.store.read(model: "Note", id: "n1")?["slug"], .null,
                       "a cleared field is a present null")
        model.delete(id: "n2")
        XCTAssertNil(model.find(id: "n2"))
        XCTAssertEqual(try model.count(), 1)
    }

    func testAKeyTheViewHoldsIsRefusedAtTheSaveAndNothingIsWritten() async throws {
        let fixture = try await makeFixture()
        _ = try fixture.model.create(id: "n1", values: ["title": .string("a"), "slug": .string("taken")])
        let before = try fixture.binding.store.marks()
        XCTAssertThrowsError(try fixture.model.create(id: "n2", values: ["title": .string("b"), "slug": .string("taken")])) { error in
            XCTAssertTrue(error is UniqueConstraintViolationError, "\(error)")
        }
        let after = try fixture.binding.store.marks()
        XCTAssertEqual(after.nextSeq, before.nextSeq, "nothing was written")
        XCTAssertEqual(after.pending, before.pending)
        XCTAssertNil(try fixture.binding.store.read(model: "Note", id: "n2"))
    }

    func testAnUpsertThatFindsNoHolderTravelsAsAnUpsertAndOneThatDoesPatchesIt() async throws {
        let fixture = try await makeFixture()
        let fresh = try fixture.model.upsert(["title": .string("x"), "slug": .string("k1")], on: "slug", id: "mine")
        XCTAssertTrue(fresh.wasCreated)
        let entry = try XCTUnwrap(try fixture.binding.store.pendingOf(fixture.binding.writer).last)
        XCTAssertEqual(entry.upsertOn, "slug", "the room resolves it too")
        XCTAssertEqual(entry.m.kind, .create)

        let merged = try fixture.model.upsert(["title": .string("y"), "slug": .string("k1")], on: "slug")
        XCTAssertFalse(merged.wasCreated)
        XCTAssertEqual(merged.record.id, "mine")
        let patch = try XCTUnwrap(try fixture.binding.store.pendingOf(fixture.binding.writer).last)
        XCTAssertEqual(patch.m.kind, .patch)
        XCTAssertNil(patch.upsertOn)
    }

    func testARemoteChangeMovesSubscribersAndTheQueryRows() async throws {
        let fixture = try await makeFixture()
        let heard = LockedBox(0)
        let unsubscribe = fixture.model.subscribe { heard.withValue { $0 += 1 } }
        defer { unsubscribe() }
        let writer = fixture.binding.writer
        let reply = try fixture.binding.withOperation {
            try fixture.binding.store.receive(writer: writer, items: [
                result(1, [RecordLogChange(model: "Note", id: "r1", row: ["id": "r1", "title": "remote", "views": 4])]),
            ])
        }
        fixture.binding.notify(reply.changed.map { RecordLogRecordKey(model: $0.model, id: $0.id) })
        let deadline = Date().addingTimeInterval(2)
        while heard.value == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThan(heard.value, 0, "the model's listeners heard the remote change")
        XCTAssertEqual(fixture.model.find(id: "r1")?["title"], .string("remote"))
        XCTAssertEqual(try fixture.model.query(["views": 4]).count, 1)
    }

    // MARK: - Behavior 50 through the facade, and edge 42's error listener

    func testFiftyFacadeSavesLandInOneCommitAndTheSessionHearsThemAfterIt() async throws {
        let fixture = try await makeFixture()
        fixture.provider.recordLogGroupCommit.commitAfterMs = 60_000
        let commits = CommitCounter()
        try commits.install(on: fixture.provider)
        let heard = LockedBox<[[Int]]>([])
        fixture.binding.onCommitted { entries in
            heard.withValue { $0.append(entries.map(\.seq)) }
            XCTAssertEqual(commits.count, 1, "the session hears entries only after their COMMIT")
        }
        for index in 0..<50 {
            _ = try fixture.model.save(id: "n\(index)", values: ["title": .string("t\(index)")])
            XCTAssertNotNil(fixture.model.find(id: "n\(index)"), "readable the moment the save returns")
        }
        XCTAssertEqual(commits.count, 0)
        XCTAssertTrue(heard.value.isEmpty)
        XCTAssertEqual(fixture.binding.syncState(model: "Note", id: "n0", lastSeq: 1), .pending)
        try fixture.binding.store.flush()
        XCTAssertEqual(commits.count, 1, "fifty facade saves, one COMMIT")
        XCTAssertEqual(heard.value.flatMap { $0 }, Array(1...50))
    }

    func testAFailedGroupCommitReachesTheBindingsErrorListenerAndHandsTheSavesBack() async throws {
        let provider = try await makeProvider()
        try provider.withConnection { connection in
            try connection.executeScript("PRAGMA foreign_keys=ON")
            try connection.executeScript("CREATE TABLE commit_parent (id TEXT PRIMARY KEY)")
            try connection.executeScript(
                "CREATE TABLE commit_child (pid TEXT REFERENCES commit_parent(id) DEFERRABLE INITIALLY DEFERRED)"
            )
        }
        let fixture = try await makeFixture(provider: provider)
        provider.recordLogGroupCommit.commitAfterMs = 60_000
        let errors = LockedBox<[JsBaoError]>([])
        fixture.binding.onError { error in errors.withValue { $0.append(error) } }
        let entry = try XCTUnwrap(try fixture.binding.commit([RecordLogWrite(mutations: [
            RecordLogMutation(model: "Note", id: "n1", kind: .create, fields: ["title": "t"]),
        ])]).first)
        try fixture.binding.store.save { sql in try sql.exec("INSERT INTO commit_child (pid) VALUES ('missing')") }
        try fixture.binding.store.flush()

        XCTAssertEqual(errors.value.count, 1)
        XCTAssertEqual(errors.value.first?.code, .unavailable)
        XCTAssertEqual(errors.value.first?.details?["reason"], "commit-failed")
        XCTAssertEqual(errors.value.first?.details?["documentId"], .string(fixture.documentId))
        XCTAssertEqual(fixture.binding.syncState(model: "Note", id: "n1", lastSeq: entry.seq), .refused)
        do {
            try await fixture.binding.whenAcknowledged(entry.seq)
            XCTFail("a save whose group did not commit is not acknowledged")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .unavailable)
        }
        XCTAssertNil(fixture.model.find(id: "n1"), "the view was rolled back with the group")
        XCTAssertEqual(try fixture.binding.store.pendingOf(fixture.binding.writer), [])
    }

    /// 4309-C2-07: a failed group's numbers are minted again; the save that
    /// takes one starts clean, and the handle of the failed save stays refused.
    func testASaveAfterAFailedGroupCommitDoesNotInheritItsRefusal() async throws {
        let provider = try await makeProvider()
        try provider.withConnection { connection in
            try connection.executeScript("PRAGMA foreign_keys=ON")
            try connection.executeScript("CREATE TABLE commit_parent (id TEXT PRIMARY KEY)")
            try connection.executeScript(
                "CREATE TABLE commit_child (pid TEXT REFERENCES commit_parent(id) DEFERRABLE INITIALLY DEFERRED)"
            )
        }
        let fixture = try await makeFixture(provider: provider)
        provider.recordLogGroupCommit.commitAfterMs = 60_000
        let failed = try fixture.model.save(id: "n1", values: ["title": .string("lost")])
        try fixture.binding.store.save { sql in try sql.exec("INSERT INTO commit_child (pid) VALUES ('missing')") }
        try fixture.binding.store.flush()
        XCTAssertEqual(failed.syncState, .refused)

        let next = try fixture.model.save(id: "n2", values: ["title": .string("kept")])
        XCTAssertEqual(next.recordLogSeq, failed.recordLogSeq, "the failed group's number is minted again")
        XCTAssertEqual(next.syncState, .pending, "a new save does not inherit the failed one's refusal")
        XCTAssertEqual(failed.syncState, .refused, "the failed save's handle stays refused")
        try fixture.binding.store.flush()

        let seq = try XCTUnwrap(next.recordLogSeq)
        let waiter = Task { try await fixture.binding.whenAcknowledged(seq) }
        try await Task.sleep(nanoseconds: 20_000_000)
        fixture.binding.notify(fixture.binding.acknowledged([seq]))
        try await waiter.value
        XCTAssertEqual(next.syncState, .confirmed)
        XCTAssertEqual(failed.syncState, .refused)
    }

    // MARK: - Edge 53: no Yjs traffic

    func testAFormatThreeSaveWritesNothingIntoTheYDocument() async throws {
        let fixture = try await makeFixture()
        let updates = LockedBox(0)
        let subscription = fixture.doc.observeUpdate { _ in updates.withValue { $0 += 1 } }
        defer { subscription.cancel() }
        _ = try fixture.model.create(id: "n1", values: ["title": .string("first")])
        _ = try fixture.model.save(id: "n1", values: ["title": .string("again")])
        fixture.model.delete(id: "n1")
        XCTAssertEqual(updates.value, 0, "the YDocument emitted no update")
        let meta = fixture.doc.transactSync { transaction -> [String] in
            guard let map = transaction.transactionGetMap(name: "_meta_Note") else { return [] }
            let collector = DynamicModel.KeyCollector()
            map.keys(tx: transaction, delegate: collector)
            return collector.keys
        }
        XCTAssertEqual(meta, [], "the model's declaration goes in record.declare, never into _meta_Note")
    }

    // MARK: - Edge 43: a model registered after the open

    func testAModelRegisteredAfterTheOpenIsHydratedFromTheView() async throws {
        let fixture = try await makeFixture()
        let writer = fixture.binding.writer
        _ = try fixture.binding.withOperation {
            try fixture.binding.store.receive(writer: writer, items: [
                result(1, [RecordLogChange(model: "Tag", id: "t1", row: ["id": "t1", "label": "red"])]),
                result(2, [RecordLogChange(model: "Tag", id: "t2", row: ["id": "t2", "label": "blue"])]),
            ])
        }
        let tags = MultiDocModel(schema: Self.tagSchema)
        let member = tags.connect(docId: fixture.documentId, doc: fixture.doc)
        try member.bindRecordLog(fixture.binding)
        XCTAssertEqual(try member.query(["label": "blue"]).compactMap { $0["id"]?.stringValue }, ["t2"])
        XCTAssertEqual(try member.count(), 2)
    }

    /// 4309-C2-04: a relaunch catches up before a model is registered; the
    /// model registered later reads the change. (Until #4700 its query tables
    /// were rebuilt then; a db3's rows live in its view only.)
    func testAModelRegisteredAfterACatchUpItMissedIsRebuiltFromTheView() async throws {
        let provider = try await makeProvider()
        let fixture = try await makeFixture(provider: provider)
        let tags = MultiDocModel(schema: Self.tagSchema)
        let member = tags.connect(docId: fixture.documentId, doc: fixture.doc)
        try member.bindRecordLog(fixture.binding)
        let first = fixture.binding.writer
        _ = try fixture.binding.withOperation {
            try fixture.binding.store.receive(writer: first, items: [
                result(1, [RecordLogChange(model: "Tag", id: "t1", row: ["id": "t1", "label": "red"])]),
            ])
        }
        XCTAssertEqual(try member.query(["label": "red"]).count, 1)
        fixture.binding.close()

        // The relaunch: only Note is registered when the room's change lands.
        let relaunched = try RecordLogDocumentBinding(
            host: provider, documentId: fixture.documentId, clientId: "client-2",
            logger: Logger(level: .none)
        )
        try relaunched.registerModel(Self.schema)
        let writer = relaunched.writer
        _ = try relaunched.withOperation {
            try relaunched.store.receive(writer: writer, items: [
                result(2, [RecordLogChange(model: "Tag", id: "t1", row: ["id": "t1", "label": "blue"])]),
                result(3, [RecordLogChange(model: "Tag", id: "t2", row: ["id": "t2", "label": "green"])]),
            ])
        }

        let later = MultiDocModel(schema: Self.tagSchema).connect(docId: fixture.documentId, doc: YDocument())
        try later.bindRecordLog(relaunched)
        XCTAssertEqual(later.find(id: "t1")?["label"], .string("blue"))
        XCTAssertEqual(try later.query(["label": "blue"]).compactMap { $0["id"]?.stringValue }, ["t1"],
                       "query agrees with the view")
        XCTAssertEqual(try later.query(["label": "red"]).count, 0)
        XCTAssertEqual(try later.count(), 2)
    }

    // MARK: - #4313 edge 046: a format-3 member beside an ordinary one

    func testAFilteredReadAcrossARecordLogAndAnOrdinaryDocumentIsRefusedAndFindAnswersBoth() async throws {
        let provider = try await makeProvider()
        let fixture = try await makeFixture(provider: provider)
        _ = try fixture.model.create(id: "three", values: ["title": .string("in format 3")])

        let ordinaryId = "f1-\(UUID().uuidString.prefix(8))"
        let ordinary = fixture.shared.connect(docId: ordinaryId, doc: YDocument())
        _ = try ordinary.create(id: "one", values: ["title": .string("in format 1")])

        XCTAssertThrowsError(try fixture.shared.query(["title": "in format 1"])) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .format2QueryScope)
        }
        XCTAssertThrowsError(try fixture.shared.count(nil))
        XCTAssertEqual(fixture.shared.find(id: "one")?.docId, ordinaryId)
        XCTAssertEqual(fixture.shared.find(id: "three")?.docId, fixture.documentId)
        XCTAssertEqual(Set(fixture.shared.findAll().compactMap { $0["id"]?.stringValue }), ["one", "three"])
        XCTAssertEqual(try fixture.shared.query(["title": "in format 3"], options: QueryOptions(documents: [fixture.documentId])).count, 1,
                       "a read scoped to the record-log document answers from its store")
        XCTAssertEqual(try fixture.shared.query(["title": "in format 1"], options: QueryOptions(documents: [ordinaryId])).count, 1,
                       "a read scoped to the ordinary document answers from the shared engine")
        XCTAssertEqual(try fixture.shared.count(nil, options: QueryOptions(documents: [fixture.documentId])), 1)
    }

    // MARK: - Helpers

    private final class CommitCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }

        func install(on provider: SQLiteStorageProvider) throws {
            let context = Unmanaged.passUnretained(self).toOpaque()
            _ = try provider.withRecordLogConnection { connection in
                sqlite3_commit_hook(connection.rawHandle, { context in
                    let counter = Unmanaged<CommitCounter>.fromOpaque(context!).takeUnretainedValue()
                    counter.lock.withLock { counter._count += 1 }
                    return 0
                }, context)
            }
        }
    }
}
