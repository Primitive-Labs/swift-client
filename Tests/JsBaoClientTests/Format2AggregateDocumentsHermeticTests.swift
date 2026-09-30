import XCTest
@testable import JsBaoClient
import YSwift

/// `AggregateOptions.documents` (#3760, criterion 4).
///
/// `query` and `count` have always taken a several-document scope;
/// `aggregate` never did, and the documents page told a Swift developer to
/// scope it with a `QueryOptions(documents:)` it does not take. The option
/// means here exactly what it means on `QueryOptions`: a list of documents,
/// with an explicit EMPTY list matching nothing.
///
/// The one thing that is not a straight forward: the engine's `aggregate`
/// SELECTED between the option and the bound document
/// (`documents ?? scopedToDocId`), where `query` and `count` AND them
/// (finding 3760-R6). A `DynamicModel` member bound to document A sharing a
/// query engine with B would then have answered B's rows for
/// `documents: [B]`, while the same option on `query` answers none. The
/// engine combines both restrictions now, so the matrix below holds for
/// `aggregate` and `query` alike — which is the claim, stated once for both.
final class Format2AggregateDocumentsHermeticTests: XCTestCase {

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
            "team": FieldDescriptor(type: .string),
        ]
    )

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let directory = NSTemporaryDirectory() + "/f2-aggdocs-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return provider
    }

    private struct Fixture {
        let coordinator: Format2Coordinator
        let shared: MultiDocModel
        var documentIds: [String]
    }

    @discardableResult
    private func connectLarge(
        coordinator: Format2Coordinator, shared: MultiDocModel, suffix: String
    ) throws -> String {
        let documentId = "agg-\(suffix)-\(UUID().uuidString.prefix(8))"
        let doc = YDocument()
        let binding = try coordinator.bind(
            documentId: documentId, models: ["Note"], document: doc
        )
        let member = shared.connect(docId: documentId, doc: doc)
        member.bindFormat2(binding)
        return documentId
    }

    /// Two large documents in one store, each holding one row of `Note`.
    private func twoLargeDocuments() async throws -> Fixture {
        let coordinator = Format2Coordinator(
            host: try await makeProvider(), clientId: "me", logger: Logger(level: .none)
        )
        let shared = MultiDocModel(schema: Self.schema)
        let a = try connectLarge(coordinator: coordinator, shared: shared, suffix: "a")
        let b = try connectLarge(coordinator: coordinator, shared: shared, suffix: "b")
        try XCTUnwrap(shared.member(docId: a)).save(
            id: "a1", values: ["title": .string("in a"), "team": .string("red")]
        )
        try XCTUnwrap(shared.member(docId: b)).save(
            id: "b1", values: ["title": .string("in b"), "team": .string("blue")]
        )
        return Fixture(coordinator: coordinator, shared: shared, documentIds: [a, b])
    }

    /// `AggregateOptions` is not `Sendable`, so a stored static would be
    /// refused under the v6 language mode; a factory is the same fixture.
    private static func grouped() -> AggregateOptions {
        AggregateOptions(
            groupBy: ["team"], operations: [AggregateOperation(type: .count)]
        )
    }

    /// The `team` values the aggregation grouped by, sorted.
    private func teams(_ rows: [[String: JSONValue]]) -> [String] {
        rows.compactMap { $0["team"]?.stringValue }.sorted()
    }

    // MARK: - The option, on the shared facade

    func testAggregateWithDocumentsSpansTwoLargeDocumentsAndNarrowsToOne() async throws {
        let fixture = try await twoLargeDocuments()
        let (a, b) = (fixture.documentIds[0], fixture.documentIds[1])

        var both = Self.grouped()
        both.documents = [a, b]
        XCTAssertEqual(teams(try fixture.shared.aggregate(both)), ["blue", "red"])

        var onlyA = Self.grouped()
        onlyA.documents = [a]
        XCTAssertEqual(teams(try fixture.shared.aggregate(onlyA)), ["red"])

        var onlyB = Self.grouped()
        onlyB.documents = [b]
        XCTAssertEqual(teams(try fixture.shared.aggregate(onlyB)), ["blue"])

        // Absent, it still spans everything connected, exactly as before.
        XCTAssertEqual(teams(try fixture.shared.aggregate(Self.grouped())), ["blue", "red"])
    }

    func testAnExplicitEmptyListMatchesNothing() async throws {
        let fixture = try await twoLargeDocuments()
        var none = Self.grouped()
        none.documents = []
        XCTAssertEqual(
            try fixture.shared.aggregate(none).count, 0,
            "an explicit empty list is the caller naming no documents"
        )
        // The same option on `query`, side by side.
        XCTAssertEqual(
            try fixture.shared.query(nil, options: QueryOptions(documents: [])).count, 0
        )
    }

    func testAMixOfAnOrdinaryAndALargeDocumentIsRefusedTyped() async throws {
        let fixture = try await twoLargeDocuments()
        let large = fixture.documentIds[0]
        let ordinaryId = "ordinary-\(UUID().uuidString.prefix(8))"
        fixture.shared.connect(docId: ordinaryId, doc: YDocument())

        var mixed = Self.grouped()
        mixed.documents = [large, ordinaryId]
        XCTAssertThrowsError(try fixture.shared.aggregate(mixed)) { error in
            guard let jsBao = error as? JsBaoError else {
                return XCTFail("expected a JsBaoError, got \(error)")
            }
            XCTAssertEqual(jsBao.code, .format2QueryScope)
        }
        // Scoped to one kind it answers.
        var scoped = Self.grouped()
        scoped.documents = [large]
        XCTAssertEqual(teams(try fixture.shared.aggregate(scoped)), ["red"])
    }

    // MARK: - The intersection rule (finding 3760-R6)

    /// A member bound to A, sharing one query engine with B. Every row of the
    /// matrix is asserted for `aggregate` AND for `query`, because the whole
    /// point of the finding is that the two must not disagree.
    func testAMemberBoundToOneDocumentIntersectsRatherThanReplaces() async throws {
        let fixture = try await twoLargeDocuments()
        let (a, b) = (fixture.documentIds[0], fixture.documentIds[1])
        let boundToA = try XCTUnwrap(fixture.shared.member(docId: a))

        let unscoped = teams(try boundToA.aggregate(Self.grouped()))
        XCTAssertEqual(unscoped, ["red"], "the member is bound to A")

        for (documents, expected) in [
            ([a], ["red"]),
            ([b], []),
            ([a, b], ["red"]),
            ([], []),
        ] as [([String], [String])] {
            var options = Self.grouped()
            options.documents = documents
            XCTAssertEqual(
                teams(try boundToA.aggregate(options)), expected,
                "aggregate(documents: \(documents))"
            )
            let rows = try boundToA.query(
                nil, options: QueryOptions(documents: documents)
            )
            XCTAssertEqual(
                rows.isEmpty, expected.isEmpty,
                "query(documents: \(documents)) must agree with aggregate"
            )
        }
    }

    /// A document the caller names that the shared model no longer holds
    /// (finding 3760-REVIEW-05).
    ///
    /// `format2Route` narrows the request to this model's CONNECTED large
    /// members, and `query` reads that narrowed scope. `aggregate` used to let
    /// the caller's own list win over it — and these query tables keep a closed
    /// document's rows (#3756), so the two reads answered differently for one
    /// request. The scopes are intersected now, so neither can widen the other.
    func testAClosedDocumentIsNotAggregatedWhereQueryWouldNotReadIt() async throws {
        let fixture = try await twoLargeDocuments()
        let (a, b) = (fixture.documentIds[0], fixture.documentIds[1])
        // B's rows stay in the shared query tables; the model stops holding it.
        fixture.shared.disconnect(docId: b)

        var both = Self.grouped()
        both.documents = [a, b]
        XCTAssertEqual(
            teams(try fixture.shared.aggregate(both)), ["red"],
            "a closed document is outside the routed scope, however the caller names it"
        )
        // The same request through `query`, side by side: one rule, two reads.
        let rows = try fixture.shared.query(nil, options: QueryOptions(documents: [a, b]))
        XCTAssertEqual(rows.compactMap { $0["team"]?.stringValue }.sorted(), ["red"])

        var onlyClosed = Self.grouped()
        onlyClosed.documents = [b]
        XCTAssertEqual(
            try fixture.shared.aggregate(onlyClosed).count, 0,
            "and naming only the closed document answers nothing, as query does"
        )
        XCTAssertEqual(
            try fixture.shared.query(nil, options: QueryOptions(documents: [b])).count, 0
        )
    }

    /// The engine itself, with no facade in front of it: the two restrictions
    /// are ANDed exactly as `count` ANDs them.
    func testTheEngineCombinesTheBoundDocumentAndTheOption() async throws {
        let fixture = try await twoLargeDocuments()
        let (a, b) = (fixture.documentIds[0], fixture.documentIds[1])
        let member = try XCTUnwrap(fixture.shared.member(docId: a))
        let engine = try XCTUnwrap(member.format2?.binding.projection.engine)

        func rows(_ documents: [String]?) throws -> Int {
            try engine.aggregate(
                modelName: "Note", options: Self.grouped(),
                scopedToDocId: a, documents: documents
            ).count
        }
        XCTAssertEqual(try rows(nil), 1, "the bound document alone")
        XCTAssertEqual(try rows([a]), 1)
        XCTAssertEqual(try rows([b]), 0, "the option must NARROW, never replace")
        XCTAssertEqual(try rows([a, b]), 1)
        XCTAssertEqual(try rows([]), 0)

        // And the two DOCUMENT scopes — the caller's option and the facade's
        // routed list — narrow each other rather than one winning (finding
        // 3760-REVIEW-05). Unscoped on either side never narrows.
        XCTAssertNil(BaoModelQueryEngine.narrow(nil, to: nil))
        XCTAssertEqual(BaoModelQueryEngine.narrow([a, b], to: nil), [a, b])
        XCTAssertEqual(BaoModelQueryEngine.narrow(nil, to: [a]), [a])
        XCTAssertEqual(BaoModelQueryEngine.narrow([a, b], to: [a]), [a])
        XCTAssertEqual(BaoModelQueryEngine.narrow([b], to: [a]), [])
        XCTAssertEqual(BaoModelQueryEngine.narrow([], to: [a, b]), [])
        // Exactly what `count` answers for the same pair of restrictions.
        XCTAssertEqual(
            try engine.count(modelName: "Note", scopedToDocId: a, documents: [b]), 0
        )
        XCTAssertEqual(
            try engine.count(modelName: "Note", scopedToDocId: a, documents: [a, b]), 1
        )
    }

    // MARK: - Source: appended, never inserted (#3764's lesson)

    func testDocumentsIsAppendedLastSoEveryExistingCallSiteCompiles() throws {
        // Every existing construction omits it, which only compiles while the
        // parameter is last AND defaulted. The suites above are the proof for
        // the labelled form; this is the positional one.
        let positional = AggregateOptions(
            groupBy: ["team"],
            operations: [AggregateOperation(type: .count)],
            filter: nil,
            sort: nil,
            limit: nil
        )
        XCTAssertNil(positional.documents)
        let named = AggregateOptions(
            groupBy: ["team"],
            operations: [AggregateOperation(type: .count)],
            documents: ["only-this-one"]
        )
        XCTAssertEqual(named.documents, ["only-this-one"])
    }
}
