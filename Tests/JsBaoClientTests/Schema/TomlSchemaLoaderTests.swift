import XCTest
@testable import JsBaoClient
import YSwift

/// Tests for `TomlSchemaLoader` — byte-compatible with js-bao's
/// `loadSchemaFromTomlString` (dist/index.js:7150-7472).
///
/// TOML conventions:
///  - Top-level `[models.<name>]` tables.
///  - `[models.X.fields.Y]` nested tables with snake_case property
///    names; `type` is one of "string" / "number" / "boolean" / "date"
///    / "id" / "stringset".
///  - `[models.X.relationships.Y]` for refersTo / hasMany /
///    hasManyThrough (also snake_case properties).
///  - `[[models.X.unique_constraints]]` array-of-tables for compound
///    uniqueness.
///
/// Validation that the loader must enforce (the "b" level agreed upon):
///  - Unknown field `type` strings rejected.
///  - Unknown relationship `type` strings rejected.
///  - Relationship `model = "Foo"` must exist in the same file.
///  - `hasManyThrough.join_model` must exist in the same file.
///  - `unique_constraints.fields[]` must all exist on the model.
final class TomlSchemaLoaderTests: XCTestCase {

    // MARK: - Happy path: field types + flags

    func testLoadsBasicModelWithAllFieldTypes() throws {
        let toml = """
        [models.Item]

        [models.Item.fields.id]
        type = "id"
        auto_assign = true
        indexed = true

        [models.Item.fields.name]
        type = "string"
        required = true
        indexed = true

        [models.Item.fields.price]
        type = "number"

        [models.Item.fields.in_stock]
        type = "boolean"
        default = true

        [models.Item.fields.due]
        type = "date"

        [models.Item.fields.tags]
        type = "stringset"
        max_count = 10
        """
        let schemas = try TomlSchemaLoader.load(tomlString: toml)
        XCTAssertEqual(schemas.count, 1)
        let item = schemas[0]
        XCTAssertEqual(item.name, "Item")

        XCTAssertEqual(item.fields["id"]?.type, .id)
        XCTAssertEqual(item.fields["id"]?.autoAssign, true)
        XCTAssertEqual(item.fields["id"]?.indexed, true)

        XCTAssertEqual(item.fields["name"]?.type, .string)
        XCTAssertEqual(item.fields["name"]?.required, true)
        XCTAssertEqual(item.fields["name"]?.indexed, true)

        XCTAssertEqual(item.fields["price"]?.type, .number)
        XCTAssertEqual(item.fields["in_stock"]?.type, .boolean)
        XCTAssertEqual(
            item.fields["in_stock"]?.default,
            .scalar(.boolean(true)),
            "Scalar defaults should decode through to DefaultValue.scalar"
        )

        XCTAssertEqual(item.fields["due"]?.type, .date)

        XCTAssertEqual(item.fields["tags"]?.type, .stringset)
        XCTAssertEqual(item.fields["tags"]?.maxCount, 10)
    }

    /// Absent boolean flags (indexed / unique / required / auto_assign)
    /// default to false. Matches js-bao (line 7152-7159 of dist).
    func testBooleanFlagsDefaultToFalse() throws {
        let toml = """
        [models.Bare]

        [models.Bare.fields.only]
        type = "string"
        """
        let schemas = try TomlSchemaLoader.load(tomlString: toml)
        let f = schemas[0].fields["only"]!
        XCTAssertFalse(f.indexed)
        XCTAssertFalse(f.unique)
        XCTAssertFalse(f.required)
        XCTAssertFalse(f.autoAssign)
        XCTAssertNil(f.maxLength)
        XCTAssertNil(f.maxCount)
        XCTAssertNil(f.default)
    }

    // MARK: - Field defaults (scalars)

    func testStringAndNumberDefaults() throws {
        let toml = """
        [models.Defaulted]

        [models.Defaulted.fields.id]
        type = "id"

        [models.Defaulted.fields.role]
        type = "string"
        default = "guest"

        [models.Defaulted.fields.retries]
        type = "number"
        default = 3
        """
        let schemas = try TomlSchemaLoader.load(tomlString: toml)
        XCTAssertEqual(
            schemas[0].fields["role"]?.default,
            .scalar(.string("guest"))
        )
        XCTAssertEqual(
            schemas[0].fields["retries"]?.default,
            .scalar(.number(3))
        )
    }

    // MARK: - Compound unique constraints

    func testCompoundUniqueConstraint() throws {
        let toml = """
        [models.User]

        [models.User.fields.email]
        type = "string"

        [models.User.fields.tenantId]
        type = "id"

        [[models.User.unique_constraints]]
        name = "email_per_tenant"
        fields = ["email", "tenantId"]
        """
        let schemas = try TomlSchemaLoader.load(tomlString: toml)
        let user = schemas[0]
        XCTAssertEqual(user.constraints.count, 1)
        let c = user.constraints["email_per_tenant"]
        XCTAssertEqual(c?.fields, ["email", "tenantId"])
        XCTAssertEqual(c?.type, "unique")
    }

    /// Single-field `unique: true` on a field SHOULD NOT produce an
    /// entry in `constraints` (those are compound-only) — but the
    /// resolved list includes a synthetic single-field constraint.
    /// Matches PrimitiveSchema.resolvedUniqueConstraints.
    func testFieldUniqueDoesNotPopulateCompoundConstraints() throws {
        let toml = """
        [models.User]

        [models.User.fields.email]
        type = "string"
        unique = true
        """
        let schemas = try TomlSchemaLoader.load(tomlString: toml)
        let user = schemas[0]
        XCTAssertTrue(user.constraints.isEmpty,
                      "Field-level unique must not appear in compound constraints")
        XCTAssertEqual(user.resolvedUniqueConstraints.count, 1,
                       "…but it must surface in the resolved list")
        XCTAssertEqual(user.resolvedUniqueConstraints.first?.fields, ["email"])
    }

    // MARK: - Relationships

    func testRefersToRelationship() throws {
        let toml = """
        [models.User]
        [models.User.fields.id]
        type = "id"

        [models.Post]
        [models.Post.fields.id]
        type = "id"
        [models.Post.fields.userId]
        type = "id"

        [models.Post.relationships.author]
        type = "refersTo"
        model = "User"
        related_id_field = "userId"
        """
        let schemas = try TomlSchemaLoader.load(tomlString: toml)
        let post = schemas.first { $0.name == "Post" }!
        let rel = post.relationships["author"]
        XCTAssertEqual(rel?.type, "refersTo")
        XCTAssertEqual(rel?.model, "User")
        XCTAssertEqual(rel?.properties["relatedIdField"], "userId",
                       "snake_case `related_id_field` must convert to camelCase")
    }

    func testHasManyRelationship() throws {
        let toml = """
        [models.User]
        [models.User.fields.id]
        type = "id"

        [models.Post]
        [models.Post.fields.id]
        type = "id"
        [models.Post.fields.userId]
        type = "id"

        [models.User.relationships.posts]
        type = "hasMany"
        model = "Post"
        related_id_field = "userId"
        order_by_field = "createdAt"
        order_direction = "DESC"
        """
        let schemas = try TomlSchemaLoader.load(tomlString: toml)
        let user = schemas.first { $0.name == "User" }!
        let rel = user.relationships["posts"]
        XCTAssertEqual(rel?.type, "hasMany")
        XCTAssertEqual(rel?.model, "Post")
        XCTAssertEqual(rel?.properties["relatedIdField"], "userId")
        XCTAssertEqual(rel?.properties["orderByField"], "createdAt")
        XCTAssertEqual(rel?.properties["orderDirection"], "DESC")
    }

    func testHasManyThroughRelationship() throws {
        let toml = """
        [models.User]
        [models.User.fields.id]
        type = "id"

        [models.Tag]
        [models.Tag.fields.id]
        type = "id"

        [models.UserTag]
        [models.UserTag.fields.id]
        type = "id"
        [models.UserTag.fields.userId]
        type = "id"
        [models.UserTag.fields.tagId]
        type = "id"

        [models.User.relationships.tags]
        type = "hasManyThrough"
        model = "Tag"
        join_model = "UserTag"
        join_model_local_field = "userId"
        join_model_related_field = "tagId"
        """
        let schemas = try TomlSchemaLoader.load(tomlString: toml)
        let user = schemas.first { $0.name == "User" }!
        let rel = user.relationships["tags"]
        XCTAssertEqual(rel?.type, "hasManyThrough")
        XCTAssertEqual(rel?.model, "Tag")
        XCTAssertEqual(rel?.properties["joinModel"], "UserTag")
        XCTAssertEqual(rel?.properties["joinModelLocalField"], "userId")
        XCTAssertEqual(rel?.properties["joinModelRelatedField"], "tagId")
    }

    // MARK: - End-to-end: TOML → DynamicModel roundtrip

    /// Load a schema from TOML, hand it to `DynamicModel`, create a
    /// record through the usual write path, and query it back.
    /// Validates that loaded schemas are indistinguishable from ones
    /// constructed in-memory.
    func testTomlSchemaDrivesDynamicModel() throws {
        let toml = """
        [models.toml_users]

        [models.toml_users.fields.id]
        type = "id"

        [models.toml_users.fields.email]
        type = "string"
        unique = true
        required = true

        [models.toml_users.fields.name]
        type = "string"
        """
        let schemas = try TomlSchemaLoader.load(tomlString: toml)
        XCTAssertEqual(schemas.count, 1)

        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schemas[0])
        _ = try model.create(id: "u1", values: [
            "email": .string("alice@x.com"),
            "name":  .string("Alice"),
        ])
        let rows = model.query(["email": "alice@x.com"])
        XCTAssertEqual(rows.first?["name"] as? String, "Alice")

        // Field-level `unique = true` should enforce via `_uniqueIdx_*`.
        XCTAssertThrowsError(try model.create(id: "u2", values: [
            "email": .string("alice@x.com"),
            "name":  .string("Dup"),
        ]))
    }

    // MARK: - auto_stamp (#1056)

    func testLoadsAutoStamp() throws {
        let toml = """
        [models.Note]
        [models.Note.fields.id]
        type = "id"
        [models.Note.fields.createdAt]
        type = "number"
        auto_stamp = "create"
        [models.Note.fields.updatedAt]
        type = "number"
        auto_stamp = "both"
        [models.Note.fields.body]
        type = "string"
        """
        let note = try TomlSchemaLoader.load(tomlString: toml)[0]
        XCTAssertEqual(note.fields["createdAt"]?.autoStamp, .create)
        XCTAssertEqual(note.fields["updatedAt"]?.autoStamp, .both)
        XCTAssertNil(note.fields["body"]?.autoStamp)
    }

    func testInvalidAutoStampIsRejected() {
        let toml = """
        [models.Note]
        [models.Note.fields.id]
        type = "id"
        [models.Note.fields.ts]
        type = "number"
        auto_stamp = "whenever"
        """
        XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: toml)) { err in
            guard case TomlSchemaLoaderError.invalidAutoStamp(
                let model, let field, let value
            ) = err else {
                return XCTFail("Expected invalidAutoStamp, got \(err)")
            }
            XCTAssertEqual(model, "Note")
            XCTAssertEqual(field, "ts")
            XCTAssertEqual(value, "whenever")
        }
    }

    // MARK: - Validation errors

    func testUnknownFieldTypeIsRejected() {
        let toml = """
        [models.Bad]
        [models.Bad.fields.thing]
        type = "mystery"
        """
        XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: toml)) { err in
            guard case TomlSchemaLoaderError.unknownFieldType(
                let model, let field, let typeName
            ) = err else {
                return XCTFail("Expected unknownFieldType, got \(err)")
            }
            XCTAssertEqual(model, "Bad")
            XCTAssertEqual(field, "thing")
            XCTAssertEqual(typeName, "mystery")
        }
    }

    func testUnknownRelationshipTypeIsRejected() {
        let toml = """
        [models.User]
        [models.User.fields.id]
        type = "id"

        [models.User.relationships.weird]
        type = "uhm"
        model = "User"
        """
        XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: toml)) { err in
            guard case TomlSchemaLoaderError.unknownRelationshipType(
                let model, let rel, let typeName
            ) = err else {
                return XCTFail("Expected unknownRelationshipType, got \(err)")
            }
            XCTAssertEqual(model, "User")
            XCTAssertEqual(rel, "weird")
            XCTAssertEqual(typeName, "uhm")
        }
    }

    /// Relationship whose `model = "Foo"` isn't defined in the file.
    /// js-bao rejects these at load time and we should too.
    func testDanglingRelationshipTargetIsRejected() {
        let toml = """
        [models.Post]
        [models.Post.fields.id]
        type = "id"
        [models.Post.fields.authorId]
        type = "id"

        [models.Post.relationships.author]
        type = "refersTo"
        model = "User"
        related_id_field = "authorId"
        """
        XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: toml)) { err in
            guard case TomlSchemaLoaderError.unknownRelatedModel(
                let model, let rel, let target
            ) = err else {
                return XCTFail("Expected unknownRelatedModel, got \(err)")
            }
            XCTAssertEqual(model, "Post")
            XCTAssertEqual(rel, "author")
            XCTAssertEqual(target, "User")
        }
    }

    /// `hasManyThrough.join_model` must also exist in the file.
    func testDanglingJoinModelIsRejected() {
        let toml = """
        [models.User]
        [models.User.fields.id]
        type = "id"

        [models.Tag]
        [models.Tag.fields.id]
        type = "id"

        [models.User.relationships.tags]
        type = "hasManyThrough"
        model = "Tag"
        join_model = "Missing"
        join_model_local_field = "userId"
        join_model_related_field = "tagId"
        """
        XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: toml)) { err in
            guard case TomlSchemaLoaderError.unknownJoinModel(
                let model, let rel, let join
            ) = err else {
                return XCTFail("Expected unknownJoinModel, got \(err)")
            }
            XCTAssertEqual(model, "User")
            XCTAssertEqual(rel, "tags")
            XCTAssertEqual(join, "Missing")
        }
    }

    /// A compound unique constraint that names a field not declared on
    /// the model. Matches js-bao's validation.
    func testUniqueConstraintReferencingUnknownFieldIsRejected() {
        let toml = """
        [models.User]
        [models.User.fields.email]
        type = "string"

        [[models.User.unique_constraints]]
        name = "bogus"
        fields = ["email", "tenantId"]
        """
        XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: toml)) { err in
            guard case TomlSchemaLoaderError.uniqueConstraintUnknownField(
                let model, let constraint, let field
            ) = err else {
                return XCTFail("Expected uniqueConstraintUnknownField, got \(err)")
            }
            XCTAssertEqual(model, "User")
            XCTAssertEqual(constraint, "bogus")
            XCTAssertEqual(field, "tenantId")
        }
    }

    // MARK: - Numeric edge cases

    /// TOML allows 64-bit signed integers; `PrimitiveValue.number` is a
    /// `Double`, so values above 2^53 lose precision — and they can't
    /// round-trip through the JSON subprocess harness either, so this
    /// case is Swift-only. We assert the loader accepts the value and
    /// stores the nearest `Double` without crashing.
    func testBigIntegerDefaultDecodesAsNearestDouble() throws {
        // 2^53 + 1 — first integer not exactly representable as Double.
        let toml = """
        [models.Big]

        [models.Big.fields.id]
        type = "id"

        [models.Big.fields.big]
        type = "number"
        default = 9007199254740993
        """
        let schemas = try TomlSchemaLoader.load(tomlString: toml)
        guard case let .scalar(.number(n)) = schemas[0].fields["big"]?.default else {
            return XCTFail("expected numeric default")
        }
        // The nearest Double to 2^53 + 1 is 2^53 (Doubles step by 2
        // past 2^53). Accept either exact or the nearest representable
        // neighbor — both are "didn't crash, stored as Double".
        XCTAssertTrue(
            n == 9007199254740993.0 || n == 9007199254740992.0,
            "Got \(n) — expected either the exact value or its nearest Double"
        )
    }

    /// Negative integers in TOML decode to a negative `Double` default.
    /// The parity fixture also asserts this via cross-platform; this is
    /// the in-process single-shot.
    func testNegativeIntegerDefault() throws {
        let toml = """
        [models.Neg]
        [models.Neg.fields.id]
        type = "id"
        [models.Neg.fields.x]
        type = "number"
        default = -42
        """
        let schemas = try TomlSchemaLoader.load(tomlString: toml)
        XCTAssertEqual(
            schemas[0].fields["x"]?.default,
            .scalar(.number(-42))
        )
    }

    func testMalformedTomlIsRejected() {
        let toml = "[models.Bad  ## unclosed\n"
        XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: toml)) { err in
            // Just make sure it's our error type, not a raw crash.
            XCTAssertTrue(err is TomlSchemaLoaderError)
        }
    }
}
