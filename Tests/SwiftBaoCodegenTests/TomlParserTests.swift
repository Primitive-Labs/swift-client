import XCTest
@testable import SwiftBaoCodegen

final class TomlParserTests: XCTestCase {

    func testParsesBasicSchema() throws {
        let toml = """
        [models.tasks]
        [models.tasks.fields.id]
        type = "id"
        [models.tasks.fields.title]
        type = "string"
        required = true
        """

        let schemas = try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")
        XCTAssertEqual(schemas.count, 1)
        let s = schemas[0]
        XCTAssertEqual(s.name, "tasks")
        XCTAssertEqual(s.swiftName, "TasksRecord")
        XCTAssertEqual(s.fields["id"]?.type, .id)
        XCTAssertEqual(s.fields["title"]?.type, .string)
        XCTAssertEqual(s.fields["title"]?.required, true)
    }

    func testClassNameOverride() throws {
        let toml = """
        [models.tasks]
        class_name = "TaskRecord"

        [models.tasks.fields.id]
        type = "id"
        """

        let schemas = try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")
        XCTAssertEqual(schemas[0].swiftName, "TaskRecord")
    }

    func testClassNameRejectsInvalidIdentifier() throws {
        let toml = """
        [models.tasks]
        class_name = "My Record"

        [models.tasks.fields.id]
        type = "id"
        """

        XCTAssertThrowsError(
            try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")
        ) { error in
            guard case CodegenError.invalidClassName(_, let reason) = error else {
                XCTFail("expected invalidClassName, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("not a valid Swift identifier"),
                          "reason should mention identifier validity, got: \(reason)")
        }
    }

    func testClassNameRejectsReservedKeyword() throws {
        // `let` matches the identifier regex but is a Swift reserved
        // keyword — the emitter doesn't backtick-escape struct names,
        // so a generated `struct let: PrimitiveModel { ... }` would
        // produce a confusing compile error pointing at the generated
        // file instead of the TOML. Codegen catches it up front.
        for keyword in ["let", "class", "struct", "init", "var", "for", "switch", "true", "Self"] {
            let toml = """
            [models.tasks]
            class_name = "\(keyword)"

            [models.tasks.fields.id]
            type = "id"
            """

            XCTAssertThrowsError(
                try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record"),
                "expected error for class_name = '\(keyword)' (reserved Swift keyword)"
            ) { error in
                guard case CodegenError.invalidClassName(_, let reason) = error else {
                    XCTFail("expected invalidClassName for '\(keyword)', got \(error)")
                    return
                }
                XCTAssertTrue(
                    reason.contains("reserved Swift keyword"),
                    "reason should mention reserved keyword for '\(keyword)', got: \(reason)"
                )
            }
        }
    }

    func testFieldFlagsAreParsed() throws {
        let toml = """
        [models.users]
        [models.users.fields.id]
        type = "id"
        [models.users.fields.email]
        type = "string"
        unique = true
        indexed = true
        max_length = 256
        """

        let schemas = try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")
        let email = try XCTUnwrap(schemas[0].fields["email"])
        XCTAssertTrue(email.unique)
        XCTAssertTrue(email.indexed)
        XCTAssertEqual(email.maxLength, 256)
    }

    func testStringDefault() throws {
        let toml = """
        [models.users]
        [models.users.fields.id]
        type = "id"
        [models.users.fields.role]
        type = "string"
        default = "guest"
        """

        let schemas = try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")
        let role = try XCTUnwrap(schemas[0].fields["role"])
        guard case let .string(s) = role.defaultLiteral else {
            return XCTFail("expected string default, got \(String(describing: role.defaultLiteral))")
        }
        XCTAssertEqual(s, "guest")
    }

    func testCompoundUniqueConstraint() throws {
        let toml = """
        [models.users]
        [models.users.fields.id]
        type = "id"
        [models.users.fields.email]
        type = "string"
        [models.users.fields.tenantId]
        type = "string"

        [[models.users.unique_constraints]]
        name = "email_per_tenant"
        fields = ["email", "tenantId"]
        """

        let schemas = try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")
        let cs = schemas[0].uniqueConstraints
        XCTAssertEqual(cs.count, 1)
        XCTAssertEqual(cs[0].name, "email_per_tenant")
        XCTAssertEqual(cs[0].fields, ["email", "tenantId"])
    }

    func testRefersToRelationship() throws {
        let toml = """
        [models.users]
        [models.users.fields.id]
        type = "id"

        [models.posts]
        [models.posts.fields.id]
        type = "id"
        [models.posts.fields.authorId]
        type = "id"

        [models.posts.relationships.author]
        type = "refersTo"
        model = "users"
        related_id_field = "authorId"
        """

        let schemas = try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")
        let posts = try XCTUnwrap(schemas.first(where: { $0.name == "posts" }))
        XCTAssertEqual(posts.relationships.count, 1)
        let (relName, rel) = posts.relationships[0]
        XCTAssertEqual(relName, "author")
        XCTAssertEqual(rel.rawType, "refersTo")
        let props = Dictionary(uniqueKeysWithValues: rel.properties)
        XCTAssertEqual(props["model"], "users")
        XCTAssertEqual(props["relatedIdField"], "authorId")
    }

    // MARK: - Validation errors mirror TomlSchemaLoader

    func testRejectsUnknownFieldType() {
        let toml = """
        [models.x]
        [models.x.fields.f]
        type = "blob"
        """
        XCTAssertThrowsError(try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")) { err in
            guard case let CodegenError.unknownFieldType(model, field, typeName) = err else {
                return XCTFail("wrong error: \(err)")
            }
            XCTAssertEqual(model, "x")
            XCTAssertEqual(field, "f")
            XCTAssertEqual(typeName, "blob")
        }
    }

    func testRejectsRelationshipToUnknownModel() {
        let toml = """
        [models.posts]
        [models.posts.fields.id]
        type = "id"

        [models.posts.relationships.author]
        type = "refersTo"
        model = "users"
        related_id_field = "authorId"
        """
        XCTAssertThrowsError(try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")) { err in
            guard case CodegenError.unknownRelatedModel = err else {
                return XCTFail("wrong error: \(err)")
            }
        }
    }

    func testRejectsUniqueConstraintFieldNotInModel() {
        let toml = """
        [models.users]
        [models.users.fields.id]
        type = "id"

        [[models.users.unique_constraints]]
        name = "x"
        fields = ["nope"]
        """
        XCTAssertThrowsError(try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")) { err in
            guard case CodegenError.uniqueConstraintUnknownField = err else {
                return XCTFail("wrong error: \(err)")
            }
        }
    }

    /// A fresh-template schema.toml ships with no `[models]` block yet
    /// — the user adds their first model as part of onboarding. The SPM
    /// plugin already handles this by emitting zero build commands; the
    /// standalone tool needs to match so a wrapper script (run.sh /
    /// run-ios.sh) can call codegen unconditionally on every invocation.
    func testEmptySchemaReturnsNoSchemas() throws {
        let schemas = try TomlParser.parse(tomlString: "", swiftNameSuffix: "Record")
        XCTAssertTrue(schemas.isEmpty)
    }

    func testCommentOnlySchemaReturnsNoSchemas() throws {
        let toml = """
        # placeholder — no models defined yet
        """
        let schemas = try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")
        XCTAssertTrue(schemas.isEmpty)
    }
}
