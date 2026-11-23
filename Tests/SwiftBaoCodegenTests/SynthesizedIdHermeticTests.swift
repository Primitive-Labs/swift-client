import Foundation
import XCTest
@testable import swift_bao_codegen

/// A model in a db3 type file needs no `id` field (#5025 behaviour 23, edges
/// E12 and E13, the Swift half).
///
/// In a TOML document with a `[type]` table, a model that declares no `id`
/// parses as if it declared `[models.<m>.fields.id] type = "id",
/// auto_assign = true`, first in field order, as js-bao's loader reads it.
/// The emitter sees an ordinary `id` field, so the struct is the one a
/// declared `auto_assign` id gives. A document with no `[type]` table parses
/// as it always has.
///
/// The structs `Fixtures/implicit-id-5025.toml` emits are committed under
/// `JsBaoClientTests/CodegenAcceptance/ImplicitId`, where the test target
/// compiles them and `ImplicitIdAcceptanceHermeticTests` exercises them.
final class SynthesizedIdHermeticTests: XCTestCase {

    private static let packageRoot: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }()

    private static let models = """
        [models.notes]
        class_name = "ImplicitIdNote"

        [models.notes.fields.title]
        type = "string"
        required = true

        [models.notes.fields.done]
        type = "boolean"
        """

    private static let declaredId = """
        [models.notes]
        class_name = "ImplicitIdNote"

        [models.notes.fields.id]
        type = "id"
        auto_assign = true

        [models.notes.fields.title]
        type = "string"
        required = true

        [models.notes.fields.done]
        type = "boolean"
        """

    private func parse(_ toml: String) throws -> [ParsedSchema] {
        try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record", strict: true, rejectReservedFieldNames: true)
    }

    private func emit(_ toml: String, source: String = "implicit-id-5025.toml") throws -> [String: String] {
        let schemas = try parse(toml)
        let emitter = SwiftEmitter(options: EmitOptions(
            sourcePath: source,
            swiftNamesByModel: Dictionary(uniqueKeysWithValues: schemas.map { ($0.name, $0.swiftName) })
        ))
        return Dictionary(uniqueKeysWithValues: schemas.map { ("\($0.swiftName).swift", emitter.emit(schema: $0)) })
    }

    func testATypeFileModelWithNoIdGetsAnAutoAssignedIdFirst() throws {
        let note = try XCTUnwrap(parse("[type]\nname = \"notes\"\n\n\(Self.models)").first)
        XCTAssertEqual(note.fieldOrder, ["id", "title", "done"])
        let id = try XCTUnwrap(note.fields["id"])
        XCTAssertEqual(id.type, .id)
        XCTAssertTrue(id.autoAssign)
        XCTAssertFalse(id.required)
        XCTAssertFalse(id.indexed)
    }

    func testTheStructIsTheOneADeclaredAutoAssignIdGives() throws {
        XCTAssertEqual(
            try emit("[type]\nname = \"notes\"\n\n\(Self.models)"),
            try emit("[type]\nname = \"notes\"\n\n\(Self.declaredId)"))
        XCTAssertEqual(try emit("[type]\nname = \"notes\"\n\n\(Self.models)"), try emit(Self.declaredId))
    }

    func testAModelWithNoTypeTableParsesAsToday() throws {
        let note = try XCTUnwrap(parse(Self.models).first)
        XCTAssertEqual(note.fieldOrder, ["title", "done"])
        XCTAssertNil(note.fields["id"])
    }

    func testOneModelDeclaresIdAndAnotherDoesNotInOneRun() throws {
        let toml = """
            [type]
            name = "mixed"

            [models.declared]
            class_name = "Declared"

            [models.declared.fields.id]
            type = "id"
            indexed = true

            [models.declared.fields.label]
            type = "string"

            [models.synthesized]
            class_name = "Synthesized"

            [models.synthesized.fields.label]
            type = "string"
            """
        let schemas = try parse(toml)
        let declared = try XCTUnwrap(schemas.first { $0.name == "declared" })
        let synthesized = try XCTUnwrap(schemas.first { $0.name == "synthesized" })
        XCTAssertTrue(declared.fields["id"]!.indexed)
        XCTAssertFalse(declared.fields["id"]!.autoAssign)
        XCTAssertTrue(synthesized.fields["id"]!.autoAssign)
        XCTAssertEqual(synthesized.fieldOrder, ["id", "label"])
        let files = try emit(toml)
        XCTAssertTrue(files["Synthesized.swift"]!.contains("FieldDescriptor(type: .id, autoAssign: true)"))
        XCTAssertTrue(files["Declared.swift"]!.contains("FieldDescriptor(type: .id, indexed: true)"))
    }

    func testATypeFileModelWithNoFieldsHasExactlyTheIdField() throws {
        let empty = try XCTUnwrap(parse("[type]\nname = \"e\"\n\n[models.empty]\nclass_name = \"ImplicitIdEmpty\"\n").first)
        XCTAssertEqual(empty.fieldOrder, ["id"])
        XCTAssertEqual(Array(empty.fields.keys), ["id"])
    }

    func testTheFixtureEmitsTheCommittedAcceptanceStructs() throws {
        let fixture = Self.packageRoot.appending(path: "Tests/SwiftBaoCodegenTests/Fixtures/implicit-id-5025.toml")
        let generated = try emit(try String(contentsOf: fixture, encoding: .utf8))
        let directory = Self.packageRoot.appending(path: "Tests/JsBaoClientTests/CodegenAcceptance/ImplicitId")
        var committed: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        where name.hasSuffix(".swift") && !name.hasSuffix("HermeticTests.swift") {
            committed[name] = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
        }
        XCTAssertEqual(generated.keys.sorted(), ["ImplicitIdEmpty.swift", "ImplicitIdNote.swift"])
        XCTAssertEqual(generated, committed)
    }
}
