import XCTest
@testable import JsBaoClient
import YSwift

/// A local `aggregate` answers the rows js-bao's model statics answer for the
/// same records and options: `["group": [<level key>: <value as stored>], <op
/// key>: <value>]`.
///
/// - A membership level's key is `has_<field>_<member>`, written raw.
/// - Two `groupBy` levels that would share a key are refused before any SQL.
/// - A group field named like an operation's key keeps both values.
final class AggregateGroupKeysHermeticTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "agg_group_keys",
        fields: [
            "id":     FieldDescriptor(type: .id),
            "name":   FieldDescriptor(type: .string),
            "tags":   FieldDescriptor(type: .stringset),
            "amount": FieldDescriptor(type: .number),
            "has_tags_ab": FieldDescriptor(type: .string),
        ]
    )

    private let count = AggregateOperation(type: .count)

    private func model(_ schema: PrimitiveSchema? = nil) -> DynamicModel {
        SchemaSync.clearCache()
        return DynamicModel(doc: YDocument(), schema: schema ?? self.schema)
    }

    /// The issue's two records: `x` carries `a-b`, `y` carries nothing.
    private func seeded() throws -> DynamicModel {
        let model = model()
        _ = try model.create(id: "r1", values: [
            "name": .string("x"), "tags": .stringset(["a-b"]), "amount": .number(1),
        ])
        _ = try model.create(id: "r2", values: [
            "name": .string("y"), "tags": .stringset([]), "amount": .number(2),
        ])
        return model
    }

    private func ambiguity(_ key: String) -> String {
        "Ambiguous aggregation group keys: '\(key)' names more than one groupBy level"
    }

    private func assertRefused(
        _ groupBy: [AggregateGroupBy], key: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let model = try seeded()
        XCTAssertThrowsError(
            try model.aggregate(AggregateOptions(groupBy: groupBy, operations: [count])),
            file: file, line: line
        ) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument, file: file, line: line)
            XCTAssertEqual((error as? JsBaoError)?.message, self.ambiguity(key), file: file, line: line)
        }
    }

    // MARK: - Row shape

    func testGroupedRowsNestGroupValuesUnderGroup() throws {
        let rows = try seeded().aggregate(AggregateOptions(
            groupBy: ["name"],
            operations: [count, AggregateOperation(type: .sum, field: "amount")],
            sort: AggregateSort(field: "name")
        ))
        XCTAssertEqual(rows, [
            ["group": ["name": "x"], "count": 1, "sum_amount": 1],
            ["group": ["name": "y"], "count": 1, "sum_amount": 2],
        ])
    }

    func testUngroupedAggregateIsOneRowWithAnEmptyGroup() throws {
        let rows = try seeded().aggregate(AggregateOptions(operations: [count]))
        XCTAssertEqual(rows, [["group": [:], "count": 2]])
    }

    func testGroupedAggregateOverNoRecordsIsEmpty() throws {
        let rows = try model().aggregate(AggregateOptions(groupBy: ["name"], operations: [count]))
        XCTAssertEqual(rows, [])
    }

    /// A record without the field groups under `null`, and an operation with
    /// nothing to fold still takes its key — as js-bao answers.
    func testAMissingValueIsNullUnderItsKey() throws {
        let model = model()
        _ = try model.create(id: "r1", values: [:])
        let rows = try model.aggregate(AggregateOptions(
            groupBy: ["name"],
            operations: [AggregateOperation(type: .sum, field: "amount")]
        ))
        XCTAssertEqual(rows, [["group": ["name": nil], "sum_amount": nil]])
    }

    func testCrossDocumentRowsTakeTheSameShape() throws {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: schema)
        let a = multi.connect(docId: "docA", doc: YDocument())
        _ = try a.create(id: "a1", values: ["name": .string("x")])
        SchemaSync.clearCache()
        let b = multi.connect(docId: "docB", doc: YDocument())
        _ = try b.create(id: "b1", values: ["name": .string("x")])

        let rows = try multi.aggregate(AggregateOptions(groupBy: ["name"], operations: [count]))
        XCTAssertEqual(rows, [["group": ["name": "x"], "count": 2]])
    }

    // MARK: - Membership keys

    func testAMembershipKeyIsWrittenRaw() throws {
        let rows = try seeded().aggregate(AggregateOptions(
            groupBy: [.stringSetMembership(field: "tags", contains: "a-b")],
            operations: [count],
            sort: AggregateSort(field: "has_tags_a-b")
        ))
        XCTAssertEqual(rows, [
            ["group": ["has_tags_a-b": "false"], "count": 1],
            ["group": ["has_tags_a-b": "true"], "count": 1],
        ])
    }

    func testSortingByAMembershipKeyDescending() throws {
        let rows = try seeded().aggregate(AggregateOptions(
            groupBy: [.stringSetMembership(field: "tags", contains: "a-b")],
            operations: [count],
            sort: AggregateSort(field: "has_tags_a-b", direction: -1)
        ))
        XCTAssertEqual(rows.map { $0["group"]?["has_tags_a-b"] }, ["true", "false"])
    }

    // MARK: - Ambiguous group keys

    func testARepeatedFieldIsRefused() throws {
        try assertRefused(["name", "name"], key: "name")
    }

    func testTwoIdenticalMembershipsAreRefused() throws {
        try assertRefused(
            [.stringSetMembership(field: "tags", contains: "a-b"),
             .stringSetMembership(field: "tags", contains: "a-b")],
            key: "has_tags_a-b"
        )
    }

    func testAFieldNamedLikeAMembershipKeyIsRefused() throws {
        try assertRefused(
            ["has_tags_ab", .stringSetMembership(field: "tags", contains: "ab")],
            key: "has_tags_ab"
        )
    }

    /// The refusal comes from building the statement, so nothing is read.
    func testTheRefusalPrecedesTheStatement() {
        XCTAssertThrowsError(try QueryTranslator.buildAggregation(
            tableName: "agg_group_keys",
            options: AggregateOptions(groupBy: ["tags", "tags"], operations: [count]),
            stringsetFields: ["tags"]
        )) { error in
            XCTAssertEqual((error as? JsBaoError)?.message, self.ambiguity("tags"))
        }
    }

    // MARK: - Group fields named like operation keys

    func testAGroupFieldNamedCountKeepsBothValues() throws {
        let countSchema = PrimitiveSchema(
            name: "agg_count_field",
            fields: ["id": FieldDescriptor(type: .id), "count": FieldDescriptor(type: .string)]
        )
        let model = model(countSchema)
        _ = try model.create(id: "c1", values: ["count": .string("7")])
        _ = try model.create(id: "c2", values: ["count": .string("7")])

        let rows = try model.aggregate(AggregateOptions(groupBy: ["count"], operations: [count]))
        XCTAssertEqual(rows, [["group": ["count": "7"], "count": 2]])
    }

    func testAGroupFieldNamedLikeASumKeyKeepsBothValues() throws {
        let sumSchema = PrimitiveSchema(
            name: "agg_sum_field",
            fields: [
                "id": FieldDescriptor(type: .id),
                "sum_amount": FieldDescriptor(type: .string),
                "amount": FieldDescriptor(type: .number),
            ]
        )
        let model = model(sumSchema)
        _ = try model.create(id: "s1", values: ["sum_amount": .string("s"), "amount": .number(1)])
        _ = try model.create(id: "s2", values: ["sum_amount": .string("s"), "amount": .number(2)])

        let rows = try model.aggregate(AggregateOptions(
            groupBy: ["sum_amount"],
            operations: [AggregateOperation(type: .sum, field: "amount")]
        ))
        XCTAssertEqual(rows, [["group": ["sum_amount": "s"], "sum_amount": 3]])
    }

    /// `sort` names the operation when a group field shares its key, as in
    /// js-bao.
    func testSortingByASharedKeyOrdersByTheOperation() throws {
        let countSchema = PrimitiveSchema(
            name: "agg_count_sort",
            fields: ["id": FieldDescriptor(type: .id), "count": FieldDescriptor(type: .string)]
        )
        let model = model(countSchema)
        _ = try model.create(id: "c1", values: ["count": .string("a")])
        _ = try model.create(id: "c2", values: ["count": .string("a")])
        _ = try model.create(id: "c3", values: ["count": .string("b")])

        let rows = try model.aggregate(AggregateOptions(
            groupBy: ["count"], operations: [count],
            sort: AggregateSort(field: "count", direction: -1)
        ))
        XCTAssertEqual(rows, [
            ["group": ["count": "a"], "count": 2],
            ["group": ["count": "b"], "count": 1],
        ])
    }

    /// Operations are selected under their own aliases, so a custom
    /// `outputField` named like a group alias takes no group column's place.
    func testAnOutputFieldNamedLikeAGroupAliasKeepsBothValues() throws {
        let model = model()
        _ = try model.create(id: "r1", values: ["name": .string("x")])
        _ = try model.create(id: "r2", values: ["name": .string("x")])

        let rows = try model.aggregate(AggregateOptions(
            groupBy: ["name"],
            operations: [AggregateOperation(type: .count, outputField: "_g0")],
            sort: AggregateSort(field: "_g0")
        ))
        XCTAssertEqual(rows, [["group": ["name": "x"], "_g0": 2]])
    }

    /// `group` holds the group values, so no operation may take that key.
    func testAnOperationNamedGroupIsRefused() throws {
        let model = try seeded()
        XCTAssertThrowsError(try model.aggregate(AggregateOptions(
            operations: [AggregateOperation(type: .count, outputField: "group")]
        ))) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
            XCTAssertEqual(
                (error as? JsBaoError)?.message,
                "Aggregation operation result key 'group' is reserved for the row's group values"
            )
        }
    }

    /// A membership's join alias never names the model's own table.
    func testAMembershipOnAModelNamedLikeAJoinAlias() throws {
        let aliasSchema = PrimitiveSchema(
            name: "_m0",
            fields: ["id": FieldDescriptor(type: .id), "tags": FieldDescriptor(type: .stringset)]
        )
        let model = model(aliasSchema)
        _ = try model.create(id: "m1", values: ["tags": .stringset(["a"])])
        _ = try model.create(id: "m2", values: ["tags": .stringset([])])

        let rows = try model.aggregate(AggregateOptions(
            groupBy: [.stringSetMembership(field: "tags", contains: "a")],
            operations: [count],
            sort: AggregateSort(field: "has_tags_a")
        ))
        XCTAssertEqual(rows, [
            ["group": ["has_tags_a": "false"], "count": 1],
            ["group": ["has_tags_a": "true"], "count": 1],
        ])
    }

    // MARK: - StringSet facets

    func testAFacetRowCarriesTheMemberUnderTheFieldName() throws {
        let rows = try seeded().aggregate(AggregateOptions(
            groupBy: ["tags"], operations: [count]
        ))
        XCTAssertEqual(rows, [["group": ["tags": "a-b"], "count": 1]])
    }

    func testSortingAFacetByItsField() throws {
        let model = model()
        _ = try model.create(id: "r1", values: ["tags": .stringset(["a", "b"])])
        let rows = try model.aggregate(AggregateOptions(
            groupBy: ["tags"], operations: [count],
            sort: AggregateSort(field: "tags", direction: -1)
        ))
        XCTAssertEqual(rows.map { $0["group"]?["tags"] }, ["b", "a"])
    }

    /// A facet beside another level is not selected; its key holds `null`.
    func testAFacetBesideAnotherLevelIsNull() throws {
        let rows = try seeded().aggregate(AggregateOptions(
            groupBy: ["tags", "name"], operations: [count],
            sort: AggregateSort(field: "name")
        ))
        XCTAssertEqual(rows, [
            ["group": ["tags": nil, "name": "x"], "count": 1],
            ["group": ["tags": nil, "name": "y"], "count": 1],
        ])
    }
}
