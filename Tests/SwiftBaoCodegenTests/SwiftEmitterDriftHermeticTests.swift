import XCTest
@testable import swift_bao_codegen

/// #5221 behavior 20 — generated models forward a device page's `drift`.
///
/// A generated model rebuilds the runtime's `PagedQueryResult` with its own
/// typed rows, field by field: both `queryPaged` overloads and the paginated
/// `hasManyThrough` accessor pass the runtime page's `drift` on, so a
/// generated model's page reports how far behind each db3 it read was.
final class SwiftEmitterDriftHermeticTests: XCTestCase {

    private static let fixture = """
    [models.posts]
    [models.posts.fields.id]
    type = "id"
    [models.posts.relationships.tags]
    type = "hasManyThrough"
    model = "tags"
    join_model = "post_tag_links"
    join_model_local_field = "postId"
    join_model_related_field = "tagId"

    [models.tags]
    [models.tags.fields.id]
    type = "id"

    [models.post_tag_links]
    [models.post_tag_links.fields.id]
    type = "id"
    """

    private func emitted() throws -> [String: String] {
        let schemas = try TomlParser.parse(tomlString: Self.fixture, swiftNameSuffix: "Record")
        let emitter = SwiftEmitter(options: EmitOptions(
            sourcePath: "schema.toml",
            swiftNamesByModel: Dictionary(uniqueKeysWithValues: schemas.map { ($0.name, $0.swiftName) })
        ))
        return Dictionary(uniqueKeysWithValues: schemas.map { ($0.swiftName, emitter.emit(schema: $0)) })
    }

    /// How many times `needle` occurs in `text`.
    private func occurrences(_ needle: String, _ text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testBothQueryPagedOverloadsForwardTheDrift() throws {
        let tags = try XCTUnwrap(try emitted()["TagsRecord"])
        XCTAssertEqual(occurrences("static func queryPaged(", tags), 2)
        XCTAssertEqual(occurrences("            hasMore: page.hasMore,\n            drift: page.drift\n", tags), 2, tags)
    }

    func testTheCountForwardsItsOptionsSoMaxDriftReachesTheReader() throws {
        let tags = try XCTUnwrap(try emitted()["TagsRecord"])
        XCTAssertTrue(tags.contains("static func count(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws -> Int {"), tags)
        XCTAssertTrue(tags.contains(".codegen.count(primitiveSchema, filter: filter, options: options)"), tags)
    }

    func testThePaginatedHasManyThroughAccessorForwardsTheDrift() throws {
        let posts = try XCTUnwrap(try emitted()["PostsRecord"])
        XCTAssertTrue(posts.contains(".codegen.hasManyThrough("), posts)
        // The two queryPaged overloads and the paginated accessor.
        XCTAssertEqual(occurrences("            hasMore: page.hasMore,\n            drift: page.drift\n", posts), 3, posts)
    }
}
