import Foundation
import XCTest
@testable import swift_bao_codegen

/// The implicit `id` of a db3 type file is in place before the model's fields
/// are judged (#5025, 5025-SO-008).
///
/// A unique constraint may name `id`. The parser checks every constraint's
/// fields against the model's, so the synthesized field has to exist by then,
/// or an id-less type-file model is refused where the same model with `id`
/// declared `auto_assign = true` is accepted (and js-bao accepts both).
final class SynthesizedIdConstraintHermeticTests: XCTestCase {

    private static let implicitId = """
        [type]
        name = "codes"

        [models.codes]
        class_name = "ImplicitIdCode"

        [models.codes.fields.code]
        type = "string"

        [[models.codes.unique_constraints]]
        name = "by_id_and_code"
        fields = ["id", "code"]
        """

    private static let declaredId = """
        [type]
        name = "codes"

        [models.codes]
        class_name = "ImplicitIdCode"

        [models.codes.fields.id]
        type = "id"
        auto_assign = true

        [models.codes.fields.code]
        type = "string"

        [[models.codes.unique_constraints]]
        name = "by_id_and_code"
        fields = ["id", "code"]
        """

    private func parse(_ toml: String) throws -> [ParsedSchema] {
        try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record", strict: true, rejectReservedFieldNames: true)
    }

    private func emit(_ toml: String) throws -> [String: String] {
        let schemas = try parse(toml)
        let emitter = SwiftEmitter(options: EmitOptions(
            sourcePath: "codes.toml",
            swiftNamesByModel: Dictionary(uniqueKeysWithValues: schemas.map { ($0.name, $0.swiftName) })
        ))
        return Dictionary(uniqueKeysWithValues: schemas.map { ("\($0.swiftName).swift", emitter.emit(schema: $0)) })
    }

    func testAUniqueConstraintNamingTheImplicitIdIsAccepted() throws {
        let codes = try XCTUnwrap(parse(Self.implicitId).first)
        XCTAssertEqual(codes.fieldOrder, ["id", "code"])
        XCTAssertEqual(codes.fields["id"]?.type, .id)
        XCTAssertEqual(codes.fields["id"]?.autoAssign, true)
        XCTAssertEqual(codes.uniqueConstraints.map(\.name), ["by_id_and_code"])
        XCTAssertEqual(codes.uniqueConstraints.first?.fields, ["id", "code"])
    }

    func testTheImplicitFormEmitsWhatTheDeclaredFormEmits() throws {
        XCTAssertEqual(try emit(Self.implicitId), try emit(Self.declaredId))
    }

    func testWithoutATypeTableTheConstraintStillNeedsADeclaredId() {
        let plain = Self.implicitId.replacingOccurrences(of: "[type]\nname = \"codes\"\n\n", with: "")
        XCTAssertThrowsError(try parse(plain)) { error in
            guard case CodegenError.uniqueConstraintUnknownField(_, _, let field) = error else {
                return XCTFail("expected uniqueConstraintUnknownField, got \(error)")
            }
            XCTAssertEqual(field, "id")
        }
    }
}
