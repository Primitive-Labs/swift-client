import XCTest
@testable import JsBaoClient

/// #5241 behaviors 17, 18 and 20 (Swift) — a read explained on the device, in
/// the server explain's shape, over a file-backed store: the port of js-bao's
/// `explainView`.
///
/// The store runs the read a request describes over one db3's copy, for real,
/// optionally forced onto a registry index (`INDEXED BY` the device's index at
/// the reader's FROM, the model then written as a literal, or that field's
/// member table) or off indexes (`none`: the view's primary key, no member or
/// text table), and answers each statement's plan taken with the run's
/// bindings, the registry indexes it used by this db3's own names, and whether
/// it scanned. Refusals throw `JsBaoError` with js-bao's codes and reasons.
final class Db3DeviceExplainStoreHermeticTests: XCTestCase {

    private var worlds: [Db3DeviceIndexWorld] = []

    override func tearDown() {
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    private static let doc = "01JD5241EXPLA1NSW1FT00000A"
    private static let other = "01JD5241EXPLA1NSW1FT00000B"
    private static let film = "Film"
    private static let review = "Review"
    private static let lowerFilm = "film"
    private static let genres = ["Action", "Comedy", "Drama", "Horror", "Western", "Sci-Fi"]

    private func world(_ label: String) async throws -> Db3DeviceIndexWorld {
        let world = try await Db3DeviceIndexWorld.make("explain-\(label)")
        worlds.append(world)
        return world
    }

    private func entry(_ name: String, _ model: String, _ field: String, kind: Db3IndexKind = .scalar, on: Db3IndexPlacement = .device) -> RecordLogIndexEntry {
        RecordLogIndexEntry(name: name, model: model, fields: [field], unique: false, kind: kind, on: on)
    }

    private var list: [RecordLogIndexEntry] {
        [
            entry("idx_records_film_year", Self.film, "year"),
            entry("idx_members_film_genres", Self.film, "genres", kind: .members),
            RecordLogIndexEntry(name: "idx_text_film", model: Self.film, fields: ["title"], unique: false, kind: .text, on: .device),
            entry("idx_records_review_film", Self.review, "film"),
            entry("idx_records_lower_film_year", Self.lowerFilm, "year"),
        ]
    }

    /// `documentId`'s store over `world` with 300 films (one genre each, and three of two), reviews of three films, ten `film` rows, and `list`.
    private func store(_ world: Db3DeviceIndexWorld, _ documentId: String = doc, list: [RecordLogIndexEntry]? = nil, typed: Bool = false) throws -> RecordLogStore {
        let store = try world.store(documentId)
        if typed {
            _ = try store.setState(writer: world.writer(documentId), type: .typed(
                name: "films", hash: "h5241",
                models: [Self.film: ["title": "string", "year": "number", "genres": "stringset"], Self.review: ["film": "string"]]
            ))
        }
        var films: [JSONValue] = (1...300).map { n in
            .object([
                "id": .string(String(format: "f%06d", n)), "title": .string("film number \(n) of a long and wordy catalogue"),
                "year": .number(Double(1900 + n % 120)), "genres": .array([.string(Self.genres[n % Self.genres.count])]),
            ])
        }
        for (i, pair) in [["Action", "Drama"], ["Comedy", "Drama"], ["Action", "Comedy"]].enumerated() {
            films.append(.object(["id": .string("m\(i)"), "title": .string("a film of two"), "year": 2100, "genres": .array(pair.map { .string($0) })]))
        }
        try world.seed(documentId, Self.film, films)
        try world.seed(documentId, Self.review, (0..<30).map { i in
            .object(["id": .string("r\(i)"), "film": .string(String(format: "f%06d", [50, 170, 290][i % 3]))])
        })
        try world.seed(documentId, Self.lowerFilm, (0..<10).map { i in .object(["id": .string("l\(i)"), "year": .number(Double(1950 + i))]) })
        try store.syncIndexes(list ?? self.list)
        return store
    }

    private func refusal(_ body: () throws -> Void) -> JsBaoError? {
        do {
            try body()
            return nil
        } catch {
            return error as? JsBaoError
        }
    }

    private let year: DocumentFilter = ["year": 1950]
    private let facet = AggregateOptions(groupBy: [.field("genres")], operations: [AggregateOperation(type: .count)])

    // MARK: - 17: the answer

    func testAQueryExplainsItselfInTheServersShape() async throws {
        let world = try await world("query")
        let store = try store(world)
        let answer = try store.explainView(Self.film, Db3ExplainRequest(op: .query, filter: year))
        XCTAssertEqual(answer.op, .query)
        XCTAssertEqual(answer.model, Self.film)
        XCTAssertNil(answer.index)
        XCTAssertEqual(answer.indexes, ["idx_records_film_year"])
        XCTAssertEqual(answer.scanned, [])
        XCTAssertEqual(answer.answered, 3)
        XCTAssertEqual(answer.cost, Db3ExplainCost(rowsRead: nil, rowsWritten: nil))
        XCTAssertTrue(answer.sqlite.hasPrefix("3."), answer.sqlite)
        XCTAssertEqual(answer.statements.count, 1)
        let statement = try XCTUnwrap(answer.statements.first)
        XCTAssertEqual(statement.model, Self.film)
        XCTAssertEqual(statement.runs, 1)
        XCTAssertEqual(statement.indexes, ["idx_records_film_year"])
        XCTAssertFalse(statement.scan)
        XCTAssertNil(statement.planError)
        // The partial index proves only with the run's `_type` bound: a plan taken without bindings could not name it.
        XCTAssertTrue(statement.plan?.joined(separator: "\n").contains("idx_record_log_view_4_film_4_year") ?? false, "\(statement.plan ?? [])")
        XCTAssertEqual(answer.answered, try store.queryView(Self.film, year).data.count)
    }

    func testCountAggregateAMemberAndATextIndexExplainThemselves() async throws {
        let world = try await world("kinds")
        let store = try store(world)
        XCTAssertEqual(try store.explainView(Self.film, Db3ExplainRequest(op: .count, filter: year)).answered, 3)
        let byYear = AggregateOptions(
            groupBy: [.field("year")], operations: [AggregateOperation(type: .count)], filter: ["year": ["$gte": 1950, "$lt": 1955]]
        )
        XCTAssertEqual(try store.explainView(Self.film, Db3ExplainRequest(op: .aggregate, aggregate: byYear)).answered, 5)
        XCTAssertEqual(
            try store.explainView(Self.film, Db3ExplainRequest(op: .query, filter: ["genres": ["$contains": "Drama"]])).indexes,
            ["idx_members_film_genres"]
        )
        XCTAssertEqual(try store.explainView(Self.film, Db3ExplainRequest(op: .query, filter: ["$search": "catalogue"])).indexes, ["idx_text_film"])
    }

    func testAFacetGroupsByMemberFromTheSessionsDeclarationsAndSetFieldsOverrides() async throws {
        let typedWorld = try await world("typed")
        let typed = try store(typedWorld, typed: true)
        let members = try typed.readView { _ in try RecordLogViewReader(store: typed, documents: [Self.doc]).aggregate(Self.film, facet, setFields: ["genres"]) }.count
        XCTAssertEqual(members, 6)
        XCTAssertEqual(try typed.explainView(Self.film, Db3ExplainRequest(op: .aggregate, aggregate: facet)).answered, members)
        // setFields in place of the declarations: none groups whole arrays.
        let arrays = try typed.explainView(Self.film, Db3ExplainRequest(op: .aggregate, aggregate: facet, setFields: [])).answered
        XCTAssertEqual(arrays, 9)
        let untypedWorld = try await world("untyped")
        let untyped = try store(untypedWorld)
        XCTAssertEqual(try untyped.explainView(Self.film, Db3ExplainRequest(op: .aggregate, aggregate: facet)).answered, arrays)
        XCTAssertEqual(try untyped.explainView(Self.film, Db3ExplainRequest(op: .aggregate, aggregate: facet, setFields: ["genres"])).answered, members)
    }

    func testRegistryNamesResolveWithinTheExplainedDb3() async throws {
        let world = try await world("names")
        let a = try store(world, list: [entry("a_year", Self.film, "year")])
        let b = try store(world, Self.other, list: [entry("b_year", Self.film, "year")])
        XCTAssertEqual(try world.rows(#"SELECT name FROM sqlite_master WHERE name LIKE 'idx\_record\_log\_view\_%' ESCAPE '\'"#).compactMap { $0["name"].stringValue },
                       ["idx_record_log_view_4_film_4_year"])
        XCTAssertEqual(try a.explainView(Self.film, Db3ExplainRequest(op: .query, filter: year)).indexes, ["a_year"])
        XCTAssertEqual(try b.explainView(Self.film, Db3ExplainRequest(op: .query, filter: year)).indexes, ["b_year"])
        XCTAssertEqual(refusal { _ = try b.explainView(Self.film, Db3ExplainRequest(op: .query, filter: year, index: "a_year")) }?.code, .db3IndexNotFound)
    }

    // MARK: - 18: forcing

    func testAScalarForceWritesIndexedByAtTheFromWithTheModelAsALiteral() async throws {
        let world = try await world("scalar")
        let store = try store(world)
        let answer = try store.explainView(Self.film, Db3ExplainRequest(op: .query, filter: ["year": 1950, "title": ["$ne": "x"]], index: "idx_records_film_year"))
        XCTAssertEqual(answer.index, "idx_records_film_year")
        let statement = try XCTUnwrap(answer.statements.first)
        XCTAssertTrue(statement.sql.contains(#"FROM record_log_view INDEXED BY "idx_record_log_view_4_film_4_year""#), statement.sql)
        XCTAssertTrue(statement.sql.contains("_type = 'Film'"), statement.sql)
        XCTAssertTrue(statement.plan?.joined(separator: "\n").contains("USING INDEX idx_record_log_view_4_film_4_year") ?? false)
        XCTAssertEqual(answer.indexes, ["idx_records_film_year"])
        XCTAssertEqual(answer.answered, 3)
        // A definition held under a `_2` name is hinted by that name, and answers its registry name.
        let lower = try store.explainView(Self.lowerFilm, Db3ExplainRequest(op: .query, filter: ["year": 1952], index: "idx_records_lower_film_year"))
        XCTAssertTrue(lower.statements.first?.sql.contains(#"INDEXED BY "idx_record_log_view_4_film_4_year_2""#) ?? false)
        XCTAssertEqual(lower.indexes, ["idx_records_lower_film_year"])
        XCTAssertEqual(lower.answered, 1)
    }

    func testNoneReadsThroughThePrimaryKeyAndNoMemberTable() async throws {
        let world = try await world("none")
        let store = try store(world)
        let answer = try store.explainView(Self.film, Db3ExplainRequest(op: .query, filter: year, index: "none"))
        XCTAssertTrue(answer.statements.first?.sql.contains(#"INDEXED BY "sqlite_autoindex_record_log_view_1""#) ?? false)
        XCTAssertEqual(answer.indexes, [])
        XCTAssertEqual(answer.scanned, [Self.film])
        XCTAssertEqual(answer.answered, 3)
        let contains = try store.explainView(Self.film, Db3ExplainRequest(op: .query, filter: ["genres": ["$contains": "Drama"]], index: "none"))
        XCTAssertFalse(contains.statements.contains { $0.sql.contains("idx_record_log_members_") })
        XCTAssertEqual(contains.scanned, [Self.film])
        XCTAssertEqual(contains.answered, try store.explainView(Self.film, Db3ExplainRequest(op: .query, filter: ["genres": ["$contains": "Drama"]])).answered)
    }

    func testAMemberForceReadsThatTableAndServesAFacetOnItsSetField() async throws {
        let world = try await world("member")
        let store = try store(world, typed: true)
        let forced = try store.explainView(Self.film, Db3ExplainRequest(op: .aggregate, aggregate: facet, index: "idx_members_film_genres"))
        XCTAssertEqual(forced.indexes, ["idx_members_film_genres"])
        XCTAssertEqual(forced.answered, 6)
        let none = try store.explainView(Self.film, Db3ExplainRequest(op: .aggregate, aggregate: facet, index: "none"))
        XCTAssertEqual(none.answered, 6)
        XCTAssertFalse(none.statements.contains { $0.sql.contains("idx_record_log_members_") })
    }

    func testEveryRefusalThrowsItsCodeAndReason() async throws {
        let world = try await world("refusals")
        let store = try store(world, list: list + [
            entry("idx_members_film_genres_server", Self.film, "genres", kind: .members, on: .server),
            entry("idx_records_film_title", Self.film, "title"),
        ], typed: true)
        func reason(_ request: Db3ExplainRequest, model: String = Self.film) -> (JsBaoErrorCode?, String?) {
            let error = refusal { _ = try store.explainView(model, request) }
            return (error?.code, error?.details?["reason"]?.stringValue)
        }
        let missing = refusal { _ = try store.explainView(Self.film, Db3ExplainRequest(op: .query, filter: year, index: "idx_nope")) }
        XCTAssertEqual(missing?.code, .db3IndexNotFound)
        XCTAssertEqual(missing?.details?["index"], "idx_nope")
        let elsewhere = refusal { _ = try store.explainView(Self.film, Db3ExplainRequest(op: .query, filter: year, index: "idx_records_review_film")) }
        XCTAssertEqual(elsewhere?.code, .db3IndexNotFound)
        XCTAssertEqual(elsewhere?.message, "The index idx_records_review_film is an index of Review, not of Film")
        XCTAssertTrue(reason(Db3ExplainRequest(op: .query, filter: ["$search": "x"], index: "idx_text_film")) == (.db3IndexCannotServe, "kind"))
        XCTAssertTrue(reason(Db3ExplainRequest(op: .query, filter: ["genres": ["$contains": "Drama"]], index: "idx_members_film_genres_server")) == (.db3IndexCannotServe, "placement"))
        XCTAssertTrue(reason(Db3ExplainRequest(op: .query, filter: ["title": "x"], index: "idx_records_film_year")) == (.db3IndexCannotServe, "fields"))
        XCTAssertTrue(reason(Db3ExplainRequest(op: .query, filter: year, index: "idx_members_film_genres")) == (.db3IndexCannotServe, "shape"))
        XCTAssertTrue(reason(Db3ExplainRequest(op: .query, filter: ["$search": "catalogue"], index: "none")) == (.db3IndexCannotServe, "search"))
        let near: DocumentFilter = ["$near": ["field": "embedding", "vector": [1, 0, 0, 0]]]
        XCTAssertTrue(reason(Db3ExplainRequest(op: .query, filter: near, index: "none")) == (.db3IndexCannotServe, "near"))
        XCTAssertTrue(reason(Db3ExplainRequest(op: .query, filter: near, index: "idx_records_film_year")) == (.db3IndexCannotServe, "near"))
        XCTAssertEqual(refusal { _ = try store.explainView(Self.film, Db3ExplainRequest(op: .query, index: "")) }?.code, .invalidArgument)
        // Not built here: declined, then a device index gone.
        _ = try store.declineIndex("idx_records_film_year")
        let declined = refusal { _ = try store.explainView(Self.film, Db3ExplainRequest(op: .query, filter: year, index: "idx_records_film_year")) }
        XCTAssertEqual(declined?.code, .db3IndexCannotServe)
        XCTAssertEqual(declined?.details?["reason"], "unbuilt")
        XCTAssertEqual(declined?.details?["status"], "declined")
        XCTAssertEqual(declined?.details?["why"], "declined on this device")
        try world.exec(#"DROP INDEX "idx_record_log_view_4_film_5_title""#)
        let gone = refusal { _ = try store.explainView(Self.film, Db3ExplainRequest(op: .query, filter: ["title": "x"], index: "idx_records_film_title")) }
        XCTAssertEqual(gone?.details?["status"], "unbuilt")
    }

    // MARK: - 20: an ordinary read after a forced explain (pin)

    func testAnOrdinaryReadAfterAForcedExplainCarriesNoIndexedBy() async throws {
        let world = try await world("pin")
        let store = try store(world)
        _ = try store.explainView(Self.film, Db3ExplainRequest(op: .query, filter: year, index: "idx_records_film_year"))
        _ = try store.explainView(Self.film, Db3ExplainRequest(op: .query, filter: ["genres": ["$contains": "Drama"]], index: "none"))
        let trace = try RecordLogStatementTrace.install(on: world.provider, self)
        XCTAssertEqual(try store.queryView(Self.film, year).data.count, 3)
        let drama = try store.countView(Self.film, ["genres": ["$contains": "Drama"]])
        _ = try store.queryView(Self.film, ["genres": ["$contains": "Drama"]])
        XCTAssertFalse(trace.viewReads.contains { $0.contains("INDEXED BY") }, "\(trace.viewReads)")
        XCTAssertEqual(trace.viewReads.filter { $0.contains(#""idx_record_log_members_"#) }.count, 2)
        XCTAssertEqual(drama, try store.explainView(Self.film, Db3ExplainRequest(op: .query, filter: ["genres": ["$contains": "Drama"]])).answered)
    }
}
