import XCTest
@testable import JsBaoClient
import YSwift

/// Tests for querying stringset fields.
///
/// Stringsets are stored in Yjs as a nested Y.Map keyed by member; in
/// the SQLite mirror they flatten to a comma-joined string in a TEXT
/// column (see `DynamicModel.sqliteRepresentation`). Naive equality on
/// that column (`tags = "red"`) only matches single-element sets — a
/// silent-wrong-result trap we want to close.
///
/// The fix: a `$contains` operator that generates boundary-safe SQL by
/// padding both the column and the search value with commas, so
/// `$contains "red"` matches regardless of position in the set but
/// won't falsely match substring-adjacent members.
///
/// Known limitation documented in the impl: a member containing a
/// literal comma would break the delimiter trick. Typical stringset
/// members are IDs/tags (no commas); we don't guard against this at
/// the layer today — follow-up work would migrate to per-field
/// junction tables (matches js-bao).
final class StringSetQueryTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "ss_posts",
        fields: [
            "id":     FieldDescriptor(type: .id),
            "title":  FieldDescriptor(type: .string),
            "tags":   FieldDescriptor(type: .stringset),
        ]
    )

    private func seeded() throws -> DynamicModel {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)

        _ = try model.create(id: "p1", values: [
            "title": .string("red alone"),
            "tags":  .stringset(["red"]),
        ])
        _ = try model.create(id: "p2", values: [
            "title": .string("red + blue"),
            "tags":  .stringset(["red", "blue"]),
        ])
        _ = try model.create(id: "p3", values: [
            "title": .string("blue alone"),
            "tags":  .stringset(["blue"]),
        ])
        _ = try model.create(id: "p4", values: [
            "title": .string("preload"),
            "tags":  .stringset(["predicament", "ed"]),
        ])
        _ = try model.create(id: "p5", values: [
            "title": .string("empty"),
            "tags":  .stringset([]),
        ])
        // p6 has no tags field at all.
        _ = try model.create(id: "p6", values: [
            "title": .string("no tags field"),
        ])
        return model
    }

    // MARK: - $contains membership

    /// The load-bearing case: $contains finds records whose stringset
    /// includes the named member, regardless of position in the set.
    func testContainsFindsAllRecordsHoldingTheMember() throws {
        let model = try seeded()
        let rows = model.query(["tags": ["$contains": "red"]])
        let ids = Set(rows.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["p1", "p2"])
    }

    func testContainsWithDifferentMember() throws {
        let model = try seeded()
        let rows = model.query(["tags": ["$contains": "blue"]])
        let ids = Set(rows.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids, ["p2", "p3"])
    }

    // MARK: - Boundary safety

    /// Prove the delimiter padding: p4's stringset is
    /// `{"predicament", "ed"}`. Searching for "red" must NOT match it
    /// even though the underlying CSV contains `red` as a substring
    /// of `predicament`. Also: searching for "ed" must match p4
    /// (it's a real member) but NOT p1 (where `ed` appears inside
    /// `red`).
    func testContainsIsBoundarySafe() throws {
        let model = try seeded()

        let forRed = Set(model.query(["tags": ["$contains": "red"]])
            .compactMap { $0["id"] as? String })
        XCTAssertFalse(forRed.contains("p4"),
                       "Must not match 'red' as substring of 'predicament'")

        let forEd = Set(model.query(["tags": ["$contains": "ed"]])
            .compactMap { $0["id"] as? String })
        XCTAssertEqual(
            forEd, ["p4"],
            "Only p4 has 'ed' as a discrete member; p1 has 'red' which contains 'ed' but that's not a membership match"
        )
    }

    /// Junction-table storage is exact-equality on the `value` column,
    /// so searching for an adjacent-pair string can't accidentally
    /// match. Unlike the old padded-CSV approach, a stringset member
    /// containing a literal comma is stored as its own junction row
    /// and would match $contains correctly — see
    /// `testContainsWorksWithCommaInMember`.
    func testContainsDoesNotMatchConcatenatedMembers() throws {
        let model = try seeded()
        let rows = model.query(["tags": ["$contains": "red,blue"]])
        XCTAssertTrue(rows.isEmpty,
                      "No member named 'red,blue' exists — must not match")
    }

    /// Regression for the original motivation of switching to
    /// junction tables: a stringset member CAN contain a comma, and
    /// $contains locates it correctly. The old CSV-based storage
    /// would have ambiguously matched adjacent members.
    func testContainsWorksWithCommaInMember() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "p_weird", values: [
            "title": .string("weird tags"),
            "tags":  .stringset(["hello, world", "apple,pie"]),
        ])

        let helloRows = model.query(["tags": ["$contains": "hello, world"]])
        XCTAssertEqual(
            helloRows.compactMap { $0["id"] as? String }, ["p_weird"],
            "Member with a comma + space round-trips cleanly"
        )
        let appleRows = model.query(["tags": ["$contains": "apple,pie"]])
        XCTAssertEqual(
            appleRows.compactMap { $0["id"] as? String }, ["p_weird"],
            "Member with a bare comma round-trips cleanly"
        )
    }

    /// Query result rows carry stringset values as `[String]`, not as
    /// the old comma-joined text. Ensures callers (and the
    /// `IncludeResolver` refersToMany path) consume the expected shape.
    func testQueryRowsReturnStringsetAsArray() throws {
        let model = try seeded()
        let rows = model.query(["id": "p2"])
        let tags = rows.first?["tags"] as? [String]
        XCTAssertNotNil(tags, "Row must carry stringset as [String]")
        XCTAssertEqual(Set(tags ?? []), ["red", "blue"])
    }

    // MARK: - Empty / missing

    func testContainsOnEmptyStringsetDoesNotMatch() throws {
        let model = try seeded()
        let rows = model.query(["tags": ["$contains": "anything"]])
        let ids = rows.compactMap { $0["id"] as? String }
        XCTAssertFalse(ids.contains("p5"),
                       "An empty stringset should never match $contains")
    }

    func testContainsWhenFieldMissingDoesNotMatch() throws {
        let model = try seeded()
        let rows = model.query(["tags": ["$contains": "red"]])
        let ids = rows.compactMap { $0["id"] as? String }
        XCTAssertFalse(ids.contains("p6"),
                       "A record that never set the stringset field should not match")
    }

    // MARK: - Multi-doc

    /// Cross-doc $contains via MultiDocModel uses the same shared
    /// SQLite table, so the operator works transparently across docs
    /// without any per-doc fan-out.
    func testContainsWorksAcrossDocsViaMultiDocModel() throws {
        SchemaSync.clearCache()
        let multi = MultiDocModel(schema: schema)

        let a = multi.connect(docId: "docA", doc: YDocument())
        _ = try a.create(id: "a1", values: [
            "title": .string("A"), "tags": .stringset(["alpha", "shared"]),
        ])

        SchemaSync.clearCache()
        let b = multi.connect(docId: "docB", doc: YDocument())
        _ = try b.create(id: "b1", values: [
            "title": .string("B"), "tags": .stringset(["beta", "shared"]),
        ])

        let rows = multi.query(["tags": ["$contains": "shared"]])
        XCTAssertEqual(
            Set(rows.compactMap { $0["id"] as? String }),
            ["a1", "b1"]
        )
    }
}
