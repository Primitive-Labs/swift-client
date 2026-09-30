import XCTest
@testable import JsBaoClient
import YSwift

/// A large document's rows answer a filtered query (#3436, behaviors 12 and
/// 13, decision 3436-SO-05).
///
/// `Model.query()`, `count()` and `aggregate()` run ONE SQL statement against
/// derived tables. A large document's records are not in the Y.Maps those
/// tables are mirrored from — they are in the document's own record store — so
/// until they are projected, a filtered read either answers without them
/// (a silent wrong answer) or refuses. This is the projection that lets it
/// answer, and the routing that decides which engine answers.
///
/// Two rules hold it together, and both are the subject of tests here:
///
/// - The projection runs on the PROVIDER'S OWN connection, never a second
///   handle on the same file (`setupStorage`'s comment records the
///   `SQLITE_BUSY` a second handle produced), and every statement of it is
///   checked — a projection write that failed silently would leave `query`
///   disagreeing with `find` for good, and the durable mark would preserve
///   that disagreement across a relaunch.
/// - The rows and the mark are DURABLE. A reopened document does not re-copy
///   its records, which at this document class's size is the whole point of
///   recording the mark; a closed document is excluded by the scope of the
///   read instead.
final class Format2QueryProjectionHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: - Fixture

    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, required: true),
            "views": FieldDescriptor(type: .number),
            "tags": FieldDescriptor(type: .stringset),
        ]
    )

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/f2-proj-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private struct Fixture {
        let host: any Format2SqlHost
        let coordinator: Format2Coordinator
        let binding: Format2DocumentBinding
        let shared: MultiDocModel
        let doc: YDocument
        let documentId: String
    }

    /// A coordinator with one large document bound, and a shared model with
    /// that document connected — exactly what `connectToSharedModels` builds.
    private func makeFixture(
        host: (any Format2SqlHost)? = nil,
        connectModel: Bool = true
    ) async throws -> Fixture {
        let sqlHost: any Format2SqlHost
        if let host { sqlHost = host } else { sqlHost = try await makeProvider() }
        let documentId = "proj-\(UUID().uuidString.prefix(8))"
        let doc = YDocument()
        let coordinator = Format2Coordinator(
            host: sqlHost, clientId: "me", logger: Logger(level: .warn)
        )
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: doc
        )
        let shared = MultiDocModel(schema: Self.schema)
        if connectModel {
            let member = shared.connect(docId: documentId, doc: doc)
            member.bindFormat2(binding)
        }
        return Fixture(
            host: sqlHost, coordinator: coordinator, binding: binding,
            shared: shared, doc: doc, documentId: documentId
        )
    }

    /// Land `mutations` in the document's overlay the way a peer's update
    /// does, and fold them.
    private func foldRemote(
        _ fixture: Fixture, _ mutations: [OverlayMutation], model: String = "Note"
    ) throws {
        let peer = OverlayDocument()
        try peer.applyUpdate(fixture.binding.overlay.encodeStateAsUpdate())
        for mutation in mutations { peer.apply(mutation, model: model) }
        try fixture.binding.overlay.applyUpdate(peer.encodeStateAsUpdate())
        try fixture.binding.observer.drain()
    }

    /// Every row the query tables hold for `Note`, read through the
    /// provider's own connection — so a test cannot be answered by an engine
    /// that wrote somewhere else.
    private func projectedRows(_ host: any Format2SqlHost) throws -> [Format2SqlRow] {
        try host.withConnection { connection in
            try connection.query("SELECT * FROM \"Note\" ORDER BY \"id\"")
        }
    }

    private func projectionMarks(_ host: any Format2SqlHost) throws -> [String] {
        try host.withConnection { connection in
            try connection.query(
                "SELECT doc_id, model FROM _query_projection ORDER BY doc_id, model"
            ).map { "\($0["doc_id"].stringValue ?? "")/\($0["model"].stringValue ?? "")" }
        }
    }

    // MARK: - Behavior 13 — the projection

    /// The rows a document already holds are copied into the query tables the
    /// first time a model connects, with the mark, in ONE transaction.
    ///
    /// Records arriving before the app registers the model is the ordinary
    /// case, not an exotic one: a cold load and a catch-up fold both land rows
    /// in the record store with nothing connected to it.
    func testConnectingProjectsTheRowsAlreadyInTheStoreAndMarksThem() async throws {
        let fixture = try await makeFixture(connectModel: false)
        try foldRemote(fixture, [
            OverlayMutation(
                id: "n1", kind: .create,
                fields: ["title": .string("first"), "views": .number(3)],
                stringSetDeltas: ["tags": ["red": true, "blue": true]]
            ),
            OverlayMutation(id: "n2", kind: .create, fields: ["title": .string("second")]),
        ])
        XCTAssertEqual(
            try projectionMarks(fixture.host), [],
            "precondition: nothing is projected before a model connects"
        )

        let member = fixture.shared.connect(docId: fixture.documentId, doc: fixture.doc)
        member.bindFormat2(fixture.binding)

        XCTAssertEqual(
            try projectionMarks(fixture.host), ["\(fixture.documentId)/Note"],
            "the connect marks the model as projected"
        )
        let rows = try projectedRows(fixture.host)
        XCTAssertEqual(
            rows.compactMap { $0["id"].stringValue }, ["n1", "n2"],
            "every row the store held is in the query table"
        )
        XCTAssertEqual(
            rows.first?["_meta_doc_id"].stringValue, fixture.documentId,
            "tagged with the document it came from, as the shared engine's rows are"
        )

        // And the facade answers a filtered read from them.
        let matched = try fixture.shared.query(["title": .string("first")], options: nil)
        XCTAssertEqual(matched.compactMap { $0["id"]?.stringValue }, ["n1"])
        XCTAssertEqual(
            matched.first?["tags"], .array([.string("blue"), .string("red")]),
            "a stringset answers from the junction rows the projection wrote"
        )
        XCTAssertEqual(try fixture.shared.count(nil), 2)
    }

    /// A projection that fails part-way leaves NEITHER the rows nor the mark,
    /// and the next connect does it again. A mark without the rows would make
    /// every later query answer short, for good.
    func testAFaultMidProjectionLeavesNeitherRowsNorMark() async throws {
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let fixture = try await makeFixture(host: failing, connectModel: false)
        try foldRemote(fixture, [
            OverlayMutation(id: "n1", kind: .create, fields: ["title": .string("first")]),
            OverlayMutation(id: "n2", kind: .create, fields: ["title": .string("second")]),
        ])

        failing.failStatementsContaining = "INSERT OR REPLACE INTO \"Note\""
        let member = fixture.shared.connect(docId: fixture.documentId, doc: fixture.doc)
        member.bindFormat2(fixture.binding)
        failing.failStatementsContaining = nil

        XCTAssertEqual(
            try projectionMarks(fixture.host), [],
            "a projection that threw leaves no mark"
        )
        XCTAssertEqual(
            try projectedRows(fixture.host).count, 0,
            "and no half-written rows: the whole projection is one transaction"
        )
        // A model that is not projected refuses a filtered read rather than
        // answering without the document's records.
        XCTAssertThrowsError(try fixture.shared.count(nil)) { error in
            XCTAssertEqual(
                (error as? JsBaoError)?.code, .format2ModelNotHydrated, "got \(error)"
            )
        }

        // The next connect projects again.
        let second = fixture.shared.connect(docId: fixture.documentId, doc: fixture.doc)
        second.bindFormat2(fixture.binding)
        XCTAssertEqual(try projectionMarks(fixture.host), ["\(fixture.documentId)/Note"])
        XCTAssertEqual(try fixture.shared.count(nil), 2)
    }

    /// A close and a reopen project NOTHING: the rows and the mark are durable,
    /// which is what keeps reopening a large document cheap. The query answers
    /// the same thing afterwards.
    func testACloseAndReopenProjectsNothingAndAnswersTheSameQuery() async throws {
        let fixture = try await makeFixture(connectModel: false)
        try foldRemote(fixture, [
            OverlayMutation(id: "n1", kind: .create, fields: ["title": .string("first")]),
        ])
        let member = fixture.shared.connect(docId: fixture.documentId, doc: fixture.doc)
        member.bindFormat2(fixture.binding)
        let projection = fixture.coordinator.queryProjection
        let runsAfterFirstConnect = projection.projectionsRun
        XCTAssertEqual(runsAfterFirstConnect, 1, "precondition: the first connect projected")

        fixture.shared.disconnect(docId: fixture.documentId)
        let reopened = fixture.shared.connect(docId: fixture.documentId, doc: fixture.doc)
        reopened.bindFormat2(fixture.binding)

        XCTAssertEqual(
            projection.projectionsRun, runsAfterFirstConnect,
            "the mark is durable: a reopen copies nothing"
        )
        XCTAssertEqual(
            try fixture.shared.query(["title": .string("first")], options: nil)
                .compactMap { $0["id"]?.stringValue },
            ["n1"],
            "and the query answers exactly what it answered before"
        )
    }

    /// A closed document does not answer: the read is scoped to the documents
    /// that are connected, so its durable rows are simply not selected.
    func testADisconnectedDocumentStopsAnsweringWithoutLosingItsRows() async throws {
        let fixture = try await makeFixture(connectModel: false)
        try foldRemote(fixture, [
            OverlayMutation(id: "n1", kind: .create, fields: ["title": .string("first")]),
        ])
        let member = fixture.shared.connect(docId: fixture.documentId, doc: fixture.doc)
        member.bindFormat2(fixture.binding)
        XCTAssertEqual(try fixture.shared.count(nil), 1, "precondition")

        fixture.shared.disconnect(docId: fixture.documentId)

        XCTAssertEqual(
            try fixture.shared.count(nil), 0,
            "a document the app closed is not part of the answer"
        )
        XCTAssertEqual(
            try projectedRows(fixture.host).count, 1,
            "but its rows stay on disk, so the reopen is cheap"
        )

        // A purge is what actually takes them: the account or the document is
        // being forgotten, not merely closed.
        try Format2RecordStore.purge(host: fixture.host, documentId: fixture.documentId)
        XCTAssertEqual(try projectedRows(fixture.host).count, 0)
        XCTAssertEqual(try projectionMarks(fixture.host), [])
    }

    /// A model that gained a field between app versions re-projects, and the
    /// new field answers a filtered read.
    ///
    /// These tables are durable, so yesterday's table is still here today and
    /// `CREATE TABLE IF NOT EXISTS` leaves it alone. Without this, every
    /// projected write would fail on a column that does not exist — which is a
    /// fold-broken document — and a mark left standing over rows that never
    /// held the new value would make a read on it answer short for good.
    func testAModelThatGainedAFieldReprojectsWithIt() async throws {
        let fixture = try await makeFixture()
        let member = try XCTUnwrap(fixture.shared.member(docId: fixture.documentId))
        _ = try member.create(id: "n1", values: ["title": .string("before")])

        // The next version of the app, same database, same document: one more
        // field on the model.
        var fields = Self.schema.fields
        fields["colour"] = FieldDescriptor(type: .string, indexed: true)
        let widened = PrimitiveSchema(name: "Note", fields: fields)
        let sharedAfter = MultiDocModel(schema: widened)
        let after = sharedAfter.connect(docId: fixture.documentId, doc: fixture.doc)
        after.bindFormat2(fixture.binding)

        _ = try after.update(id: "n1", values: ["colour": .string("green")])

        XCTAssertEqual(
            try sharedAfter.query(["colour": .string("green")], options: nil)
                .compactMap { $0["id"]?.stringValue },
            ["n1"],
            "the new field is a column, and the row that gained a value answers on it"
        )
        XCTAssertEqual(
            try sharedAfter.count(nil), 1,
            "and the record written before the upgrade is still there, once"
        )
    }

    /// A fold's projected row commits with the merged row: the query and
    /// `find` never disagree, in either direction.
    func testAFoldsProjectedRowCommitsWithTheMergedRow() async throws {
        let fixture = try await makeFixture()

        try foldRemote(fixture, [
            OverlayMutation(id: "n1", kind: .create, fields: ["title": .string("first")]),
        ])
        XCTAssertEqual(
            try fixture.shared.query(["title": .string("first")], options: nil).count, 1,
            "an arriving record is queryable"
        )

        try foldRemote(fixture, [OverlayMutation(id: "n1", kind: .delete)])
        XCTAssertEqual(
            try fixture.shared.count(nil), 0,
            "and a tombstone takes it out of the query tables too"
        )
        XCTAssertNil(try fixture.binding.store.read(model: "Note", recordId: "n1"))
    }

    /// A local write's projected row commits with the merged row and the
    /// pending op — and a commit that fails leaves neither.
    func testALocalWriteProjectsInTheSameCommitAndARollbackTakesBoth() async throws {
        let provider = try await makeProvider()
        let failing = FailingSqlHost(wrapped: provider)
        let fixture = try await makeFixture(host: failing)
        let member = try XCTUnwrap(fixture.shared.member(docId: fixture.documentId))

        _ = try member.create(id: "n1", values: ["title": .string("kept")])
        XCTAssertEqual(
            try fixture.shared.query(["title": .string("kept")], options: nil).count, 1,
            "a local write is queryable the moment it returns"
        )

        failing.failStatementsContaining = "INSERT OR REPLACE INTO _pending_ops"
        XCTAssertThrowsError(try member.create(id: "n2", values: ["title": .string("lost")]))
        failing.failStatementsContaining = nil

        XCTAssertEqual(
            try projectedRows(fixture.host).compactMap { $0["id"].stringValue }, ["n1"],
            "the rolled-back write left no projected row either"
        )
    }

    /// The engine over the provider's handle reports a failing statement
    /// instead of answering with an empty result — the defect 3436-SO-05
    /// names. An empty answer from a broken query table is indistinguishable
    /// from an empty document.
    func testAFailingStatementOnTheHostBackedEngineThrows() async throws {
        let fixture = try await makeFixture()
        let engine = fixture.coordinator.queryProjection.engine

        try fixture.host.withConnection { try $0.executeScript("DROP TABLE \"Note\"") }

        XCTAssertThrowsError(try engine.query(modelName: "Note")) { error in
            XCTAssertTrue(
                "\(error)".contains("Note"),
                "the failure names the statement's table; got \(error)"
            )
        }
    }

    /// The projection runs on the provider's OWN connection: the query tables
    /// are in the provider's database, and a `kv_store` write in flight beside
    /// a projection neither fails nor is failed by it. A second handle on one
    /// WAL file is what produced `SQLITE_BUSY` (`setupStorage`'s comment).
    func testTheProjectionSharesTheProvidersConnectionWithTheKeyValueStore() async throws {
        let provider = try await makeProvider()
        let fixture = try await makeFixture(host: provider, connectModel: false)
        let mutations = (0..<200).map {
            OverlayMutation(
                id: "n\($0)", kind: .create, fields: ["title": .string("row \($0)")]
            )
        }
        try foldRemote(fixture, mutations)

        // The projection and an auth-style key-value write, at the same time.
        async let kv: Void = {
            for index in 0..<50 {
                try? await provider.put(
                    store: "kv_store", key: "k\(index)", value: "v\(index)", metadata: nil
                )
            }
        }()
        let member = fixture.shared.connect(docId: fixture.documentId, doc: fixture.doc)
        member.bindFormat2(fixture.binding)
        await kv

        XCTAssertEqual(try projectedRows(fixture.host).count, 200)
        let stored: StorageRecord<String>? = try await provider.get(
            store: "kv_store", key: "k49"
        )
        XCTAssertEqual(stored?.value, "v49")
        XCTAssertEqual(
            try fixture.host.withConnection { connection in
                try connection.query(
                    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'Note'"
                ).count
            },
            1,
            "the query table is in the provider's own database, not a second one"
        )
    }

    // MARK: - Behavior 12 — routing

    /// A model with members of both kinds cannot answer an unscoped filtered
    /// read: the two kinds live in different engines, and merging them in
    /// Swift would be a second query language. It is refused by name.
    func testAnUnscopedReadAcrossBothKindsIsRefusedWithTheScopeCode() async throws {
        let fixture = try await makeFixture()
        let large = try XCTUnwrap(fixture.shared.member(docId: fixture.documentId))
        _ = try large.create(id: "n1", values: ["title": .string("large")])

        // An ordinary document on the same model.
        let ordinary = YDocument()
        let ordinaryMember = fixture.shared.connect(docId: "ordinary", doc: ordinary)
        _ = try ordinaryMember.create(id: "o1", values: ["title": .string("ordinary")])

        for read in [
            { _ = try fixture.shared.count(nil) },
            { _ = try fixture.shared.query(["title": .string("large")], options: nil) },
            {
                _ = try fixture.shared.aggregate(
                    AggregateOptions(operations: [AggregateOperation(type: .count)])
                )
            },
        ] as [() throws -> Void] {
            XCTAssertThrowsError(try read()) { error in
                XCTAssertEqual(
                    (error as? JsBaoError)?.code, .format2QueryScope, "got \(error)"
                )
            }
        }

        // The unfiltered reads still answer completely — they have no filter
        // to push down, so neither engine has to do the other's work.
        XCTAssertEqual(
            fixture.shared.findAll().compactMap { $0["id"]?.stringValue }.sorted(),
            ["n1", "o1"]
        )
    }

    /// A client whose documents are all large answers from the host-backed
    /// engine, with no refusal anywhere: the scope question does not arise.
    func testAClientWithOnlyLargeDocumentsAnswersFromTheHostEngine() async throws {
        let fixture = try await makeFixture()
        let member = try XCTUnwrap(fixture.shared.member(docId: fixture.documentId))
        _ = try member.create(id: "n1", values: ["title": .string("a"), "views": .number(1)])
        _ = try member.create(id: "n2", values: ["title": .string("b"), "views": .number(9)])

        XCTAssertEqual(
            try fixture.shared.query(["views": .number(9)], options: nil)
                .compactMap { $0["id"]?.stringValue },
            ["n2"]
        )
        XCTAssertEqual(try fixture.shared.count(["views": .number(9)]), 1)
        XCTAssertEqual(
            try fixture.shared.aggregate(
                AggregateOptions(operations: [AggregateOperation(type: .count)])
            ).first?["count"]?.numberValue,
            2
        )

        // And the per-document facade answers the same question for its own
        // document, scoped to it.
        XCTAssertEqual(try member.count(["views": .number(1)]), 1)
        XCTAssertEqual(
            try member.query(["views": .number(1)], options: nil)
                .compactMap { $0["id"]?.stringValue },
            ["n1"]
        )
    }

    /// Two large documents on one client answer as one model: the rows are
    /// tagged by document, and the scope is every connected one.
    func testTwoLargeDocumentsAnswerAsOneModel() async throws {
        let fixture = try await makeFixture()
        let first = try XCTUnwrap(fixture.shared.member(docId: fixture.documentId))
        _ = try first.create(id: "n1", values: ["title": .string("one")])

        let secondDoc = YDocument()
        let secondId = "proj-second"
        let secondBinding = try fixture.coordinator.bind(
            documentId: secondId, models: ["Note"], document: secondDoc
        )
        let secondMember = fixture.shared.connect(docId: secondId, doc: secondDoc)
        secondMember.bindFormat2(secondBinding)
        _ = try secondMember.create(id: "n2", values: ["title": .string("two")])

        XCTAssertEqual(try fixture.shared.count(nil), 2)
        XCTAssertEqual(
            try fixture.shared.query(["title": .string("two")], options: nil)
                .compactMap { $0["_meta_doc_id"]?.stringValue },
            [secondId],
            "each row still says which document it came from"
        )
    }

    /// A client with no large document at all is untouched: same engine, same
    /// answers, no projection tables consulted.
    func testAClientWithOnlyOrdinaryDocumentsIsUnchanged() async throws {
        let shared = MultiDocModel(schema: Self.schema)
        let doc = YDocument()
        let member = shared.connect(docId: "ordinary", doc: doc)
        _ = try member.create(id: "o1", values: ["title": .string("x")])

        XCTAssertEqual(
            try shared.query(["title": .string("x")], options: nil)
                .compactMap { $0["id"]?.stringValue },
            ["o1"]
        )
        XCTAssertEqual(try shared.count(nil), 1)
        XCTAssertEqual(try member.count(nil), 1)
    }
}
