import XCTest
@testable import swift_bao_codegen

/// #5895 behavior 9 — the generated models name their upsert targets.
///
/// Each model with a unique field or constraint gets a nested
/// `UniqueField` (the fields `save(in:upsertOn:)` resolves: each one a
/// unique constraint covers on its own) and `UniqueConstraint` (the names
/// `upsertByUnique` looks up: `<model>_<field>_unique` per unique field,
/// then each declared constraint), and typed overloads of those calls
/// beside the `String` forms. A model with none gets neither, and keeps
/// the `String` forms.
final class SwiftEmitterUpsertNamesHermeticTests: XCTestCase {

    private static let fixture = """
    [models.posts]
    [models.posts.fields.id]
    type = "id"
    [models.posts.fields.slug]
    type = "string"
    unique = true
    [models.posts.fields.title]
    type = "string"
    [models.posts.fields.author]
    type = "string"
    [models.posts.fields.default]
    type = "string"
    [models.posts.fields.tags]
    type = "stringset"
    [[models.posts.unique_constraints]]
    name = "title_author"
    fields = ["title", "author"]
    [[models.posts.unique_constraints]]
    name = "by_default"
    fields = ["default"]

    [models.notes]
    [models.notes.fields.id]
    type = "id"
    [models.notes.fields.body]
    type = "string"
    """

    private func emitted() throws -> [String: String] {
        let schemas = try TomlParser.parse(tomlString: Self.fixture, swiftNameSuffix: "Record")
        let emitter = SwiftEmitter(options: EmitOptions(
            sourcePath: "schema.toml",
            swiftNamesByModel: Dictionary(uniqueKeysWithValues: schemas.map { ($0.name, $0.swiftName) })
        ))
        return Dictionary(uniqueKeysWithValues: schemas.map { ($0.swiftName, emitter.emit(schema: $0)) })
    }

    func testDeclaresTheUniqueFieldsAndConstraintsAsNestedEnums() throws {
        let posts = try XCTUnwrap(try emitted()["PostsRecord"])
        XCTAssertTrue(posts.contains("""
            enum UniqueField: String, Sendable {
                case slug = "slug"
                case `default` = "default"
            }
        """), posts)
        XCTAssertTrue(posts.contains("""
            enum UniqueConstraint: String, Sendable {
                case posts_slug_unique = "posts_slug_unique"
                case title_author = "title_author"
                case by_default = "by_default"
            }
        """), posts)
    }

    func testTypedUpsertsForwardTheRawNameToTheStringForms() throws {
        let posts = try XCTUnwrap(try emitted()["PostsRecord"])
        XCTAssertTrue(posts.contains("""
            func save(in documentId: String, upsertOn: UniqueField) throws -> PostsRecord {
                try save(in: documentId, upsertOn: upsertOn.rawValue)
            }
        """), posts)
        XCTAssertTrue(posts.contains("""
            func upsertByUnique(_ constraint: UniqueConstraint, mode: UpsertMode = .either, in documentId: String) throws -> PostsRecord {
                try upsertByUnique(constraint.rawValue, mode: mode, in: documentId)
            }
        """), posts)
        XCTAssertTrue(posts.contains("""
            func upsertByUnique(_ constraint: UniqueConstraint, lookupValue: [PrimitiveValue], mode: UpsertMode = .either, in documentId: String) throws -> PostsRecord {
                try upsertByUnique(constraint.rawValue, lookupValue: lookupValue, mode: mode, in: documentId)
            }
        """), posts)
        // The String forms stay.
        XCTAssertTrue(posts.contains("func save(in documentId: String, upsertOn: String) throws -> PostsRecord {"), posts)
        XCTAssertTrue(posts.contains("func upsertByUnique(_ constraint: String, mode: UpsertMode = .either, in documentId: String) throws -> PostsRecord {"), posts)
    }

    /// Names that sanitize alike (`slug_` trims to `slug`) never reuse a
    /// case another name already took, whether that case is a suffixed one
    /// (`slug_2` from the `slug_` collision) or a name's own (`slug_2`
    /// declared first), so each enum's cases stay distinct.
    func testSanitizedNamesNeverCollideWithSuffixedOnes() throws {
        let toml = """
        [models.posts]
        [models.posts.fields.id]
        type = "id"
        [models.posts.fields.slug]
        type = "string"
        unique = true
        [models.posts.fields.slug_]
        type = "string"
        unique = true
        [models.posts.fields.slug_2]
        type = "string"
        unique = true

        [models.notes]
        [models.notes.fields.id]
        type = "id"
        [models.notes.fields.a]
        type = "string"
        [[models.notes.unique_constraints]]
        name = "by_a_2"
        fields = ["a"]
        [[models.notes.unique_constraints]]
        name = "by_a"
        fields = ["a"]
        [[models.notes.unique_constraints]]
        name = "by-a"
        fields = ["a"]
        """
        let schemas = try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")
        let emitter = SwiftEmitter(options: EmitOptions(
            sourcePath: "schema.toml",
            swiftNamesByModel: Dictionary(uniqueKeysWithValues: schemas.map { ($0.name, $0.swiftName) })
        ))
        let out = Dictionary(uniqueKeysWithValues: schemas.map { ($0.swiftName, emitter.emit(schema: $0)) })
        let posts = try XCTUnwrap(out["PostsRecord"])
        XCTAssertTrue(posts.contains("""
            enum UniqueField: String, Sendable {
                case slug = "slug"
                case slug_2 = "slug_"
                case slug_2_2 = "slug_2"
            }
        """), posts)
        let notes = try XCTUnwrap(out["NotesRecord"])
        XCTAssertTrue(notes.contains("""
            enum UniqueConstraint: String, Sendable {
                case by_a_2 = "by_a_2"
                case by_a = "by_a"
                case by_a_3 = "by-a"
            }
        """), notes)
    }

    func testAModelWithNoUniqueNamesKeepsOnlyTheStringForms() throws {
        let notes = try XCTUnwrap(try emitted()["NotesRecord"])
        XCTAssertFalse(notes.contains("UniqueField"), notes)
        XCTAssertFalse(notes.contains("UniqueConstraint"), notes)
        XCTAssertTrue(notes.contains("func save(in documentId: String, upsertOn: String) throws -> NotesRecord {"), notes)
    }
}
