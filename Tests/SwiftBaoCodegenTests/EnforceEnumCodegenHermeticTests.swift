import Foundation
import XCTest
@testable import swift_bao_codegen

/// `swift-bao-codegen` over a db3 type whose field enforces its enum (#5897
/// behavior 24, the codegen half).
///
/// `enforce_enum = true` or `= false` is a known key in strict mode; any other
/// value is refused in strict and non-strict mode, as js-bao's loader refuses
/// it, so it never reads as enforcement off. The room enforces the key, so the
/// generated Swift for an enforced field equals the unenforced field's.
///
/// Hermetic: `TomlParser` and `CodegenRun` over in-memory documents.
final class EnforceEnumCodegenHermeticTests: XCTestCase {

    private static func workspace(_ more: String) -> String {
        """
        [type]
        name = "workspace"

        [models.tasks]
        class_name = "Task"

        [models.tasks.fields.title]
        type = "string"

        [models.tasks.fields.status]
        type = "string"
        enum = ["open", "doing", "done"]
        default = "open"
        \(more)
        """
    }

    private func render(_ source: String) throws -> [String: String] {
        let files = try CodegenRun.render(
            documents: [(sourceName: "workspace.toml", source: source)],
            sharedEnums: nil,
            emptyLabel: "",
            accessLevel: "public",
            moduleImport: "JsBaoClient",
            swiftNameSuffix: "Record",
            strict: true
        )
        return Dictionary(uniqueKeysWithValues: files.map { ($0.fileName, $0.source) })
    }

    func testTheParserTakesTrueAndFalseInStrictMode() throws {
        for flag in ["enforce_enum = true", "enforce_enum = false"] {
            let schemas = try TomlParser.parse(tomlString: Self.workspace(flag), swiftNameSuffix: "Record", strict: true)
            XCTAssertEqual(schemas.map(\.name), ["tasks"], flag)
        }
    }

    func testTheParserRefusesAValueThatIsNotABooleanStrictOrNot() {
        for flag in [#"enforce_enum = "true""#, "enforce_enum = 1", "enforce_enum = [true]"] {
            for strict in [true, false] {
                XCTAssertThrowsError(
                    try TomlParser.parse(tomlString: Self.workspace(flag), swiftNameSuffix: "Record", strict: strict),
                    "\(flag), strict \(strict)"
                ) { error in
                    XCTAssertEqual(String(describing: error), "[models.tasks.fields.status]: enforce_enum must be true or false", flag)
                }
            }
        }
    }

    func testGeneratedSwiftForAnEnforcedFieldIsTheUnenforcedFields() throws {
        let plain = try render(Self.workspace(""))
        XCTAssertFalse(plain.isEmpty)
        XCTAssertEqual(try render(Self.workspace("enforce_enum = true")), plain)
        XCTAssertEqual(try render(Self.workspace("enforce_enum = false")), plain)
    }
}
