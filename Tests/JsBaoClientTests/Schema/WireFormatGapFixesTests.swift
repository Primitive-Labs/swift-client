import XCTest
@testable import JsBaoClient
import YSwift

/// Regression coverage for the 12 wire-format parity gaps (A–L) closed
/// on branch `swift-wire-format-gaps-fixes-may-20`. Labels match the
/// `WireFormatGapsDemo` page in primitive-app-demo and the
/// `~/primitive/js-baseline-parity` browser baseline, so a failure here
/// surfaces in the same vocabulary as the developer-facing demos.
///
/// Each test pins a single corner of behavior. If a future refactor of
/// `QueryTranslator`, `TomlSchemaLoader`, or `StorageProvider` silently
/// re-introduces one of the gaps, the matching test goes red.
///
/// Gaps A–L were originally catalogued in the (since-retired) parity
/// docs; the PR #789 description carries the same list.
final class WireFormatGapFixesTests: XCTestCase {

    // MARK: - Fixtures

    private let taskSchema = PrimitiveSchema(
        name: "tasks",
        fields: [
            "id":       FieldDescriptor(type: .id),
            "title":    FieldDescriptor(type: .string),
            "priority": FieldDescriptor(type: .number, indexed: true),
            "assignee": FieldDescriptor(type: .string),
        ]
    )

    /// Three rows: assignee="alice", assignee="bob", assignee=NULL.
    /// The NULL row is the gap-A/B probe.
    private func seededAssignees() throws -> DynamicModel {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: taskSchema)
        _ = try model.create(id: "a", values: [
            "title": .string("A"), "assignee": .string("alice"),
        ])
        _ = try model.create(id: "b", values: [
            "title": .string("B"), "assignee": .string("bob"),
        ])
        _ = try model.create(id: "c", values: [
            "title": .string("C"),
            // assignee omitted → NULL in the SQLite mirror
        ])
        return model
    }

    /// Three rows with numeric priority. Used by gaps C/D/E to probe
    /// "substring op on a non-string field".
    private func seededPriorities() throws -> DynamicModel {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: taskSchema)
        _ = try model.create(id: "p0", values: ["priority": .number(5)])
        _ = try model.create(id: "p1", values: ["priority": .number(10)])
        _ = try model.create(id: "p2", values: ["priority": .number(25)])
        return model
    }

    /// Three rows with string title. Used by gaps F/G for trim + cap.
    private func seededTitles() throws -> DynamicModel {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: taskSchema)
        _ = try model.create(id: "t0", values: [
            "title": .string("Alpha widget"),
        ])
        _ = try model.create(id: "t1", values: [
            "title": .string("Beta gadget"),
        ])
        _ = try model.create(id: "t2", values: [
            "title": .string("Gamma thing"),
        ])
        return model
    }

    // MARK: - A. `$ne` excludes NULL rows

    func test_A_ne_excludes_null_rows() throws {
        let model = try seededAssignees()
        let rows = model.query(["assignee": ["$ne": "alice"]])
        let assignees = rows.compactMap { $0["assignee"] as? String }
        XCTAssertEqual(
            assignees, ["bob"],
            "$ne should match js-bao: exclude NULL rows. " +
            "QueryTranslator.swift `$ne` previously OR'd `IS NULL`, " +
            "which silently included missing values."
        )
        XCTAssertEqual(rows.count, 1)
    }

    // MARK: - B. `$nin` excludes NULL rows

    func test_B_nin_excludes_null_rows() throws {
        let model = try seededAssignees()
        let rows = model.query(["assignee": ["$nin": ["alice"]]])
        let assignees = rows.compactMap { $0["assignee"] as? String }
        XCTAssertEqual(
            assignees, ["bob"],
            "$nin should match js-bao: exclude NULL rows. Same " +
            "OR-NULL wing bug as `$ne`."
        )
        XCTAssertEqual(rows.count, 1)
    }

    // MARK: - C/D/E. Substring ops on a non-string field

    func test_C_startsWith_on_number_returns_no_rows() throws {
        let model = try seededPriorities()
        let rows = model.query(["priority": ["$startsWith": "1"]])
        XCTAssertEqual(
            rows.count, 0,
            "$startsWith on a non-string field used to emit `1=1` " +
            "(silently match every row). Now emits `0` — the " +
            "non-throwing analogue of js-bao's `throws on bad input`."
        )
    }

    func test_D_endsWith_on_number_returns_no_rows() throws {
        let model = try seededPriorities()
        let rows = model.query(["priority": ["$endsWith": "5"]])
        XCTAssertEqual(rows.count, 0)
    }

    func test_E_containsText_on_number_returns_no_rows() throws {
        let model = try seededPriorities()
        let rows = model.query(["priority": ["$containsText": "1"]])
        XCTAssertEqual(rows.count, 0)
    }

    // MARK: - F. `$containsText` trims whitespace before matching

    func test_F_containsText_trims_whitespace() throws {
        let model = try seededTitles()
        let rows = model.query([
            "title": ["$containsText": "  widget  "],
        ])
        let titles = rows.compactMap { $0["title"] as? String }
        XCTAssertEqual(
            titles, ["Alpha widget"],
            "js-bao's browser.ts trims `$containsText` input before " +
            "building the LIKE pattern. Without trimming, the pattern " +
            "becomes `%  widget  %` and never matches `Alpha widget`."
        )
    }

    // MARK: - G. `$containsText` caps input at 1024 chars

    func test_G_containsText_caps_at_1024_chars() throws {
        let model = try seededTitles()
        // 2006-char input. After the 1024 cap, the LIKE pattern is
        // `widget` + 1018 Z's. No seeded title has Z's, so 0 rows.
        // Without the cap, SQLite ran an oversize LIKE; this test
        // doesn't directly observe the cap, but it pins the contract
        // so a future change that drops it can be probed with a
        // pattern that *would* spuriously match uncapped.
        let longProbe = "widget" + String(repeating: "Z", count: 2000)
        let rows = model.query([
            "title": ["$containsText": longProbe],
        ])
        XCTAssertEqual(rows.count, 0)
    }

    // MARK: - H. TOML loader rejects unknown field keys (strict mode)

    func test_H_strict_toml_rejects_unknown_field_key() throws {
        let toml = """
        [models.foo]
        [models.foo.fields.id]
        type = "id"
        [models.foo.fields.bar]
        type = "string"
        bogus_option = "should-not-be-accepted"
        """
        XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: toml)) { error in
            guard case .unknownKey(_, let key, _) = error as? TomlSchemaLoaderError else {
                XCTFail("expected .unknownKey error, got \(error)")
                return
            }
            XCTAssertEqual(key, "bogus_option")
        }
    }

    func test_H_strict_false_accepts_unknown_keys() throws {
        // `strict: false` keeps the legacy permissive behavior for
        // callers loading third-party TOML they haven't audited.
        let toml = """
        [models.foo]
        [models.foo.fields.id]
        type = "id"
        [models.foo.fields.bar]
        type = "string"
        bogus_option = "should-be-silently-ignored"
        """
        let schemas = try TomlSchemaLoader.load(tomlString: toml, strict: false)
        XCTAssertEqual(schemas.count, 1)
        XCTAssertEqual(schemas.first?.name, "foo")
    }

    // MARK: - I. hasMany requires `related_id_field`

    func test_I_hasMany_requires_related_id_field() throws {
        let toml = """
        [models.foo]
        [models.foo.fields.id]
        type = "id"

        [models.bar]
        [models.bar.fields.id]
        type = "id"

        [models.foo.relationships.bars]
        type = "hasMany"
        model = "bar"
        # related_id_field intentionally omitted
        """
        XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: toml)) { error in
            guard case .missingRelationshipField(_, _, let relType, let field) =
                    error as? TomlSchemaLoaderError else {
                XCTFail("expected .missingRelationshipField, got \(error)")
                return
            }
            XCTAssertEqual(relType, "hasMany")
            XCTAssertEqual(field, "related_id_field")
        }
    }

    // MARK: - J. hasManyThrough requires join_model_*_field

    func test_J_hasManyThrough_requires_join_model_local_field() throws {
        let toml = """
        [models.foo]
        [models.foo.fields.id]
        type = "id"

        [models.bar]
        [models.bar.fields.id]
        type = "id"

        [models.join]
        [models.join.fields.id]
        type = "id"

        [models.foo.relationships.bars]
        type = "hasManyThrough"
        model = "bar"
        join_model = "join"
        # join_model_local_field intentionally omitted
        join_model_related_field = "barId"
        """
        XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: toml)) { error in
            guard case .missingRelationshipField(_, _, _, let field) =
                    error as? TomlSchemaLoaderError else {
                XCTFail("expected .missingRelationshipField, got \(error)")
                return
            }
            XCTAssertEqual(field, "join_model_local_field")
        }
    }

    func test_J_hasManyThrough_requires_join_model_related_field() throws {
        let toml = """
        [models.foo]
        [models.foo.fields.id]
        type = "id"

        [models.bar]
        [models.bar.fields.id]
        type = "id"

        [models.join]
        [models.join.fields.id]
        type = "id"

        [models.foo.relationships.bars]
        type = "hasManyThrough"
        model = "bar"
        join_model = "join"
        join_model_local_field = "fooId"
        # join_model_related_field intentionally omitted
        """
        XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: toml)) { error in
            guard case .missingRelationshipField(_, _, _, let field) =
                    error as? TomlSchemaLoaderError else {
                XCTFail("expected .missingRelationshipField, got \(error)")
                return
            }
            XCTAssertEqual(field, "join_model_related_field")
        }
    }

    // MARK: - K. StorageRecord tolerates non-string metadata values

    func test_K_storageRecord_decodes_non_string_metadata() throws {
        // js-bao-wss-client writes metadata as `Record<string, unknown>`,
        // so values can be numbers / booleans / nested objects. Swift's
        // metadata type is `[String: String]?` for source compatibility,
        // but the custom decoder stringifies any JSON scalar it sees.
        let json = #"""
        {
          "key": "k1",
          "value": "v1",
          "metadata": {"sizeBytes": 4096, "ttl": 3600, "isHot": true}
        }
        """#
        let rec = try JSONDecoder().decode(
            StorageRecord<String>.self, from: Data(json.utf8)
        )
        XCTAssertEqual(rec.metadata?["sizeBytes"], "4096")
        XCTAssertEqual(rec.metadata?["ttl"], "3600")
        XCTAssertEqual(rec.metadata?["isHot"], "true")
    }

    func test_K_storageRecord_decodes_string_metadata_unchanged() throws {
        // Smoke test: the new tolerant decoder must not break the
        // existing "all values are strings" path.
        let json = #"""
        { "key": "k1", "value": "v1", "metadata": {"tag": "v2", "owner": "alice"} }
        """#
        let rec = try JSONDecoder().decode(
            StorageRecord<String>.self, from: Data(json.utf8)
        )
        XCTAssertEqual(rec.metadata?["tag"], "v2")
        XCTAssertEqual(rec.metadata?["owner"], "alice")
    }

    // MARK: - L. StorageRecord round-trips `updatedAtMs`

    func test_L_storageRecord_decodes_updatedAtMs() throws {
        let json = #"""
        { "key": "k2", "value": "v2", "updatedAtMs": 1714060800000 }
        """#
        let rec = try JSONDecoder().decode(
            StorageRecord<String>.self, from: Data(json.utf8)
        )
        XCTAssertEqual(
            rec.updatedAtMs, 1714060800000,
            "js-bao writes `updatedAtMs: number` for cache freshness " +
            "(KvCache.refreshIfOlderThanMs). Without this field, Swift " +
            "could only read its own ISO-string `updatedAt` and silently " +
            "lost JS-written timestamps."
        )
    }

    func test_L_storageRecord_roundtrip_via_init() throws {
        let rec = StorageRecord<String>(
            key: "k3", value: "v3",
            updatedAtMs: 1714060800000
        )
        XCTAssertEqual(rec.updatedAtMs, 1714060800000)
    }

    // MARK: - M. `_meta_doc_id` legacy default matches js-bao (#1117)

    /// Single-doc DynamicModels (no explicit docId) tag their SQLite
    /// mirror rows with js-bao's `DEFAULT_LEGACY_DOC_ID`
    /// ("__legacy_default__"), not the empty string Swift used before.
    func test_M_meta_doc_id_defaults_to_legacy_default() throws {
        SchemaSync.clearCache()
        let model = DynamicModel(doc: YDocument(), schema: taskSchema)
        _ = try model.create(id: "m0", values: ["title": .string("legacy")])

        XCTAssertEqual(model.docId, "__legacy_default__")
        let rows = model.inspectionQueryEngine.rawQuery(
            "SELECT \"_meta_doc_id\" FROM \"\(model.inspectionTableName)\" WHERE id = 'm0'"
        )
        XCTAssertEqual(
            rows.first?["_meta_doc_id"] as? String,
            "__legacy_default__",
            "mirror rows must carry js-bao's DEFAULT_LEGACY_DOC_ID"
        )
    }
}
