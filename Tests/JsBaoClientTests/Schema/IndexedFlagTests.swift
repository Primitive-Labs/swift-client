import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// Tests that the SQLite query-mirror only creates indexes on fields
/// flagged `indexed: true` (or `unique: true`, which implies indexed
/// per js-bao convention). Before this, Swift's engine eagerly
/// `CREATE INDEX`'d every non-id column — more permissive than js-bao
/// and wasteful on wide tables.
final class IndexedFlagTests: XCTestCase {

    /// Returns every SQLite index defined on `table` that wasn't
    /// created automatically for PRIMARY KEY/UNIQUE constraints.
    /// Queries `pragma index_list`.
    private func userCreatedIndexes(in engine: BaoModelQueryEngine, table: String) -> Set<String> {
        let rows = engine.rawQuery(
            "SELECT name, origin FROM pragma_index_list(?)",
            params: [table]
        )
        return Set(rows.compactMap { row -> String? in
            guard let origin = row["origin"] as? String, origin == "c" else {
                // 'c' == CREATE INDEX; 'pk'/'u' == auto-created
                return nil
            }
            return row["name"] as? String
        })
    }

    /// Only fields with `indexed: true` or `unique: true` should
    /// produce a SQLite index. Plain fields should not.
    func testOnlyIndexedOrUniqueFieldsCreateSqliteIndex() {
        let schema = PrimitiveSchema(
            name: "indexed_tasks",
            fields: [
                "id":       FieldDescriptor(type: .id),
                "title":    FieldDescriptor(type: .string),                        // no index
                "priority": FieldDescriptor(type: .number, indexed: true),         // indexed
                "email":    FieldDescriptor(type: .string, unique: true),          // unique → indexed
                "done":     FieldDescriptor(type: .boolean),                       // no index
            ]
        )
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)

        // Force lazy engine init.
        _ = model.query()

        let indexes = userCreatedIndexes(in: model.queryEngineInternal,
                                          table: "indexed_tasks")
        // Expected: indexes on "priority" and "email" only.
        XCTAssertTrue(indexes.contains("idx_indexed_tasks_priority"))
        XCTAssertTrue(indexes.contains("idx_indexed_tasks_email"))
        XCTAssertFalse(indexes.contains("idx_indexed_tasks_title"),
                       "Plain field must not be indexed")
        XCTAssertFalse(indexes.contains("idx_indexed_tasks_done"),
                       "Plain boolean must not be indexed")
    }

    /// A schema with zero indexed/unique fields produces zero
    /// user-created indexes.
    func testSchemaWithNoIndexedFieldsProducesOnlyDocIdIndex() {
        // DynamicModel always opens its table with a `_meta_doc_id`
        // column + matching index (so a shared engine can scope
        // queries by doc). When the schema declares no
        // `indexed: true` / `unique: true` fields, that's the only
        // user-created index that should exist.
        let schema = PrimitiveSchema(
            name: "no_index_rows",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "name": FieldDescriptor(type: .string),
                "age":  FieldDescriptor(type: .number),
            ]
        )
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = model.query()

        XCTAssertEqual(
            userCreatedIndexes(in: model.queryEngineInternal,
                                 table: "no_index_rows"),
            ["idx_no_index_rows__meta_doc_id"],
            "Only the implicit _meta_doc_id index should exist"
        )
    }

}
