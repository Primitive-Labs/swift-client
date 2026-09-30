import XCTest
@testable import JsBaoClient
import YSwift

/// #3166 — the negative operators match a record where the field is ABSENT.
///
/// `$ne`/`$nin` compiled to `col != ?` / `col NOT IN (…)`, which SQLite
/// evaluates as UNKNOWN for a NULL column, so a record that never wrote the
/// field was silently excluded: `["deleted": ["$ne": true]]` returned nothing
/// against a model whose records never carried `deleted`. js-bao changed to
/// MongoDB semantics in the same release, and the local mirror follows.
///
/// Replica note, deliberately pinned below: the mirror stores each field in a
/// typed column, where a NULL is the only representation of "no value" —
/// `PrimitiveValue` has no null case, so a write cannot even express a stored
/// null, and absence is the whole of it. `$ne: nil` and `$exists` therefore
/// read absence and (a server-written) explicit null identically, where the
/// server's JSON path (`json_type`) tells them apart.
final class AbsentFieldFilterHermeticTests: XCTestCase {

    private let taskSchema = PrimitiveSchema(
        name: "absent_field_tasks",
        fields: [
            "id":       FieldDescriptor(type: .id),
            "title":    FieldDescriptor(type: .string),
            "assignee": FieldDescriptor(type: .string),
            "priority": FieldDescriptor(type: .number),
        ]
    )

    /// Three rows: two carrying `assignee`, one that never wrote it.
    private func seeded() throws -> DynamicModel {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: taskSchema)
        _ = try model.create(id: "a", values: [
            "title": .string("A"), "assignee": .string("alice"), "priority": .number(1),
        ])
        _ = try model.create(id: "b", values: [
            "title": .string("B"), "assignee": .string("bob"), "priority": .number(2),
        ])
        _ = try model.create(id: "absent", values: [
            "title": .string("C"), "priority": .number(3),
            // assignee omitted → NULL in the SQLite mirror
        ])
        return model
    }

    private func ids(_ rows: [[String: JSONValue]]) -> [String] {
        rows.compactMap { $0["id"]?.stringValue }.sorted()
    }

    // MARK: - Behavior 1: `$ne` matches the absent-field rows

    func test_ne_matches_rows_missing_the_field() throws {
        let model = try seeded()
        let rows = try model.query(["assignee": ["$ne": "alice"]])
        XCTAssertEqual(ids(rows), ["absent", "b"])
    }

    // MARK: - Behavior 2: `$nin` matches them too

    func test_nin_matches_rows_missing_the_field() throws {
        let model = try seeded()
        let rows = try model.query(["assignee": ["$nin": ["alice", "bob"]]])
        XCTAssertEqual(ids(rows), ["absent"])
    }

    // MARK: - Behavior 3: `$ne: nil` is the presence test

    func test_ne_null_matches_only_rows_holding_a_value() throws {
        let model = try seeded()
        let rows = try model.query(["assignee": ["$ne": JSONValue.null]])
        XCTAssertEqual(ids(rows), ["a", "b"])
    }

    // MARK: - Behavior 4: a null entry in `$nin` excludes missing/null

    func test_nin_with_null_entry_excludes_missing_rows() throws {
        let model = try seeded()
        let rows = try model.query([
            "assignee": ["$nin": [JSONValue.null, JSONValue.string("alice")]],
        ])
        XCTAssertEqual(ids(rows), ["b"])
    }

    func test_nin_of_only_null_keeps_rows_holding_a_value() throws {
        let model = try seeded()
        let rows = try model.query(["assignee": ["$nin": [JSONValue.null]]])
        XCTAssertEqual(ids(rows), ["a", "b"])
    }

    // MARK: - Unchanged semantics, and the replica's null/absent identity

    func test_equality_and_ranges_still_require_the_field() throws {
        let model = try seeded()
        XCTAssertEqual(ids(try model.query(["assignee": "alice"])), ["a"])
        XCTAssertEqual(ids(try model.query(["assignee": ["$eq": "alice"]])), ["a"])
        XCTAssertEqual(ids(try model.query(["assignee": ["$gt": "alice"]])), ["b"])
        XCTAssertEqual(
            ids(try model.query(["assignee": ["$in": ["alice", "bob"]]])),
            ["a", "b"]
        )
    }

    func test_null_equality_and_exists_treat_the_null_column_as_absent() throws {
        let model = try seeded()
        XCTAssertEqual(
            ids(try model.query(["assignee": JSONValue.null])),
            ["absent"],
            "a null equality matches the row whose column is NULL"
        )
        XCTAssertEqual(
            ids(try model.query(["assignee": ["$exists": false]])),
            ["absent"],
            "the replica's typed column cannot tell a stored null from absence"
        )
        XCTAssertEqual(ids(try model.query(["assignee": ["$exists": true]])), ["a", "b"])
    }

    func test_sibling_operators_on_one_field_and_combine() throws {
        let model = try seeded()
        let rows = try model.query([
            "assignee": ["$ne": "alice", "$exists": true],
        ])
        XCTAssertEqual(
            ids(rows), ["b"],
            "operators on one field AND-join, so the `$ne` OR-NULL wing keeps its parentheses"
        )
    }

    /// The recipe the docs and the CHANGELOG publish for restoring a
    /// pre-#3166 result set: a `nil` entry in `$nin`. It reads the same on
    /// every path — unlike `$exists: true` beside the negative operator, which
    /// still admits a stored JSON null on the server's `json_type` path.
    func test_nin_with_null_entry_restores_the_old_result_set() throws {
        let model = try seeded()
        let rows = try model.query(["assignee": ["$nin": [nil, "alice"]]])
        XCTAssertEqual(ids(rows), ["b"])
    }
}
