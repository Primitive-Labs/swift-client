import XCTest
@testable import JsBaoClient
import YSwift

/// Tests for the fail-fast guard against stringset-junction-table
/// name collisions. Junction tables are named `{tableName}__{fieldName}`
/// (double underscore). If two distinct `(model, field)` pairs resolve
/// to the same composed name, silent data sharing between unrelated
/// stringsets would result — `BaoModelQueryEngine` catches that at
/// `ensureTable` time via a `preconditionFailure`.
///
/// Test strategy: we can't assert-against `preconditionFailure`
/// directly (it crashes the process), so we assert the positive path
/// — non-colliding pairs register cleanly, including re-registration
/// of the same pair and the "model name contains underscore" case
/// that would have collided under js-bao's single-underscore
/// convention.
final class JunctionCollisionTests: XCTestCase {

    /// Re-registering the exact same `(model, field)` pair is fine —
    /// idempotent. Guard only fires on DISTINCT pairs colliding.
    func testSameModelAndFieldReregisterIsIdempotent() {
        SchemaSync.clearCache()
        let doc = YDocument()
        let schema = PrimitiveSchema(
            name: "reentry_users",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "tags": FieldDescriptor(type: .stringset),
            ]
        )
        let m1 = DynamicModel(doc: doc, schema: schema)
        // Second init on the SAME doc + schema must not trip the
        // collision guard. The engine's `ensureTable` gets called
        // again with the same pair.
        let m2 = DynamicModel(doc: doc, schema: schema)
        _ = m1
        _ = m2
    }

    /// With double-underscore delimiter, the classic single-underscore
    /// collision case — `(users, posts_tags)` vs `(users_posts, tags)`
    /// — no longer collapses. Both register cleanly into distinct
    /// junction tables (`users__posts_tags` and `users_posts__tags`).
    func testModelWithUnderscoreDoesNotCollide() {
        SchemaSync.clearCache()
        let engine = BaoModelQueryEngine()

        // Model "users" with stringset field "posts_tags"
        engine.ensureTable(
            modelName: "users",
            fields: [
                (name: "id",         type: .string),
                (name: "posts_tags", type: .json),
            ],
            withDocIdColumn: true,
            stringsetFields: ["posts_tags"]
        )

        // Model "users_posts" with stringset field "tags"
        engine.ensureTable(
            modelName: "users_posts",
            fields: [
                (name: "id",   type: .string),
                (name: "tags", type: .json),
            ],
            withDocIdColumn: true,
            stringsetFields: ["tags"]
        )

        // Introspect sqlite_master to confirm two distinct junction
        // tables were created.
        let tables = engine.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%\\_\\_%' ESCAPE '\\'",
            params: []
        )
        let names = Set(tables.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("users__posts_tags"),
                      "Expected junction users__posts_tags in \(names)")
        XCTAssertTrue(names.contains("users_posts__tags"),
                      "Expected junction users_posts__tags in \(names)")
    }

    /// Two different schemas that legitimately share a junction-table
    /// name (e.g. same model name) registered against ONE shared
    /// engine — the (model, field) pair is identical, so it's the
    /// idempotent path, not a collision. Simulates the multi-doc
    /// `MultiDocModel` setup where every per-doc DynamicModel
    /// re-invokes `ensureTable` on the shared engine.
    func testSharedEngineAcceptsIdenticalRegistrations() {
        SchemaSync.clearCache()
        let schema = PrimitiveSchema(
            name: "shared_items",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "tags": FieldDescriptor(type: .stringset),
            ]
        )
        let multi = MultiDocModel(schema: schema)
        // Two docs share the engine; each DynamicModel re-calls
        // ensureTable under the hood for its init.
        _ = multi.connect(docId: "docA", doc: YDocument())
        SchemaSync.clearCache()
        _ = multi.connect(docId: "docB", doc: YDocument())
        XCTAssertEqual(multi.connectedDocIds, ["docA", "docB"])
    }
}
