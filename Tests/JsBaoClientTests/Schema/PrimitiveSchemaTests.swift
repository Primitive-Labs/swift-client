import XCTest
@testable import JsBaoClient

/// Tests the runtime-schema value types that mirror js-bao's
/// `DiscoveredField` / `DiscoveredConstraint` / `DiscoveredRelationship` /
/// `DiscoveredModel` shapes exactly.
final class PrimitiveSchemaTests: XCTestCase {

    // MARK: - FieldDescriptor

    func testFieldDescriptorMinimal() throws {
        let f = FieldDescriptor(type: .string)
        XCTAssertEqual(f.type, .string)
        XCTAssertFalse(f.indexed)
        XCTAssertFalse(f.unique)
        XCTAssertFalse(f.required)
        XCTAssertFalse(f.autoAssign)
        XCTAssertNil(f.maxLength)
        XCTAssertNil(f.maxCount)
        XCTAssertNil(f.default)
    }

    func testFieldDescriptorFull() throws {
        let f = FieldDescriptor(
            type: .stringset,
            indexed: true,
            unique: false,
            required: true,
            autoAssign: false,
            maxLength: 64,
            maxCount: 10,
            default: .scalar(.number(0))
        )
        XCTAssertEqual(f.type, .stringset)
        XCTAssertTrue(f.indexed)
        XCTAssertFalse(f.unique)
        XCTAssertTrue(f.required)
        XCTAssertEqual(f.maxLength, 64)
        XCTAssertEqual(f.maxCount, 10)
        XCTAssertEqual(f.default, .scalar(.number(0)))
    }

    // MARK: - DefaultValue

    /// Scalar defaults preserve the underlying PrimitiveValue verbatim.
    func testDefaultValueScalar() throws {
        XCTAssertEqual(DefaultValue.scalar(.string("x")), .scalar(.string("x")))
        XCTAssertEqual(DefaultValue.scalar(.number(0)), .scalar(.number(0)))
        XCTAssertEqual(DefaultValue.scalar(.boolean(false)), .scalar(.boolean(false)))
    }

    /// Function defaults carry a name; wire-encoding adds the `$` prefix.
    func testDefaultValueFunctionEncodesWithDollarPrefix() throws {
        let d = DefaultValue.function(name: "generate_ulid")
        XCTAssertEqual(d.encodedForMeta() as? String, "$generate_ulid")
    }

    func testDefaultValueScalarStringEncodesRaw() throws {
        XCTAssertEqual(DefaultValue.scalar(.string("hi")).encodedForMeta() as? String, "hi")
    }

    func testDefaultValueScalarNumberEncodesRaw() throws {
        XCTAssertEqual(DefaultValue.scalar(.number(42)).encodedForMeta() as? Double, 42)
    }

    func testDefaultValueScalarBoolEncodesRaw() throws {
        XCTAssertEqual(DefaultValue.scalar(.boolean(true)).encodedForMeta() as? Bool, true)
    }

    /// Decoding a `$name` sentinel back into a DefaultValue preserves the
    /// function name; a literal string stays a scalar; ditto number/bool.
    func testDefaultValueDecodeFunction() throws {
        XCTAssertEqual(
            DefaultValue.decode(fromMeta: "$generate_ulid"),
            .function(name: "generate_ulid")
        )
    }

    func testDefaultValueDecodeScalarString() throws {
        XCTAssertEqual(
            DefaultValue.decode(fromMeta: "hi"),
            .scalar(.string("hi"))
        )
    }

    func testDefaultValueDecodeScalarNumber() throws {
        XCTAssertEqual(
            DefaultValue.decode(fromMeta: 42.5),
            .scalar(.number(42.5))
        )
    }

    func testDefaultValueDecodeScalarBool() throws {
        XCTAssertEqual(
            DefaultValue.decode(fromMeta: false),
            .scalar(.boolean(false))
        )
    }

    // MARK: - ConstraintDescriptor

    func testConstraintDescriptorBasics() throws {
        let c = ConstraintDescriptor(
            name: "uq_tenant_sku",
            type: "unique",
            fields: ["tenantId", "sku"]
        )
        XCTAssertEqual(c.name, "uq_tenant_sku")
        XCTAssertEqual(c.type, "unique")
        XCTAssertEqual(c.fields, ["tenantId", "sku"])
    }

    /// The wire format stores the field list as a JSON-encoded STRING, not
    /// as a Y.Array — easiest place to get the encoding wrong.
    func testConstraintDescriptorFieldsEncodedAsJsonString() throws {
        let c = ConstraintDescriptor(
            name: "uq_tenant_sku",
            type: "unique",
            fields: ["tenantId", "sku"]
        )
        XCTAssertEqual(c.fieldsJson, "[\"tenantId\",\"sku\"]")
    }

    /// Decoding a JSON-encoded fields string recovers the original list;
    /// malformed JSON yields an empty list (matches js-bao's fallback).
    func testConstraintDescriptorDecodesJsonFields() throws {
        XCTAssertEqual(
            ConstraintDescriptor.decodeFields("[\"a\",\"b\"]"),
            ["a", "b"]
        )
        XCTAssertEqual(ConstraintDescriptor.decodeFields("not-json"), [])
    }

    // MARK: - RelationshipDescriptor

    /// refersTo: the typed constructor fills the standard key set.
    func testRelationshipRefersToHasCorrectKeys() throws {
        let r = RelationshipDescriptor.refersTo(
            model: "users",
            relatedIdField: "userId"
        )
        XCTAssertEqual(r.properties["type"], "refersTo")
        XCTAssertEqual(r.properties["model"], "users")
        XCTAssertEqual(r.properties["relatedIdField"], "userId")
    }

    /// hasMany with required + optional fields.
    func testRelationshipHasManyWithOrder() throws {
        let r = RelationshipDescriptor.hasMany(
            model: "posts",
            relatedIdField: "userId",
            orderByField: "createdAt",
            orderDirection: "DESC"
        )
        XCTAssertEqual(r.properties["type"], "hasMany")
        XCTAssertEqual(r.properties["model"], "posts")
        XCTAssertEqual(r.properties["relatedIdField"], "userId")
        XCTAssertEqual(r.properties["orderByField"], "createdAt")
        XCTAssertEqual(r.properties["orderDirection"], "DESC")
    }

    /// hasMany without optional fields omits them entirely rather than
    /// storing empty strings (matches js-bao's Object.entries skip-if-undefined).
    func testRelationshipHasManyOmitsNilOptionals() throws {
        let r = RelationshipDescriptor.hasMany(
            model: "posts",
            relatedIdField: "userId"
        )
        XCTAssertEqual(r.properties["type"], "hasMany")
        XCTAssertNil(r.properties["orderByField"])
        XCTAssertNil(r.properties["orderDirection"])
    }

    /// hasManyThrough carries the join-model triplet.
    func testRelationshipHasManyThrough() throws {
        let r = RelationshipDescriptor.hasManyThrough(
            model: "tags",
            joinModel: "post_tag_links",
            joinModelLocalField: "postId",
            joinModelRelatedField: "tagId"
        )
        XCTAssertEqual(r.properties["type"], "hasManyThrough")
        XCTAssertEqual(r.properties["model"], "tags")
        XCTAssertEqual(r.properties["joinModel"], "post_tag_links")
        XCTAssertEqual(r.properties["joinModelLocalField"], "postId")
        XCTAssertEqual(r.properties["joinModelRelatedField"], "tagId")
    }

    /// Unknown keys on a relationship are preserved (round-trip survival).
    func testRelationshipPreservesUnknownKeys() throws {
        var r = RelationshipDescriptor.refersTo(model: "users", relatedIdField: "uid")
        r.properties["experimentalFlag"] = "yes"
        XCTAssertEqual(r.properties["experimentalFlag"], "yes")
    }

    // MARK: - PrimitiveSchema aggregate

    /// A schema models one record type: name + fields + optional
    /// constraints + optional relationships.
    func testPrimitiveSchemaBasics() throws {
        let schema = PrimitiveSchema(
            name: "users",
            fields: [
                "id": FieldDescriptor(type: .id, indexed: true, autoAssign: true,
                                      default: .function(name: "generate_ulid")),
                "email": FieldDescriptor(type: .string, unique: true),
            ]
        )
        XCTAssertEqual(schema.name, "users")
        XCTAssertEqual(schema.fields.count, 2)
        XCTAssertEqual(schema.fields["id"]?.type, .id)
        XCTAssertTrue(schema.fields["id"]?.indexed == true)
        XCTAssertEqual(schema.fields["email"]?.type, .string)
        XCTAssertTrue(schema.fields["email"]?.unique == true)
        XCTAssertTrue(schema.constraints.isEmpty)
        XCTAssertTrue(schema.relationships.isEmpty)
    }

    /// Compound constraints live at the schema level, not on fields.
    func testPrimitiveSchemaWithCompoundConstraint() throws {
        let schema = PrimitiveSchema(
            name: "unique_products",
            fields: [
                "tenantId": FieldDescriptor(type: .string, indexed: true),
                "sku":      FieldDescriptor(type: .string, indexed: true),
            ],
            constraints: [
                "uq_tenant_sku": ConstraintDescriptor(
                    name: "uq_tenant_sku",
                    type: "unique",
                    fields: ["tenantId", "sku"]
                )
            ]
        )
        XCTAssertEqual(schema.constraints.count, 1)
        XCTAssertEqual(schema.constraints["uq_tenant_sku"]?.fields, ["tenantId", "sku"])
    }

    func testPrimitiveSchemaWithRelationships() throws {
        let schema = PrimitiveSchema(
            name: "users",
            fields: ["id": FieldDescriptor(type: .id)],
            relationships: [
                "posts": .hasMany(model: "posts", relatedIdField: "userId")
            ]
        )
        XCTAssertEqual(schema.relationships["posts"]?.type, "hasMany")
        XCTAssertEqual(schema.relationships["posts"]?.model, "posts")
    }
}
