import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests for `MultiDocModel` — cross-doc query layer on a shared
/// SQLite store. Mirrors js-bao's `BaseModel.dbInstance` design: one
/// shared table, every per-doc `DynamicModel` tags its rows with
/// `_meta_doc_id = docId`, cross-doc queries run as a single SQL
/// query against the merged table.
///
/// Writes still go through the per-doc `DynamicModel` (returned by
/// `connect(docId:doc:)`). Uniqueness remains per-doc — js-bao's
/// `_uniqueIdx_*` maps live inside each YDoc, so two docs may hold
/// records that agree on a `unique: true` field.
final class MultiDocModelTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "md_users",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "email": FieldDescriptor(type: .string, unique: true),
            "name":  FieldDescriptor(type: .string),
            "rank":  FieldDescriptor(type: .number),
        ]
    )

    /// Two docs connected to the aggregator, seeded via the per-doc
    /// DynamicModels returned by `connect`.
    private func seededPair() throws -> MultiDocModel {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: schema)

        let modelA = multi.connect(docId: "docA", doc: YDocument())
        _ = try modelA.create(id: "a1", values: [
            "email": .string("alice@a.com"), "name": .string("Alice-A"),
            "rank": .number(1),
        ])
        _ = try modelA.create(id: "a2", values: [
            "email": .string("bob@a.com"), "name": .string("Bob-A"),
            "rank": .number(3),
        ])

        SchemaSync.clearCache()
        let modelB = multi.connect(docId: "docB", doc: YDocument())
        _ = try modelB.create(id: "b1", values: [
            "email": .string("carol@b.com"), "name": .string("Carol-B"),
            "rank": .number(2),
        ])
        return multi
    }

    // MARK: - findAll

    func testFindAllMergesAcrossDocs() throws {
        let multi = try seededPair()
        let rows = multi.findAll()
        XCTAssertEqual(rows.count, 3)
        let ids = Set(rows.compactMap { $0["id"]?.stringValue })
        XCTAssertEqual(ids, ["a1", "a2", "b1"])
    }

    /// Every row carries `_meta_doc_id` so callers can route follow-up
    /// ops (e.g. update / delete) to the correct underlying doc.
    func testFindAllAttachesDocIdToEveryRow() throws {
        let multi = try seededPair()
        let rows = multi.findAll()
        for row in rows {
            XCTAssertNotNil(row["_meta_doc_id"]?.stringValue,
                            "Every row must carry _meta_doc_id")
        }
        let byDoc = Dictionary(grouping: rows) {
            $0["_meta_doc_id"]?.stringValue ?? ""
        }
        XCTAssertEqual(byDoc["docA"]?.count, 2)
        XCTAssertEqual(byDoc["docB"]?.count, 1)
    }

    // MARK: - find

    func testFindByIdLocatesTheRightDoc() throws {
        let multi = try seededPair()
        let result = multi.find(id: "b1")
        XCTAssertEqual(result?.docId, "docB")
        XCTAssertEqual(result?.row["name"]?.stringValue, "Carol-B")
    }

    func testFindReturnsNilWhenNoDocHasIt() throws {
        let multi = try seededPair()
        XCTAssertNil(multi.find(id: "not_a_real_id"))
    }

    // MARK: - findByUnique

    func testFindByUniqueAcrossDocs() throws {
        let multi = try seededPair()
        let carol = try multi.findByUnique(
            constraint: "md_users_email_unique",
            value: .string("carol@b.com")
        )
        XCTAssertEqual(carol?.docId, "docB")
        XCTAssertEqual(carol?.row["name"]?.stringValue, "Carol-B")
    }

    func testFindByUniqueSearchesEveryDoc() throws {
        let multi = try seededPair()
        let alice = try multi.findByUnique(
            constraint: "md_users_email_unique",
            value: .string("alice@a.com")
        )
        XCTAssertEqual(alice?.docId, "docA")
    }

    func testFindByUniqueMissReturnsNil() throws {
        let multi = try seededPair()
        let gone = try multi.findByUnique(
            constraint: "md_users_email_unique",
            value: .string("nobody@x.com")
        )
        XCTAssertNil(gone)
    }

    // MARK: - query

    func testQueryFiltersFanOutAndMerge() throws {
        let multi = try seededPair()
        let rows = try multi.query(["rank": ["$gte": 2]])
        let ids = Set(rows.compactMap { $0["id"]?.stringValue })
        XCTAssertEqual(ids, ["a2", "b1"])
    }

    /// Sort is applied by SQL ORDER BY across the shared table — one
    /// query, not a per-doc fetch+merge.
    func testQuerySortAppliesAcrossMergedResult() throws {
        let multi = try seededPair()
        let rows = try multi.query(nil, options: QueryOptions(
            sortOrder: [("rank", 1)]
        ))
        XCTAssertEqual(rows.map { $0["id"]?.stringValue },
                       ["a1", "b1", "a2"],
                       "Merged sort by rank ASC across docs")
    }

    /// Limit is applied by SQL LIMIT on the merged result.
    func testQueryLimitAppliesAfterMerge() throws {
        let multi = try seededPair()
        let rows = try multi.query(nil, options: QueryOptions(
            sortOrder: [("rank", 1)], limit: 2
        ))
        XCTAssertEqual(rows.map { $0["id"]?.stringValue }, ["a1", "b1"])
    }

    /// `_meta_doc_id` is a real SQLite column on the shared table —
    /// callers can filter by it to scope a query to one doc.
    func testQueryCanFilterByMetaDocId() throws {
        let multi = try seededPair()
        let rows = try multi.query(["_meta_doc_id": "docA"])
        let ids = Set(rows.compactMap { $0["id"]?.stringValue })
        XCTAssertEqual(ids, ["a1", "a2"])
    }

    // MARK: - count

    func testCountSumsAcrossDocs() throws {
        let multi = try seededPair()
        XCTAssertEqual(try multi.count(), 3)
    }

    func testCountWithFilterSumsAcrossDocs() throws {
        let multi = try seededPair()
        XCTAssertEqual(try multi.count(["rank": ["$gte": 2]]), 2)
    }

    // MARK: - aggregate (new: cross-doc via shared store)

    /// Global rollup: one SUM across every connected doc. Before the
    /// shared-store refactor this would have required Swift-side
    /// merging of per-doc aggregates.
    func testAggregateSumsAcrossDocs() throws {
        let multi = try seededPair()
        let result = try multi.aggregate(AggregateOptions(
            operations: [
                AggregateOperation(type: .sum, field: "rank")
            ]
        ))
        XCTAssertEqual(result.count, 1)
        // rank: 1 + 3 + 2 = 6
        let sum = (result.first?["sum_rank"]?.numberValue) ??
                  Double(result.first?["sum_rank"]?.numberValue ?? 0)
        XCTAssertEqual(sum, 6)
    }

    /// Group by `_meta_doc_id` to get per-doc rollups from a single
    /// SQL query — this is the thing fan-out couldn't do cleanly.
    func testAggregateGroupByDocId() throws {
        let multi = try seededPair()
        let rows = try multi.aggregate(AggregateOptions(
            groupBy: ["_meta_doc_id"],
            operations: [
                AggregateOperation(type: .count, outputField: "n"),
                AggregateOperation(type: .avg, field: "rank"),
            ]
        ))
        let byDoc = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, [String: JSONValue])? in
            guard let docId = row["_meta_doc_id"]?.stringValue else { return nil }
            return (docId, row)
        })
        XCTAssertEqual(byDoc["docA"]?["n"]?.numberValue, 2)
        XCTAssertEqual(byDoc["docB"]?["n"]?.numberValue, 1)
        // docA avg rank: (1+3)/2 = 2
        XCTAssertEqual(byDoc["docA"]?["avg_rank"]?.numberValue, 2.0)
        XCTAssertEqual(byDoc["docB"]?["avg_rank"]?.numberValue, 2.0)
    }

    func testAggregateWithFilter() throws {
        let multi = try seededPair()
        let rows = try multi.aggregate(AggregateOptions(
            operations: [AggregateOperation(type: .count, outputField: "n")],
            filter: ["rank": ["$gte": 2]]
        ))
        XCTAssertEqual(rows.first?["n"]?.numberValue, 2)
    }

    // MARK: - connect / disconnect at runtime

    func testConnectAddsANewDoc() throws {
        let multi = try seededPair()
        XCTAssertEqual(try multi.count(), 3)

        SchemaSync.clearCache()
        let modelC = multi.connect(docId: "docC", doc: YDocument())
        _ = try modelC.create(id: "c1", values: [
            "email": .string("dan@c.com"), "name": .string("Dan-C"),
            "rank": .number(10),
        ])

        XCTAssertEqual(try multi.count(), 4)
        XCTAssertEqual(multi.find(id: "c1")?.docId, "docC")
    }

    /// On disconnect the doc's rows are dropped from the shared
    /// SQLite table so subsequent cross-doc reads don't return stale
    /// state. The underlying YDocument itself isn't modified — the
    /// data is still there if the doc is re-connected.
    func testDisconnectRemovesRowsFromSharedStore() throws {
        let multi = try seededPair()
        XCTAssertEqual(try multi.count(), 3)
        multi.disconnect(docId: "docB")
        XCTAssertEqual(try multi.count(), 2)
        XCTAssertNil(multi.find(id: "b1"))
        XCTAssertNil(multi.member(docId: "docB"))
    }

    /// `member(docId:)` hands back the per-doc model — the write
    /// target for callers routing via a `find` result's `docId`.
    func testMemberReturnsThePerDocModel() throws {
        let multi = try seededPair()
        let m = multi.member(docId: "docA")
        XCTAssertNotNil(m)
        XCTAssertEqual(m?.docId, "docA")
        // Writes via the returned model reach the shared table.
        _ = try m?.create(id: "a3", values: [
            "email": .string("ed@a.com"), "name": .string("Ed-A"),
            "rank": .number(9),
        ])
        XCTAssertEqual(try multi.count(), 4)
    }

    // MARK: - Empty doc tolerance

    func testEmptyDocContributesNoRows() throws {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: schema)
        let modelA = multi.connect(docId: "docA", doc: YDocument())
        _ = try modelA.create(id: "a1", values: [
            "email": .string("a@x.com"), "name": .string("A"),
            "rank": .number(1),
        ])

        SchemaSync.clearCache()
        _ = multi.connect(docId: "docEmpty", doc: YDocument())

        XCTAssertEqual(try multi.count(), 1)
        XCTAssertEqual(multi.findAll().count, 1)
    }

    // MARK: - Cross-doc uniqueness is PER-doc (not global)

    /// Per-doc uniqueness constraints are enforced within each
    /// DynamicModel. Cross-doc collisions on a "unique" field are
    /// explicitly allowed — matches js-bao's behavior where
    /// `_uniqueIdx_*` is per-doc.
    func testSameUniqueValueInTwoDocsIsLegal() throws {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: schema)
        let modelA = multi.connect(docId: "docA", doc: YDocument())
        _ = try modelA.create(id: "a1", values: [
            "email": .string("shared@x.com"), "name": .string("A"),
            "rank": .number(1),
        ])

        SchemaSync.clearCache()
        let modelB = multi.connect(docId: "docB", doc: YDocument())
        // Same email in a different doc: legal.
        XCTAssertNoThrow(try modelB.create(id: "b1", values: [
            "email": .string("shared@x.com"), "name": .string("B"),
            "rank": .number(2),
        ]))

        // findByUnique returns the first match found — typically the
        // first-connected doc. We assert only that SOME match returns.
        XCTAssertNotNil(try multi.findByUnique(
            constraint: "md_users_email_unique",
            value: .string("shared@x.com")
        ))
    }

    // MARK: - upsertByUnique: cross-doc search (#1122)

    /// js-bao's `upsertByUnique` searches EVERY connected doc for an
    /// existing match before inserting. Here the match lives in docB but
    /// the target doc is docA — the upsert must still find the match, then
    /// save the resolved record id through the supplied target document
    /// (`existingRecord.save({ targetDocument })` parity).
    func testUpsertByUniqueSearchesAcrossDocsAndWritesToTargetDoc() throws {
        let multi = try seededPair()  // carol@b.com lives in docB
        let result = try multi.upsertByUnique(
            constraint: "md_users_email_unique",
            data: ["email": .string("carol@b.com"), "name": .string("Carol V2")],
            targetDocId: "docA"  // target differs from the match's doc
        )
        XCTAssertFalse(result.wasCreated, "cross-doc match must resolve an existing record id")
        XCTAssertEqual(result.record.id, "b1", "must resolve to docB's existing id")
        XCTAssertEqual(result.record["name"], .string("Carol V2"))
        XCTAssertEqual(multi.find(id: "b1")?.docId, "docA",
                       "targetDocument parity writes the resolved id into docA")
        XCTAssertEqual(multi.find(id: "b1")?.row["name"]?.stringValue, "Carol V2")
    }

    /// No match in any connected doc → insert into the target doc.
    func testUpsertByUniqueInsertsIntoTargetWhenNoMatchAnywhere() throws {
        let multi = try seededPair()
        let result = try multi.upsertByUnique(
            constraint: "md_users_email_unique",
            data: ["email": .string("dave@new.com"), "name": .string("Dave")],
            id: "d1",
            targetDocId: "docA"
        )
        XCTAssertTrue(result.wasCreated)
        XCTAssertEqual(result.record.id, "d1")
        let inserted = multi.findAll().first { ($0["id"]?.stringValue) == "d1" }
        XCTAssertEqual(inserted?["_meta_doc_id"]?.stringValue, "docA",
                       "fresh insert lands in the target doc")
    }

    /// `.mustExist` with a match in ANOTHER doc still updates (proves the
    /// existence check spans docs, not just the target).
    func testUpsertByUniqueMustExistFindsMatchInOtherDoc() throws {
        let multi = try seededPair()  // carol@b.com in docB
        let result = try multi.upsertByUnique(
            constraint: "md_users_email_unique",
            data: ["email": .string("carol@b.com"), "rank": .number(99)],
            mode: .mustExist,
            targetDocId: "docA"
        )
        XCTAssertFalse(result.wasCreated)
        XCTAssertEqual(result.record.id, "b1")
        XCTAssertEqual(result.record["rank"], .number(99))
    }

    /// An explicit (caller-pinned) id colliding with a cross-doc match is
    /// a hard conflict (#1122 — js-bao `_constructorProvidedId` parity).
    func testUpsertByUniqueExplicitIdConflictAcrossDocs() throws {
        let multi = try seededPair()
        XCTAssertThrowsError(try multi.upsertByUnique(
            constraint: "md_users_email_unique",
            data: ["email": .string("carol@b.com"), "name": .string("X")],
            id: "different",
            explicitId: true,
            targetDocId: "docA"
        )) { error in
            XCTAssertEqual(error as? UpsertError,
                           .explicitIdConflict(supplied: "different", existing: "b1"))
        }
        XCTAssertEqual(multi.findAll().count, 3, "conflict must not insert")
    }
}
