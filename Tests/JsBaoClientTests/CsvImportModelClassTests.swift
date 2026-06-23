import XCTest
@testable import JsBaoClient

/// Tests the `importCsv` model-class path (#1145), mirroring js-bao's
/// `databases.importCsv` `model:` BaseModel handling: resolve the model name
/// from the class, filter CSV columns to the schema's fields, coerce
/// number/boolean fields from the schema, and sync the model's indexes after
/// import (reported as `CsvImportResult.indexesCreated`).
///
/// These exercise the full `importCsv` pipeline through an in-process request
/// closure (the same `(method, path, body)` closure shape `DatabasesAPI`
/// holds), so they run without a dev server. The closure records the `/batch`
/// and `/indexes/sync` payloads and returns the canned engine responses, which
/// is enough to assert the column filtering, type coercion, and index-sync
/// behavior end-to-end.
final class CsvImportModelClassTests: XCTestCase {

    // A codegen-shaped model: `id`, an indexed string, a unique string, a
    // number, and a boolean. Mirrors what `swift-bao-codegen` emits.
    struct Product: PrimitiveModel, Equatable {
        static let modelName = "products"
        static let primitiveSchema = PrimitiveSchema(
            name: "products",
            fields: [
                "id":    FieldDescriptor(type: .id),
                "name":  FieldDescriptor(type: .string, indexed: true),
                "sku":   FieldDescriptor(type: .string, unique: true),
                "price": FieldDescriptor(type: .number),
                "active": FieldDescriptor(type: .boolean),
            ]
        )
        var id: String
        init(id: String) { self.id = id }
        init?(record: PrimitiveRecord) { self.id = record.id }
        func primitiveValues() -> [String: PrimitiveValue] { [:] }
    }

    // MARK: - Pure schema → sync-state extraction (offline)

    func testModelSyncStateSkipsIdAndKeepsIndexedAndUnique() throws {
        let state = DatabasesAPI.modelSyncState(from: Product.primitiveSchema)
        XCTAssertEqual(state.modelName, "products")

        // `id` excluded; `price`/`active` not indexed → excluded; only the
        // indexed `name` and the unique `sku` survive. (Sorted by field name.)
        XCTAssertEqual(state.indexes.map(\.fieldName), ["name", "sku"])

        let name = try XCTUnwrap(state.indexes.first { $0.fieldName == "name" })
        XCTAssertEqual(name.fieldType, "string")
        XCTAssertFalse(name.unique)

        let sku = try XCTUnwrap(state.indexes.first { $0.fieldName == "sku" })
        XCTAssertTrue(sku.unique, "single-field unique must carry unique: true")

        // No compound constraints declared.
        XCTAssertTrue(state.uniqueConstraints.isEmpty)
    }

    func testModelSyncStateEmitsCompoundConstraints() throws {
        let schema = PrimitiveSchema(
            name: "memberships",
            fields: [
                "id":      FieldDescriptor(type: .id),
                "userId":  FieldDescriptor(type: .string, indexed: true),
                "groupId": FieldDescriptor(type: .string),
            ],
            constraints: [
                "user_group_unique": ConstraintDescriptor(
                    name: "user_group_unique",
                    fields: ["userId", "groupId"]
                )
            ]
        )
        let state = DatabasesAPI.modelSyncState(from: schema)
        XCTAssertEqual(state.uniqueConstraints.count, 1)
        XCTAssertEqual(state.uniqueConstraints.first?.name, "user_group_unique")
        XCTAssertEqual(state.uniqueConstraints.first?.fields, ["userId", "groupId"])
    }

    func testCoercionMapFromSchema() throws {
        let map = DatabasesAPI.coercionMap(from: Product.primitiveSchema)
        XCTAssertEqual(map["price"], .number)
        XCTAssertEqual(map["active"], .boolean)
        // String / id fields are not coerced.
        XCTAssertNil(map["name"])
        XCTAssertNil(map["id"])
    }

    func testCoercionMapNilSchemaIsEmpty() throws {
        XCTAssertTrue(DatabasesAPI.coercionMap(from: nil).isEmpty)
    }

    // MARK: - Full pipeline through an in-process request closure (offline)

    /// Records every batch operation and the sync-indexes payload.
    private actor Recorder {
        var batchedRows: [[String: JSONValue]] = []
        var syncCount = 0
        func addRows(_ rows: [[String: JSONValue]]) { batchedRows.append(contentsOf: rows) }
        func bumpSync() { syncCount += 1 }
    }

    private func makeApi(
        recorder: Recorder,
        registeredIndexes: Int
    ) -> DatabasesAPI {
        DatabasesAPI(makeRequest: { _, path, body in
            if path.contains("/batch") {
                // body: { operationName, batch: [{ params: { modelName, id, data } }] }
                let dict = body as? [String: Any] ?? [:]
                let batch = dict["batch"] as? [[String: Any]] ?? []
                var rows: [[String: JSONValue]] = []
                for op in batch {
                    let params = op["params"] as? [String: Any] ?? [:]
                    if let data = params["data"] {
                        let row = try JSONCoding.decode([String: JSONValue].self, from: data)
                        rows.append(row)
                    }
                }
                await recorder.addRows(rows)
                return ["imported": rows.count, "failed": 0, "results": [Any]()]
            }
            if path.contains("/indexes/sync") {
                await recorder.bumpSync()
                return ["registered": registeredIndexes]
            }
            return [String: Any]()
        })
    }

    func testModelClassFiltersColumnsCoercesAndSyncsIndexes() async throws {
        let recorder = Recorder()
        let api = makeApi(recorder: recorder, registeredIndexes: 2)

        // CSV has an extra `notAField` column that must be filtered out by the
        // schema, and string price/active that must be coerced.
        let csv = """
        id,name,sku,price,active,notAField
        p1,Widget,SKU-1,9.99,true,junk
        p2,Gadget,SKU-2,19.5,false,more-junk
        """

        let result = try await api.importCsv(
            databaseId: "db-1",
            options: CsvImportOptions(csv: csv, model: Product.self)
        )

        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.failed, 0)
        // syncIndexes defaults to true for the model path → registered count.
        XCTAssertEqual(result.indexesCreated, 2)

        let rows = await recorder.batchedRows
        XCTAssertEqual(rows.count, 2)
        let first = try XCTUnwrap(rows.first { $0["id"] == .string("p1") })

        // Column filtering: `notAField` dropped (not in schema).
        XCTAssertNil(first["notAField"], "non-schema column must be filtered out")
        // Schema type coercion: price → number, active → boolean.
        XCTAssertEqual(first["price"], .number(9.99))
        XCTAssertEqual(first["active"], .bool(true))
        // Unchanged string field.
        XCTAssertEqual(first["name"], .string("Widget"))
    }

    func testModelClassResolvesModelNameInBatch() async throws {
        let recorder = Recorder()
        var capturedModelName: String?
        let api = DatabasesAPI(makeRequest: { _, path, body in
            if path.contains("/batch") {
                let dict = body as? [String: Any] ?? [:]
                let batch = dict["batch"] as? [[String: Any]] ?? []
                if let params = (batch.first?["params"]) as? [String: Any] {
                    capturedModelName = params["modelName"] as? String
                }
                let rows = batch.compactMap { ($0["params"] as? [String: Any])?["data"] }
                return ["imported": rows.count, "failed": 0, "results": [Any]()]
            }
            if path.contains("/indexes/sync") { return ["registered": 0] }
            return [String: Any]()
        })
        _ = recorder

        _ = try await api.importCsv(
            databaseId: "db-1",
            options: CsvImportOptions(
                data: [["id": "p1", "name": "Widget"]],
                model: Product.self
            )
        )
        XCTAssertEqual(capturedModelName, "products",
                       "model class must resolve its modelName for the batch")
    }

    func testSyncIndexesFalseSkipsIndexSync() async throws {
        let recorder = Recorder()
        let api = makeApi(recorder: recorder, registeredIndexes: 5)

        let result = try await api.importCsv(
            databaseId: "db-1",
            options: CsvImportOptions(
                data: [["id": "p1", "name": "Widget"]],
                model: Product.self,
                syncIndexes: false
            )
        )
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.indexesCreated, 0, "syncIndexes:false must skip the sync")
        let syncs = await recorder.syncCount
        XCTAssertEqual(syncs, 0, "no /indexes/sync request should be made")
    }

    func testModelNameOnlyPathDoesNotFilterOrSync() async throws {
        let recorder = Recorder()
        let api = makeApi(recorder: recorder, registeredIndexes: 9)

        // No model class → no schema → no column filtering, no index sync.
        let result = try await api.importCsv(
            databaseId: "db-1",
            options: CsvImportOptions(
                data: [["id": "p1", "name": "Widget", "notAField": "kept"]],
                modelName: "products"
            )
        )
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.indexesCreated, 0)

        let rows = await recorder.batchedRows
        let first = try XCTUnwrap(rows.first)
        // Without a schema, the unknown column survives (string-typed).
        XCTAssertEqual(first["notAField"], .string("kept"))
        let syncs = await recorder.syncCount
        XCTAssertEqual(syncs, 0)
    }

    func testEmptyIdColumnCellMatchesJSParity() async throws {
        let recorder = Recorder()
        let api = makeApi(recorder: recorder, registeredIndexes: 0)

        _ = try await api.importCsv(
            databaseId: "db-1",
            options: CsvImportOptions(
                data: [["id": "", "name": "Widget", "sku": "SKU-1"]],
                model: Product.self,
                idColumn: "id"
            )
        )

        let rows = await recorder.batchedRows
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(
            row["id"], .string(""),
            "JS treats an empty idColumn cell as present and assigns id = \"\""
        )
    }

    func testNeitherModelNorModelNameThrows() async throws {
        let api = makeApi(recorder: Recorder(), registeredIndexes: 0)
        do {
            _ = try await api.importCsv(
                databaseId: "db-1",
                options: CsvImportOptions(data: [["id": "p1"]])
            )
            XCTFail("expected modelNameRequired")
        } catch let error as DatabaseImportError {
            XCTAssertEqual(error, .modelNameRequired)
        }
    }
}
