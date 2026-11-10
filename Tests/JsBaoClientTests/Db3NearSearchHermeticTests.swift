import XCTest
@testable import JsBaoClient

/// #5230 behaviors 12 to 16 and edge cases 35, 40 and 42 (the read's half) —
/// `$near` on a device read in Swift, js-bao's grammar, refusals, statements
/// and answer shape (#5229):
///
/// - 12: the grammar's refusals, each `.invalidArgument` with js-bao's
///   message, before any statement reads a record.
/// - 13: the state refusals in js-bao's order: a field the type does not
///   declare a vector, a vector of another length or holding a number that is
///   not finite, no entry, a declined entry, an unbuilt one.
/// - 14: exact `$near` equals brute force over the view's rows, cos and l2,
///   for k 1 to every row; `_distance` on every row whatever the projection;
///   a filter; count and aggregate keep its rows; a page pages on its cursors;
///   `_distance` rides the records' rows, `DynamicModel.query` rows and
///   `PrimitiveRow.raw`; the subqueries are the shared fixture's text.
/// - 15: ties at the kth distance break by `_id` whatever the insertion order.
/// - 16: with a model installed and filled the ANN table answers, reranked to
///   the exact distance; while its fill runs the flat table answers.
/// - 35: a read over several db3s is refused naming the count; an include
///   leg's `$near` is refused as before (pin).
/// - 40: `k` above the row count answers every row; `k` 10,000 is admitted.
/// - 42: `$search` beside `$near` is refused; a `$near.filter` on a member
///   indexed field reads its member table.
final class Db3NearSearchHermeticTests: XCTestCase {

    private typealias F = Db3VectorFixture
    private typealias Support = Db3VectorTestSupport

    private static let db3 = "db3-near"
    private static let dims = 16
    private static let encoding = VectorEncoding(dims: dims, element: .f32)
    private static let schema = PrimitiveSchema(
        name: "Note",
        fields: [
            "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "n": FieldDescriptor(type: .number),
            "embedding": FieldDescriptor(type: .vector, dims: dims, element: .f32), "other": FieldDescriptor(type: .vector, dims: dims, element: .f32),
            "tags": FieldDescriptor(type: .stringset),
        ]
    )

    private var fixtures: [RecordLogViewFixture] = []
    private var rows: [(id: String, vector: [Float])] = []

    override func tearDown() {
        for fixture in fixtures { fixture.remove() }
        fixtures = []
        super.tearDown()
    }

    /// 1,200 clustered 16-d notes, `embedding` indexed cos and `other` (the same vectors) l2.
    private func fixture(count: Int = 1200, index: [RecordLogIndexEntry]? = nil) async throws -> (RecordLogViewFixture, RecordLogDocumentBinding) {
        let fixture = try await RecordLogViewFixture.make("near")
        fixtures.append(fixture)
        let vectors = Support.clusteredVectors(count, Self.dims, clusters: 12)
        rows = vectors.enumerated().map { (String(format: "n%05d", $0.offset), $0.element) }
        try fixture.seed(Self.db3, "Note", try rows.enumerated().map { offset, row in
            let stored = JSONValue.string(try VectorCodec.encode(row.vector, encoding: Self.encoding))
            return ["id": .string(row.id), "title": .string("t\(offset % 7)"), "n": .number(Double(offset)), "embedding": stored, "other": stored,
                    "tags": .array([.string("g\(offset % 3)")])]
        })
        let binding = try fixture.open(Self.db3)
        try binding.store.syncIndexes(index ?? [
            Support.vectorEntry("Note", "embedding", Self.encoding), Support.vectorEntry("Note", "other", Self.encoding, distance: "l2"),
        ])
        return (fixture, binding)
    }

    private func near(_ field: String, _ vector: [Float], k: Int? = nil, filter: DocumentFilter? = nil) -> DocumentFilter {
        var near: [String: JSONValue] = ["field": .string(field), "vector": .array(vector.map { .number(Double($0)) })]
        if let k { near["k"] = .number(Double(k)) }
        if let filter { near["filter"] = .object(filter) }
        return ["$near": .object(near)]
    }

    private func page(_ binding: RecordLogDocumentBinding, _ filter: DocumentFilter, _ options: QueryOptions = QueryOptions(limit: 10_000)) throws -> PagedQueryResult<RecordLogRow> {
        try binding.store.queryView("Note", filter, options: options)
    }

    private func refusal(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) -> JsBaoError? {
        do {
            try body()
            XCTFail("expected a refusal", file: file, line: line)
            return nil
        } catch let error as JsBaoError {
            return error
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
            return nil
        }
    }

    private func reference(_ query: [Float], k: Int, distance: String = "cos", among ids: Set<String>? = nil) -> [(id: String, distance: Double)] {
        Support.bruteForce(rows.filter { ids?.contains($0.id) ?? true }, query, k: k, distance: distance)
    }

    private func assertAnswers(_ answered: [RecordLogRow], _ expected: [(id: String, distance: Double)], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(answered.compactMap { $0["id"]?.stringValue }, expected.map(\.id), label, file: file, line: line)
        for (row, want) in zip(answered, expected) {
            // vec1 measures in binary32: to 1e-6 relative to the distance.
            XCTAssertEqual(row["_distance"]?.numberValue ?? -1, want.distance, accuracy: 1e-6 * max(1, abs(want.distance)), "\(label) \(want.id)", file: file, line: line)
        }
    }

    // MARK: - 12, 35: the grammar

    func testTheGrammarsRefusalsAreJsBaosBeforeAnyStatement() async throws {
        let (fixture, binding) = try await fixture(count: 30)
        let trace = try fixture.trace(self)
        let vector: JSONValue = .array((0..<Self.dims).map { _ in 0.5 })
        let base: [String: JSONValue] = ["field": "embedding", "vector": vector]
        let with = { (key: String, value: JSONValue) -> JSONValue in var near = base; near[key] = value; return .object(near) }
        let cases: [(String, DocumentFilter, String)] = [
            ("beside another key", ["$near": .object(base), "title": "t1"], "$near is the only key of its filter: put the other conditions under $near.filter"),
            ("beside $search", ["$near": .object(base), "$search": "t1"], "$near is the only key of its filter: put the other conditions under $near.filter"),
            ("under $and", ["$and": [["$near": .object(base)]]], "$near is allowed only at the top level of a query's filter: it is the filter's only key, its other conditions under $near.filter"),
            ("under $or", ["$or": [["title": "a"], ["$near": .object(base)]]], "$near is allowed only at the top level of a query's filter: it is the filter's only key, its other conditions under $near.filter"),
            ("under $not", ["title": ["$not": ["$near": .object(base)]]], "$near is allowed only at the top level of a query's filter: it is the filter's only key, its other conditions under $near.filter"),
            ("not an object", ["$near": "embedding"], "$near is { field, vector, k?, filter? }"),
            ("an unknown key", ["$near": with("limit", 3)], "$near takes field, vector, k and filter, not \"limit\""),
            ("a field that is not an identifier", ["$near": with("field", "embedding.x")], "$near.field must name the vector field"),
            ("no field", ["$near": .object(["vector": vector])], "$near.field must name the vector field"),
            ("a vector that is not an array", ["$near": with("vector", "0.5")], "$near.vector must be the query vector: an array of numbers or a Float32Array"),
            ("k 0", ["$near": with("k", 0)], "$near.k must be an integer from 1 to 10000"),
            ("k 10,001", ["$near": with("k", 10_001)], "$near.k must be an integer from 1 to 10000"),
            ("k 2.5", ["$near": with("k", 2.5)], "$near.k must be an integer from 1 to 10000"),
            ("k \"10\"", ["$near": with("k", "10")], "$near.k must be an integer from 1 to 10000"),
            ("a filter that is not an object", ["$near": with("filter", ["title"])], "$near.filter must be a filter object"),
            ("a filter holding $near", ["$near": with("filter", ["$near": .object(base)])], "$near's filter takes neither $near nor $search"),
            ("a filter holding $search", ["$near": with("filter", ["$and": [["$search": "t1"]]])], "$near's filter takes neither $near nor $search"),
        ]
        trace.clear()
        for (name, filter, message) in cases {
            for read in ["page", "count"] {
                let error = refusal {
                    if read == "page" { _ = try page(binding, filter) } else { _ = try binding.store.countView("Note", filter) }
                }
                XCTAssertEqual(error?.code, .invalidArgument, "\(name) (\(read))")
                XCTAssertEqual(error?.message, message, "\(name) (\(read))")
            }
        }
        XCTAssertEqual(trace.viewReads, [], "no statement read a record")
        // 35: a read over several db3s is refused naming the count.
        let several = refusal {
            _ = try RecordLogViewReader(store: binding.store, documents: [Self.db3, "db3-other"]).page("Note", ["$near": .object(base)], options: nil, shape: .stored)
        }
        XCTAssertEqual(several?.code, .invalidArgument)
        XCTAssertEqual(several?.message, "$near reads one db3's vector index: give exactly one db3, not 2")
        // 35 (pin): an include leg's `$near`, at any depth, is refused as before.
        final class Target: IncludeTarget {
            let modelName: String
            init(_ modelName: String) { self.modelName = modelName }
            func query(_ filter: DocumentFilter?, options: QueryOptions?) throws -> [[String: JSONValue]] { [] }
        }
        let leg = Include(type: .hasMany, target: Target("Comment"), foreignKey: "noteId",
                          include: [Include(type: .refersTo, target: Target("Note"), sourceField: "noteId", filter: ["$near": .object(base)])])
        let included = refusal {
            _ = try RecordLogViewReader(store: binding.store, documents: [Self.db3]).page("Note", [:], options: nil, shape: .stored, include: [leg])
        }
        XCTAssertEqual(included?.code, .queryIndexNotOnDevice)
        XCTAssertEqual(included?.details?["operator"], "$near")
        XCTAssertEqual(trace.viewReads, [])
    }

    // MARK: - 13: the state refusals, in order

    func testTheStateRefusalsComeInJsBaosOrderBeforeAnyStatement() async throws {
        let (fixture, binding) = try await fixture(count: 30, index: [
            Support.vectorEntry("Note", "embedding", Self.encoding),
            RecordLogIndexEntry(name: "idx_vec_note_other", model: "Note", fields: ["other"], unique: false, kind: .vector),
        ])
        try binding.setState(type: .typed(
            name: "notes", hash: "h1",
            models: ["Note": ["title": "string", "n": "number", "embedding": "vector", "other": "vector", "plain": "vector"]],
            vectors: ["Note": ["embedding": Self.encoding, "other": Self.encoding, "plain": Self.encoding]]
        ))
        let trace = try fixture.trace(self)
        let good = Array(repeating: Float(0.25), count: Self.dims)
        let string = refusal { _ = try page(binding, near("title", good)) }
        XCTAssertEqual(string?.code, .db3VectorInvalid)
        XCTAssertEqual(string?.message, "Note.title is a string field, not a vector field: $near reads a vector field's index")
        XCTAssertEqual(string?.details, ["model": "Note", "field": "title"])
        let undeclared = refusal { _ = try page(binding, near("missing", good)) }
        XCTAssertEqual(undeclared?.code, .db3VectorInvalid)
        XCTAssertEqual(undeclared?.message, "Note.missing is not declared, not a vector field: $near reads a vector field's index")
        let short = refusal { _ = try page(binding, near("embedding", Array(good.prefix(15)))) }
        XCTAssertEqual(short?.code, .db3VectorInvalid)
        XCTAssertEqual(short?.message, "$near.vector holds 15 numbers; Note.embedding holds 16")
        XCTAssertEqual(short?.details, ["model": "Note", "field": "embedding"])
        var nan = good
        nan[3] = .nan
        XCTAssertEqual(refusal { _ = try page(binding, near("embedding", nan)) }?.message, "$near.vector[3] is not a finite number")
        var infinite = good
        infinite[0] = .infinity
        XCTAssertEqual(refusal { _ = try page(binding, near("embedding", infinite)) }?.code, .db3VectorInvalid)
        // A declared vector field with no entry cached.
        let none = refusal { _ = try page(binding, near("plain", good)) }
        XCTAssertEqual(none?.code, .queryIndexNotOnDevice)
        XCTAssertEqual(none?.details, ["operator": "$near", "model": "Note", "field": "plain"])
        // An entry the list gives no options for: unbuilt, naming the engine and why.
        let unbuilt = refusal { _ = try page(binding, near("other", good)) }
        XCTAssertEqual(unbuilt?.code, .db3IndexPlacementUnsupported)
        XCTAssertEqual(unbuilt?.details, [
            "kind": "vector", "on": "device", "engine": "swift-sqlite", "reason": .string(RecordLogVectorIndex.unbuilt),
        ])
        XCTAssertEqual(trace.viewReads, [], "no statement read a record")
        // Declined here: refused naming accept.
        _ = try binding.store.declineIndex("idx_vec_note_embedding")
        trace.clear()
        let declined = refusal { _ = try page(binding, near("embedding", good)) }
        XCTAssertEqual(declined?.code, .db3IndexDeclinedOnDevice)
        XCTAssertEqual(declined?.details, ["model": "Note", "index": "idx_vec_note_embedding", "kind": "vector"])
        XCTAssertTrue(declined?.message.contains("client.db3.indexes.accept(db3Id, name: \"idx_vec_note_embedding\")") == true, declined?.message ?? "")
        XCTAssertEqual(refusal { _ = try binding.store.countView("Note", near("embedding", good)) }?.code, .db3IndexDeclinedOnDevice)
        XCTAssertEqual(trace.viewReads, [])
    }

    // MARK: - 14, 40: exact

    func testExactNearEqualsBruteForceForEveryKAndBothDistances() async throws {
        let (_, binding) = try await fixture()
        for (field, distance) in [("embedding", "cos"), ("other", "l2")] {
            for (offset, k) in [1, 5, nil, 100, 5000, 10_000].enumerated() {
                let query = Support.clusteredVectors(1, Self.dims, clusters: 1, seed: UInt32(77 + offset))[0]
                let answered = try page(binding, near(field, query, k: k)).data
                assertAnswers(answered, reference(query, k: k ?? 10, distance: distance), "\(distance) k \(k.map(String.init) ?? "default")")
            }
        }
        // A vector of whole numbers is numbers.
        let ints: [JSONValue] = (0..<Self.dims).map { .number(Double($0 % 3)) }
        let whole = try page(binding, ["$near": ["field": "embedding", "vector": .array(ints), "k": 3]]).data
        assertAnswers(whole, reference((0..<Self.dims).map { Float($0 % 3) }, k: 3), "whole numbers")
    }

    func testDistanceRidesEveryRowAndAFilterCountAndAggregateKeepTheNearestRows() async throws {
        let (_, binding) = try await fixture()
        let query = rows[42].vector
        let k10 = reference(query, k: 10)
        for projection in [["title": 1], ["title": 0]] {
            let answered = try page(binding, near("embedding", query), QueryOptions(limit: 100, projection: projection)).data
            assertAnswers(answered, k10, "projection \(projection)")
            let keys = answered.first.map { Set($0.keys) } ?? []
            if projection["title"] == 1 {
                XCTAssertEqual(keys, ["id", "title", "_distance"])
            } else {
                XCTAssertFalse(keys.contains("title"))
                XCTAssertTrue(keys.isSuperset(of: ["id", "embedding", "_distance"]), "\(keys)")
            }
        }
        // The top-1 for a vector in the set is that row, at distance 0.
        XCTAssertEqual(try page(binding, near("embedding", query, k: 1)).data.first?["id"], "n00042")
        // A filter: the k nearest passing it (vec1 streaming).
        let passing = Set(rows.enumerated().filter { $0.offset >= 600 && $0.offset % 2 == 0 }.map(\.element.id))
        let filter: DocumentFilter = ["n": ["$gte": 600], "title": ["$in": ["t0", "t2", "t4", "t6"]]]
        let filteredIds = Set(rows.enumerated().filter { $0.offset >= 600 && [0, 2, 4, 6].contains($0.offset % 7) }.map(\.element.id))
        XCTAssertFalse(passing.isEmpty)
        assertAnswers(try page(binding, near("embedding", query, k: 25, filter: filter)).data, reference(query, k: 25, among: filteredIds), "filtered")
        // count and aggregate keep the $near's rows.
        XCTAssertEqual(try binding.store.countView("Note", near("embedding", query, k: 25, filter: filter)), 25)
        XCTAssertEqual(try binding.store.countView("Note", near("embedding", query)), 10)
        let reader = RecordLogViewReader(store: binding.store, documents: [Self.db3])
        let counted = try reader.aggregate("Note", AggregateOptions(
            groupBy: [], operations: [AggregateOperation(type: .count)], filter: near("embedding", query, k: 30)
        ), setFields: [])
        XCTAssertEqual(counted.first?.values.compactMap(\.numberValue).first, 30)
        let facet = try reader.aggregate("Note", AggregateOptions(groupBy: [.field("tags")], operations: [], filter: near("embedding", query, k: 30)), setFields: ["tags"])
        let expectedFacet = Dictionary(grouping: reference(query, k: 30).map { Int($0.id.dropFirst())! % 3 }, by: { $0 }).mapValues(\.count)
        XCTAssertEqual(facet.reduce(0) { $0 + Int($1["count"]?.numberValue ?? 0) }, 30)
        for row in facet {
            guard let member = row["group"]?["tags"]?.stringValue, let bucket = Int(member.dropFirst()) else { return XCTFail("a facet row \(row)") }
            XCTAssertEqual(Int(row["count"]?.numberValue ?? -1), expectedFacet[bucket], member)
        }
    }

    func testANearPagePagesForwardAndBackOnItsCursorsInDistanceOrder() async throws {
        let (_, binding) = try await fixture()
        let query = rows[7].vector
        let expected = reference(query, k: 10)
        let first = try page(binding, near("embedding", query), QueryOptions(limit: 4))
        let second = try page(binding, near("embedding", query), QueryOptions(limit: 4, cursor: first.nextCursor))
        let third = try page(binding, near("embedding", query), QueryOptions(limit: 4, cursor: second.nextCursor))
        XCTAssertTrue(first.hasMore)
        XCTAssertTrue(second.hasMore)
        XCTAssertFalse(third.hasMore)
        assertAnswers(first.data + second.data + third.data, expected, "forward")
        let back = try page(binding, near("embedding", query), QueryOptions(limit: 4, cursor: third.prevCursor, direction: .backward))
        assertAnswers(back.data, Array(expected[4..<8]), "backward")
        // Descending distance is a sort like any other.
        let farthest = try page(binding, near("embedding", query), QueryOptions(sort: ["_distance": -1], limit: 100)).data
        XCTAssertEqual(farthest.compactMap { $0["id"]?.stringValue }, expected.reversed().map(\.id))
    }

    func testDistanceRidesTheRecordsRowsAndDynamicModelRows() async throws {
        let (fixture, _) = try await fixture()
        let query = rows[3].vector
        let expected = reference(query, k: 10)
        let records = try fixture.records(Self.db3).query("Note", near("embedding", query))
        XCTAssertEqual(records.data.compactMap { $0.raw["id"]?.stringValue }, expected.map(\.id))
        XCTAssertEqual(records.data.first?.raw["_distance"]?.numberValue ?? -1, expected[0].distance, accuracy: 1e-6)
        let member = try fixture.member(Self.schema, Self.db3)
        let modelRows = try member.query(near("embedding", query))
        XCTAssertEqual(modelRows.compactMap { $0["id"]?.stringValue }, expected.map(\.id))
        XCTAssertEqual(modelRows.first?["_distance"]?.numberValue ?? -1, expected[0].distance, accuracy: 1e-6)
        let paged = try member.queryPaged(near("embedding", query), options: QueryOptions(limit: 3))
        XCTAssertEqual(paged.data.first?.raw["_distance"]?.numberValue ?? -1, expected[0].distance, accuracy: 1e-6)
        XCTAssertEqual(try member.count(near("embedding", query, k: 7)), 7)
    }

    func testTheSubqueriesAreTheSharedFixturesText() throws {
        let fixture = try F.family()
        for read in try XCTUnwrap(fixture["near"]?.arrayValue) {
            let target = try XCTUnwrap(fixture["targets"]?.arrayValue?.first)
            let table = try XCTUnwrap(target["table"]?.stringValue)
            let near = RecordLogNearSearch.Read(
                table: table, annTable: read["annTable"]?.stringValue, distance: try XCTUnwrap(read["distance"]?.stringValue),
                vector: Support.bytes([1, 0, 0, 0, 0, 0, 0, 0]), k: Int(try XCTUnwrap(read["k"]?.numberValue)), filter: [:]
            )
            let params = (read["filterParams"]?.arrayValue ?? []).map { Format2SqlValue.integer(Int64($0.numberValue ?? 0)) }
            let (sql, binds) = RecordLogNearSearch.subquery(near, viewTable: "record_log_view", filterSQL: read["filterSql"]?.stringValue ?? "", filterParams: params)
            XCTAssertEqual(.string(sql), read["sql"])
            let named: [JSONValue] = binds.map { bind in
                switch bind {
                case .blob: return "vector"
                case .text(let text): return .string(text)
                case .integer(let n): return .number(Double(n))
                default: return .null
                }
            }
            XCTAssertEqual(.array(named), read["params"])
        }
        for row in try XCTUnwrap(fixture["tieWindow"]?.arrayValue) {
            XCTAssertEqual(RecordLogNearSearch.tieWindow(Int(row["k"]?.numberValue ?? 0)), Int(row["window"]?.numberValue ?? -1))
        }
    }

    // MARK: - 15: ties

    func testATieAtTheKthDistanceBreaksBySmallestIdWhateverTheInsertionOrder() async throws {
        let fixture = try await RecordLogViewFixture.make("near-ties")
        fixtures.append(fixture)
        let same = JSONValue.string(try VectorCodec.encode(Array(repeating: 1, count: Self.dims), encoding: Self.encoding))
        // Written in descending id order, so rowid order is the reverse of id order.
        let ids = (0..<200).map { String(format: "tie%03d", $0) }.reversed()
        try fixture.seed(Self.db3, "Note", ids.enumerated().map { ["id": .string($0.element), "n": .number(Double($0.offset)), "embedding": same] })
        let binding = try fixture.open(Self.db3)
        try binding.store.syncIndexes([Support.vectorEntry("Note", "embedding", Self.encoding)])
        let query = Array(repeating: Float(1), count: Self.dims)
        XCTAssertEqual(try page(binding, near("embedding", query, k: 3)).data.compactMap { $0["id"]?.stringValue }, ["tie000", "tie001", "tie002"])
        XCTAssertEqual(try page(binding, near("embedding", query, k: 3, filter: ["n": ["$lt": 150]])).data.compactMap { $0["id"]?.stringValue },
                       ["tie050", "tie051", "tie052"])
    }

    // MARK: - 16: ann

    func testAnInstalledAndFilledModelAnswersFromTheAnnTableRerankedToTheExactDistance() async throws {
        let (fixture, binding) = try await fixture(index: [
            Support.vectorEntry("Note", "embedding", Self.encoding, index: F.ann(), annModel: F.annModel(revision: 1)),
        ])
        let world = try await worldOver(fixture)
        let table = F.flat(Self.db3)
        // One bucket and no quantizer: vec1 seeds its training at random, and with
        // more buckets a query's neighbours may fall in a bucket nprobe 0.1 does not
        // reach (5 trainings in 60 at 12 buckets). One bucket makes the candidates
        // the exact nearest, so the reranked answer must equal brute force.
        let model = try Support.trainModel(try F.held(world, table).sorted { $0.key < $1.key }.map { Support.floats($0.value) },
                                           distance: "cos", nbucket: 1, codesize: 0, quantizer: "none")
        // Filling: the flat table answers.
        try F.plantAnn(world, Self.db3, model: model, fill: true, encoding: Self.encoding)
        let trace = try fixture.trace(self)
        let query = rows[10].vector
        assertAnswers(try page(binding, near("embedding", query)).data, reference(query, k: 10), "while filling")
        XCTAssertFalse(trace.viewReads.contains { $0.contains("_ann\"") }, "\(trace.viewReads)")
        // Filled: the ANN table answers, `_distance` the exact distance.
        try F.plantAnn(world, Self.db3, model: model, encoding: Self.encoding)
        trace.clear()
        let answered = try page(binding, near("embedding", query)).data
        XCTAssertTrue(trace.viewReads.contains { $0.contains("\(table)_ann\"(?, ?) AS a") && $0.contains("vec1_cos_distance(a.vector, ?)") }, "\(trace.viewReads)")
        XCTAssertEqual(answered.first?["id"], "n00010")
        assertAnswers(answered, reference(query, k: 10), "filled")
        let exact = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, Support.cosDistance($0.vector, query)) })
        for row in answered {
            let id = row["id"]?.stringValue ?? ""
            XCTAssertEqual(row["_distance"]?.numberValue ?? -1, exact[id] ?? -2, accuracy: 1e-6, id)
        }
        let distances = answered.compactMap { $0["_distance"]?.numberValue }
        XCTAssertEqual(distances, distances.sorted())
        let recall = Double(Set(answered.compactMap { $0["id"]?.stringValue }).intersection(reference(query, k: 10).map(\.id)).count) / 10
        XCTAssertGreaterThanOrEqual(recall, 0.8)
        XCTAssertEqual(try binding.store.localIndexes().first?.mode, .ann)
    }

    /// F-5230-CODE-006: a list that drops the ANN table between a `$near`'s
    /// judgement of its index and its statement (the owner deleted the model)
    /// leaves a page, a count and an aggregate answering exactly from the flat
    /// table, never a missing-table error.
    func testANearRacingAnInvalidationAnswersExactlyFromTheFlatTable() async throws {
        let listed = Support.vectorEntry("Note", "embedding", Self.encoding, index: F.ann(), annModel: F.annModel(revision: 1))
        let (fixture, binding) = try await fixture(index: [listed])
        let world = try await worldOver(fixture)
        let table = F.flat(Self.db3)
        let model = try Support.trainModel(try F.held(world, table).sorted { $0.key < $1.key }.map { Support.floats($0.value) },
                                           distance: "cos", nbucket: 1, codesize: 0, quantizer: "none")
        let query = rows[10].vector
        let reader = RecordLogViewReader(store: binding.store, documents: [Self.db3])
        let reads: [(String, () throws -> Void)] = [
            ("page", { self.assertAnswers(try self.page(binding, self.near("embedding", query)).data, self.reference(query, k: 10), "page") }),
            ("count", { XCTAssertEqual(try binding.store.countView("Note", self.near("embedding", query, k: 25)), 25) }),
            ("aggregate", {
                let counted = try reader.aggregate("Note", AggregateOptions(
                    groupBy: [], operations: [AggregateOperation(type: .count)], filter: self.near("embedding", query, k: 30)
                ), setFields: [])
                XCTAssertEqual(counted.first?.values.compactMap(\.numberValue).first, 30)
            }),
        ]
        let trace = try fixture.trace(self)
        for (label, read) in reads {
            try binding.store.syncIndexes([listed])
            try F.plantAnn(world, Self.db3, model: model, encoding: Self.encoding)
            XCTAssertEqual(try binding.store.localIndexes().first?.mode, .ann, label)
            trace.clear()
            // Judged against the ANN table; the model is deleted before the statement runs.
            binding.store.vectorEntryReadForTest = {
                binding.store.vectorEntryReadForTest = nil
                try binding.store.syncIndexes([Support.vectorEntry("Note", "embedding", Self.encoding, index: F.ann(), revision: 2, annModel: nil)])
            }
            XCTAssertNoThrow(try read(), label)
            binding.store.vectorEntryReadForTest = nil
            XCTAssertFalse(try F.objects(world).contains("table:\(RecordLogVectorIndex.annTable(table))"), label)
            XCTAssertFalse(trace.viewReads.contains { $0.contains("_ann\"") }, "\(label): \(trace.viewReads)")
        }
    }

    func testATieAcrossTheKBoundaryBreaksByIdInAnnModeToo() async throws {
        let fixture = try await RecordLogViewFixture.make("near-ann-ties")
        fixtures.append(fixture)
        let spread = Support.clusteredVectors(400, Self.dims, clusters: 8)
        let same = Array(repeating: Float(1), count: Self.dims)
        var seeded: [JSONValue] = []
        for (offset, vector) in spread.enumerated() {
            seeded.append(["id": .string(String(format: "s%03d", offset)), "embedding": .string(try VectorCodec.encode(vector, encoding: Self.encoding))])
        }
        for id in (0..<20).map({ String(format: "tie%02d", $0) }).reversed() {
            seeded.append(["id": .string(id), "embedding": .string(try VectorCodec.encode(same, encoding: Self.encoding))])
        }
        try fixture.seed(Self.db3, "Note", seeded)
        let binding = try fixture.open(Self.db3)
        try binding.store.syncIndexes([Support.vectorEntry("Note", "embedding", Self.encoding, index: F.ann(), annModel: F.annModel(revision: 1))])
        let world = try await worldOver(fixture)
        let model = try Support.trainModel(try F.held(world, F.flat(Self.db3)).sorted { $0.key < $1.key }.map { Support.floats($0.value) },
                                           distance: "cos", nbucket: 8, codesize: 0, quantizer: "none")
        try F.plantAnn(world, Self.db3, model: model, encoding: Self.encoding)
        XCTAssertEqual(try page(binding, near("embedding", same, k: 3)).data.compactMap { $0["id"]?.stringValue }, ["tie00", "tie01", "tie02"])
    }

    /// A ``Db3DeviceIndexWorld``-shaped view of `fixture`'s file, for the shared vector helpers.
    private func worldOver(_ fixture: RecordLogViewFixture) async throws -> Db3DeviceIndexWorld {
        try await Db3DeviceIndexWorld.over(fixture.provider, directory: fixture.directory)
    }

    // MARK: - 42: beside text and member indexes

    func testANearFilterOnAMemberIndexedFieldReadsItsMemberTable() async throws {
        let (fixture, binding) = try await fixture(index: [
            Support.vectorEntry("Note", "embedding", Self.encoding),
            RecordLogIndexEntry(name: "idx_members_note_tags", model: "Note", fields: ["tags"], unique: false, members: true, on: .device),
        ])
        let trace = try fixture.trace(self)
        let query = rows[5].vector
        let answered = try page(binding, near("embedding", query, k: 10, filter: ["tags": ["$contains": "g1"]])).data
        let g1 = Set(rows.enumerated().filter { $0.offset % 3 == 1 }.map(\.element.id))
        assertAnswers(answered, reference(query, k: 10, among: g1), "member filter")
        let members = RecordLogIndexes.memberTableName(documentId: Self.db3, model: "Note", field: "tags")
        XCTAssertTrue(trace.viewReads.contains { $0.contains("\"\(members)\"") }, "\(trace.viewReads)")
    }
}
