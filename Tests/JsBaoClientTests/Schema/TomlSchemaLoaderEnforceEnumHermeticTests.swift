import XCTest
@testable import JsBaoClient

/// `TomlSchemaLoader` reads `enforce_enum` (#5897 behavior 24, the loader
/// half): `true` and `false` are known in strict mode, and any other value is
/// refused in strict and non-strict mode, as js-bao's loader refuses it, so a
/// malformed value never loads as enforcement off. The room enforces the key;
/// the loaded field is the unenforced field's.
final class TomlSchemaLoaderEnforceEnumHermeticTests: XCTestCase {

    private static func workspace(_ more: String) -> String {
        """
        [type]
        name = "workspace"

        [models.tasks.fields.status]
        type = "string"
        enum = ["open", "doing", "done"]
        \(more)
        """
    }

    func testTrueAndFalseLoadInStrictModeAsTheUnenforcedField() throws {
        let plain = try TomlSchemaLoader.load(tomlString: Self.workspace(""), strict: true)
        XCTAssertEqual(plain.first?.fields["status"]?.type, .string)
        for flag in ["enforce_enum = true", "enforce_enum = false"] {
            XCTAssertEqual(try TomlSchemaLoader.load(tomlString: Self.workspace(flag), strict: true), plain, flag)
        }
    }

    func testAValueThatIsNotABooleanIsRefusedStrictOrNot() {
        for flag in [#"enforce_enum = "true""#, "enforce_enum = 1", "enforce_enum = [true]"] {
            for strict in [true, false] {
                XCTAssertThrowsError(try TomlSchemaLoader.load(tomlString: Self.workspace(flag), strict: strict), "\(flag), strict \(strict)") { error in
                    XCTAssertEqual(String(describing: error), "[models.tasks.fields.status]: enforce_enum must be true or false", flag)
                }
            }
        }
    }
}
