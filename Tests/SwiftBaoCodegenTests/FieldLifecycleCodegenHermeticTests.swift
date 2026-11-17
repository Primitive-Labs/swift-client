import Foundation
import XCTest
@testable import swift_bao_codegen

/// `swift-bao-codegen` over a db3 type that retires fields (#6021 behaviors
/// 8, 9, 10 and 59, the codegen half).
///
/// `deprecated` and `cleared` are known field keys and `removedFields` a known
/// model key in strict mode. A deprecated field is still generated, marked
/// `@available(*, deprecated)`; a cleared field and a tombstoned name are not
/// generated at all. A type that uses none of the keys generates what it did.
/// A field generated `required` is one `init?(record:)` guards, so a model
/// generated while a field was required returns `nil` for a record without
/// it, and one generated with it optional does not: the docs tell a developer
/// to make the field optional and ship that build before clearing it.
///
/// Hermetic: `TomlParser` and `CodegenRun` over in-memory documents.
final class FieldLifecycleCodegenHermeticTests: XCTestCase {

    private static func workspace(lifecycle: Bool, scoreRequired: Bool = false) -> String {
        """
        [type]
        name = "workspace"

        [models.tasks]
        class_name = "Task"
        \(lifecycle ? #"removedFields = ["veryOld"]"# : "")

        [models.tasks.fields.title]
        type = "string"

        [models.tasks.fields.legacyNotes]
        type = "string"
        \(lifecycle ? "deprecated = true" : "")

        [models.tasks.fields.oldScore]
        type = "number"
        \(lifecycle ? "deprecated = true\ncleared = true" : "")
        \(scoreRequired ? "required = true" : "")
        """
    }

    private func render(_ source: String) throws -> String {
        let files = try CodegenRun.render(
            documents: [(sourceName: "workspace.toml", source: source)],
            sharedEnums: nil,
            emptyLabel: "",
            accessLevel: "public",
            moduleImport: "JsBaoClient",
            swiftNameSuffix: "Record",
            strict: true
        )
        return files.filter { $0.fileName.hasPrefix("Task") }.map(\.source).joined(separator: "\n")
    }

    func testTheParserTakesTheKeysInStrictMode() throws {
        let schemas = try TomlParser.parse(tomlString: Self.workspace(lifecycle: true), swiftNameSuffix: "Record", strict: true)
        XCTAssertEqual(schemas.map(\.name), ["tasks"])
        XCTAssertEqual(schemas[0].fieldOrder.filter { $0 != "id" }, ["title", "legacyNotes"])
        XCTAssertEqual(schemas[0].fields["legacyNotes"]?.deprecated, true)
        XCTAssertNil(schemas[0].fields["oldScore"])
    }

    /// A single-field constraint over a cleared field goes with the field, as
    /// the room's install drops it; one over live fields stays.
    func testASingleFieldConstraintOverAClearedFieldGoesWithIt() throws {
        let source = Self.workspace(lifecycle: true) + """


            [[models.tasks.unique_constraints]]
            name = "score_once"
            fields = ["oldScore"]

            [[models.tasks.unique_constraints]]
            name = "title_once"
            fields = ["title"]
            """
        let schemas = try TomlParser.parse(tomlString: source, swiftNameSuffix: "Record", strict: true)
        XCTAssertEqual(schemas[0].uniqueConstraints.map(\.name), ["title_once"])
        XCTAssertFalse(try render(source).contains("oldScore"))
    }

    func testADeprecatedFieldIsMarkedAndAClearedOrTombstonedOneIsNotGenerated() throws {
        let swift = try render(Self.workspace(lifecycle: true))
        XCTAssertTrue(swift.contains("    @available(*, deprecated)\n    public var legacyNotes: String?"), swift)
        XCTAssertFalse(swift.contains("oldScore"))
        XCTAssertFalse(swift.contains("veryOld"))
        XCTAssertEqual(swift.components(separatedBy: "@available(*, deprecated)").count - 1, 1)
    }

    func testADeprecatedSharedEnumFieldMarksItsTypedAccessor() throws {
        let toml = """
            [type]
            name = "workspace"

            [models.tasks]
            class_name = "Task"

            [models.tasks.fields.phase]
            ref = "Phase"
            deprecated = true

            [models.tasks.fields.stage]
            ref = "Phase"
            """
        let files = try CodegenRun.render(
            documents: [(sourceName: "workspace.toml", source: toml)],
            sharedEnums: [SharedEnums(files: [("common", "[defs.Phase]\ntype = \"string\"\nenum = [\"open\", \"closed\"]\n")], dir: "schemas/")],
            emptyLabel: "",
            accessLevel: "public",
            moduleImport: "JsBaoClient",
            swiftNameSuffix: "Record",
            strict: true
        )
        let swift = try XCTUnwrap(files.first { $0.fileName == "Task.swift" }?.source)
        XCTAssertTrue(swift.contains("    @available(*, deprecated)\n    public var phase: Phase? {"), swift)
        XCTAssertTrue(swift.contains("    public var stage: Phase? {"), swift)
        XCTAssertFalse(swift.contains("    @available(*, deprecated)\n    public var stage: Phase? {"), swift)
    }

    func testATypeUsingNoneOfTheKeysGeneratesNoDeprecation() throws {
        let swift = try render(Self.workspace(lifecycle: false))
        XCTAssertFalse(swift.contains("@available(*, deprecated)"))
        XCTAssertTrue(swift.contains("public var oldScore: Double?"), swift)
    }

    func testARequiredFieldIsGuardedByInitRecordAndAnOptionalOneIsNot() throws {
        let required = try render(Self.workspace(lifecycle: false, scoreRequired: true))
        let optional = try render(Self.workspace(lifecycle: false))
        // The `init?(record:)` block: a required field is bound in its `guard`, which returns `nil` without it.
        let guardLine = { (source: String) -> Bool in
            guard let start = source.range(of: "init?(record: PrimitiveRecord) {") else { return false }
            let body = source[start.upperBound...]
            guard let end = body.range(of: "\n    }\n") else { return false }
            let block = String(body[..<end.lowerBound])
            return block.contains("guard let oldScore = record[\"oldScore\"]") && block.contains("else { return nil }")
        }
        XCTAssertTrue(guardLine(required), required)
        XCTAssertFalse(guardLine(optional), optional)
    }
}
