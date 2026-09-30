import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// A unique constraint on a stringset field is refused where it is declared
/// (#3719) — the Swift client, with the same sentences js-bao answers.
///
/// No writer can build such a key consistently (the server stringified the
/// stored nested map, the clients key the member array), so the combination
/// is refused on every declaration surface:
///
/// - `TomlSchemaLoader.load` throws `.uniqueOnStringset`;
/// - a `PrimitiveSchema` built with the public initializer cannot throw (the
///   read path, `SchemaDiscovery`, builds schemas with it too), so it
///   registers, and the refusal comes on its first write — before any
///   `_meta_<model>` is recorded;
/// - `resolvedUniqueConstraints` never resolves such a constraint.
///
/// Hermetic: in-process `YDocument`s and an offline client, no server.
final class UniqueStringsetHermeticTests: XCTestCase {

    static let fieldMessage =
        "Model \"post\": field \"tags\" is a stringset and cannot be unique. "
        + "A unique constraint applies to scalar fields only."

    static let compoundMessage =
        "Model \"post\": unique constraint \"title_tags\" names the stringset field "
        + "\"tags\", which cannot be unique. A unique constraint applies to scalar "
        + "fields only."

    static let fieldToml = """
    [models.post.fields.title]
    type = "string"

    [models.post.fields.tags]
    type = "stringset"
    unique = true
    """

    static let compoundToml = """
    [models.post.fields.title]
    type = "string"

    [models.post.fields.tags]
    type = "stringset"

    [[models.post.unique_constraints]]
    name = "title_tags"
    fields = ["title", "tags"]
    """

    static let fieldSchema = PrimitiveSchema(
        name: "post",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "tags": FieldDescriptor(type: .stringset, unique: true),
        ]
    )

    static let compoundSchema = PrimitiveSchema(
        name: "post",
        fields: [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "tags": FieldDescriptor(type: .stringset),
        ],
        constraints: [
            "title_tags": ConstraintDescriptor(name: "title_tags", fields: ["title", "tags"]),
        ]
    )

    // MARK: - Behavior 22: the TOML loader

    func testLoaderRefusesTheFieldFormWithTheJsSentence() {
        XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: Self.fieldToml)) { error in
            guard case let TomlSchemaLoaderError.uniqueOnStringset(message) = error else {
                return XCTFail("expected .uniqueOnStringset, got \(error)")
            }
            XCTAssertEqual(message, Self.fieldMessage)
            XCTAssertEqual(String(describing: error), Self.fieldMessage)
        }
    }

    func testLoaderRefusesTheCompoundFormWithTheJsSentence() {
        XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: Self.compoundToml)) { error in
            guard case TomlSchemaLoaderError.uniqueOnStringset = error else {
                return XCTFail("expected .uniqueOnStringset, got \(error)")
            }
            XCTAssertEqual(String(describing: error), Self.compoundMessage)
        }
    }

    func testLoaderStillLoadsAScalarUnique() throws {
        let schemas = try TomlSchemaLoader.load(tomlString: """
        [models.post.fields.title]
        type = "string"
        unique = true

        [models.post.fields.tags]
        type = "stringset"
        """)
        XCTAssertEqual(schemas.first?.fields["title"]?.unique, true)
    }

    /// Edge: `unique = false` on a stringset is no violation, and
    /// `max_count` on one is unaffected.
    func testLoaderAcceptsAStringsetWithUniqueFalseAndMaxCount() throws {
        let schemas = try TomlSchemaLoader.load(tomlString: """
        [models.post.fields.tags]
        type = "stringset"
        unique = false
        max_count = 5
        """)
        XCTAssertEqual(schemas.first?.fields["tags"]?.maxCount, 5)
        XCTAssertNil(schemas.first?.uniqueStringsetViolation)
    }

    // MARK: - Behavior 24: the one rule, and what is enforced

    func testViolationAnswersTheFieldFormTheCompoundFormAndNil() {
        let field = Self.fieldSchema.uniqueStringsetViolation
        XCTAssertEqual(field?.message, Self.fieldMessage)
        XCTAssertEqual(field?.field, "tags")
        XCTAssertEqual(field?.constraint, "post_tags_unique")

        let compound = Self.compoundSchema.uniqueStringsetViolation
        XCTAssertEqual(compound?.message, Self.compoundMessage)
        XCTAssertEqual(compound?.field, "tags")
        XCTAssertEqual(compound?.constraint, "title_tags")

        let scalar = PrimitiveSchema(
            name: "post",
            fields: [
                "title": FieldDescriptor(type: .string, unique: true),
                "slug": FieldDescriptor(type: .string),
            ],
            constraints: [
                "title_slug": ConstraintDescriptor(name: "title_slug", fields: ["title", "slug"]),
            ]
        )
        XCTAssertNil(scalar.uniqueStringsetViolation)
    }

    func testResolvedUniqueConstraintsOmitsStringsetBackedOnes() {
        let schema = PrimitiveSchema(
            name: "post",
            fields: [
                "title": FieldDescriptor(type: .string, unique: true),
                "slug": FieldDescriptor(type: .string),
                "tags": FieldDescriptor(type: .stringset, unique: true),
            ],
            constraints: [
                "title_tags": ConstraintDescriptor(name: "title_tags", fields: ["title", "tags"]),
                "title_slug": ConstraintDescriptor(name: "title_slug", fields: ["title", "slug"]),
            ]
        )
        XCTAssertEqual(
            schema.resolvedUniqueConstraints.map(\.name),
            ["post_title_unique", "title_slug"]
        )
    }

    // MARK: - Behavior 25: a programmatic schema is refused on its first write

    func testProgrammaticSchemaRegistersButItsFirstWriteIsRefused() async throws {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "unique-stringset-3719",
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            autoNetwork: false
        ))
        // Registration never throws: the signature stays additive.
        client.registerModels([Self.fieldSchema, Self.compoundSchema])
        await client.destroy()

        for schema in [Self.fieldSchema, Self.compoundSchema] {
            SchemaSync.clearCache()
            let doc = YDocument()
            let model = DynamicModel(doc: doc, schema: schema)
            let expected = schema.uniqueStringsetViolation?.message

            XCTAssertThrowsError(
                try model.create(id: "p1", values: [
                    "title": .string("one"), "tags": .stringset(["a"]),
                ])
            ) { error in
                let jsBaoError = error as? JsBaoError
                XCTAssertEqual(jsBaoError?.code, .invalidArgument)
                XCTAssertEqual(jsBaoError?.message, expected)
            }
            XCTAssertThrowsError(
                try model.save(id: "p2", values: ["title": .string("two")])
            ) { error in
                XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
            }

            XCTAssertNil(
                SchemaDiscovery.discoverSchema(doc: doc, modelNames: ["post"]).models["post"],
                "a refused declaration must not be recorded into _meta_post"
            )
            XCTAssertNil(model.find(id: "p1"))
            XCTAssertNil(model.find(id: "p2"))
            // Reads are unaffected.
            XCTAssertEqual(try model.query().count, 0)
        }
    }

    func testProgrammaticScalarUniqueSchemaStillWrites() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let schema = PrimitiveSchema(
            name: "post",
            fields: [
                "id": FieldDescriptor(type: .id),
                "title": FieldDescriptor(type: .string, unique: true),
                "tags": FieldDescriptor(type: .stringset),
            ]
        )
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "p1", values: [
            "title": .string("one"), "tags": .stringset(["a"]),
        ])
        XCTAssertNotNil(model.find(id: "p1"))
        XCTAssertNotNil(
            SchemaDiscovery.discoverSchema(doc: doc, modelNames: ["post"]).models["post"]
        )
    }

    /// Edge: the READ path stays tolerant — a document whose `_meta_`
    /// already carries the combination (recorded by an older client) still
    /// discovers.
    func testDiscoveryStillAnswersASchemaCarryingTheCombination() {
        SchemaSync.clearCache()
        let doc = YDocument()
        SchemaSync.syncModelMeta(doc: doc, schema: Self.fieldSchema)
        let discovered = SchemaDiscovery.discoverSchema(doc: doc, modelNames: ["post"])
        XCTAssertEqual(discovered.models["post"]?.fields["tags"]?.type, .stringset)
        XCTAssertEqual(discovered.models["post"]?.fields["tags"]?.unique, true)
    }
}
