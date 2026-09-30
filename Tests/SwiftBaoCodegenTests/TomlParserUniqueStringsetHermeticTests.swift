import XCTest
@testable import swift_bao_codegen

/// `swift-bao-codegen` refuses a unique constraint on a stringset field
/// (#3719), with the sentence js-bao and `TomlSchemaLoader` answer — so a
/// schema the runtime refuses never codegens cleanly.
///
/// Hermetic: a TOML string in, the parser's error out.
final class TomlParserUniqueStringsetHermeticTests: XCTestCase {

    func testRefusesUniqueOnAStringsetField() {
        let toml = """
        [models.post.fields.title]
        type = "string"

        [models.post.fields.tags]
        type = "stringset"
        unique = true
        """
        XCTAssertThrowsError(
            try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")
        ) { error in
            guard case CodegenError.uniqueOnStringset = error else {
                return XCTFail("expected .uniqueOnStringset, got \(error)")
            }
            XCTAssertEqual(
                String(describing: error),
                "Model \"post\": field \"tags\" is a stringset and cannot be unique. "
                    + "A unique constraint applies to scalar fields only."
            )
        }
    }

    func testRefusesACompoundConstraintNamingAStringsetField() {
        let toml = """
        [models.post.fields.title]
        type = "string"

        [models.post.fields.tags]
        type = "stringset"

        [[models.post.unique_constraints]]
        name = "title_tags"
        fields = ["title", "tags"]
        """
        XCTAssertThrowsError(
            try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")
        ) { error in
            guard case CodegenError.uniqueOnStringset = error else {
                return XCTFail("expected .uniqueOnStringset, got \(error)")
            }
            XCTAssertEqual(
                String(describing: error),
                "Model \"post\": unique constraint \"title_tags\" names the stringset "
                    + "field \"tags\", which cannot be unique. A unique constraint "
                    + "applies to scalar fields only."
            )
        }
    }

    func testStillParsesScalarUniques() throws {
        let toml = """
        [models.post.fields.title]
        type = "string"
        unique = true

        [models.post.fields.tags]
        type = "stringset"
        unique = false
        """
        let schemas = try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")
        XCTAssertEqual(schemas.first?.fields["title"]?.unique, true)
    }
}
