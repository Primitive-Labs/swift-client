import XCTest
@testable import swift_bao_codegen

/// `swift-bao-codegen` on a document's observed schema, and the emitter's
/// output held still (#4624 behaviours 23, 24, 28).
///
/// - 23: `Fixtures/observed-schema-4624.toml`, a document's live export
///   (`ObservedSchemaCodegenLiveTests` pins it to the export), parses in
///   strict mode with reserved field names refused, honours every
///   `class_name` it carries, and emits exactly the models committed under
///   `JsBaoClientTests/CodegenAcceptance/ObservedSchema` (compiled by that
///   target) and the barrel golden.
/// - 24: every TOML of the Swift codegen tests emits what it emitted before
///   this change: the committed generated files and goldens.
/// - 28: the Swift the emitter writes names no type outside the generated
///   models and `Fixtures/swift-reserved-names.json`, the list the JS exporter
///   keeps its `class_name` values away from; the list's keywords are
///   `Naming.swiftKeywords`.
final class ObservedSchemaCodegenHermeticTests: XCTestCase {

    private static let packageRoot: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }()

    private func text(_ relative: String) throws -> String {
        try String(contentsOf: Self.packageRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// What `swift-bao-codegen --input <relative>` writes, by file name.
    private func generate(_ relative: String) throws -> [String: String] {
        let schemas = try TomlParser.parse(
            tomlString: try text(relative), swiftNameSuffix: "Record", strict: true, rejectReservedFieldNames: true
        )
        let emitter = SwiftEmitter(options: EmitOptions(
            sourcePath: URL(fileURLWithPath: relative).lastPathComponent,
            swiftNamesByModel: Dictionary(uniqueKeysWithValues: schemas.map { ($0.name, $0.swiftName) })
        ))
        var files: [String: String] = [:]
        for schema in schemas { files["\(schema.swiftName).swift"] = emitter.emit(schema: schema) }
        files[SwiftEmitter.barrelFileName] = emitter.emitBarrel(schemas: schemas)
        return files
    }

    /// The committed files of a directory, by name (a `.golden` suffix dropped).
    private func committed(_ directory: String) throws -> [String: String] {
        let url = Self.packageRoot.appendingPathComponent(directory)
        var files: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path) where name.hasSuffix(".swift") || name.hasSuffix(".golden") {
            let key = name.hasSuffix(".golden") ? String(name.dropLast(".golden".count)) : name
            files[key] = try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
        }
        return files
    }

    private func assertSame(_ got: [String: String], _ want: [String: String], _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.keys.sorted(), want.keys.sorted(), what, file: file, line: line)
        for (name, source) in got {
            XCTAssertTrue(Array(source.utf8) == Array((want[name] ?? "").utf8), "\(what): \(name) differs", file: file, line: line)
        }
    }

    // MARK: - Behaviour 23

    func testTheObservedExportGeneratesTheCommittedModels() throws {
        let fixture = "Tests/SwiftBaoCodegenTests/Fixtures/observed-schema-4624.toml"
        let schemas = try TomlParser.parse(
            tomlString: try text(fixture), swiftNameSuffix: "Record", strict: true, rejectReservedFieldNames: true
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: schemas.map { ($0.name, $0.swiftName) }),
            ["Mix": "Mix", "Shelf": "Shelf", "any": "AnyModel", "primitive_row": "PrimitiveRowModel",
             "tasks": "TasksRecord", "tasks_record": "TasksRecordModel"],
            "class_name honoured; `tasks` keeps the Swift default name"
        )
        let generated = try generate(fixture)
        var models = try committed("Tests/JsBaoClientTests/CodegenAcceptance/ObservedSchema")
        models[SwiftEmitter.barrelFileName] = try committed("Tests/SwiftBaoCodegenTests/Goldens/observed-schema-4624")[SwiftEmitter.barrelFileName]
        assertSame(generated, models, "observed-schema-4624.toml")
        let mix = try XCTUnwrap(generated["Mix.swift"])
        for field in ["Title", "at", "mixed", "n", "nothing"] {
            XCTAssertTrue(mix.contains("public var \(field): String? {"), "observed-only \(field) is an optional string")
        }
        XCTAssertTrue(mix.contains("public var tags: Set<String>? {"))
    }

    // MARK: - Behaviour 24

    func testEveryCodegenTestSchemaEmitsWhatItDidBefore() throws {
        assertSame(try generate("Tests/JsBaoClientTests/Schema/CodegenAcceptance/fixture.toml"),
                   try committed("Tests/JsBaoClientTests/Schema/CodegenAcceptance/Generated"), "fixture.toml")
        assertSame(try generate("Tests/JsBaoClientTests/CrossPlatform/E2E/swift/Models/schema.toml"),
                   try committed("Tests/SwiftBaoCodegenTests/Goldens/e2e-schema"), "E2E schema.toml")
        assertSame(try generate("Tests/JsBaoClientTests/CrossPlatform/harness/fixtures/sample-schema.toml"),
                   try committed("Tests/SwiftBaoCodegenTests/Goldens/sample-schema"), "sample-schema.toml")
        assertSame(try generate("Tests/JsBaoClientTests/CrossPlatform/harness/fixtures/type-coercion.toml"),
                   try committed("Tests/SwiftBaoCodegenTests/Goldens/type-coercion"), "type-coercion.toml")
    }

    // MARK: - Behaviour 28

    func testTheEmittedSwiftNamesOnlyReservedTypes() throws {
        let json = try JSONSerialization.jsonObject(
            with: Data(try text("Tests/SwiftBaoCodegenTests/Fixtures/swift-reserved-names.json").utf8)
        ) as? [String: Any]
        let keywords = try XCTUnwrap(json?["keywords"] as? [String])
        let types = try XCTUnwrap(json?["types"] as? [String])
        XCTAssertEqual(Set(keywords), Naming.swiftKeywords)

        let fixture = "Tests/JsBaoClientTests/Schema/CodegenAcceptance/fixture.toml"
        let schemas = try TomlParser.parse(tomlString: try text(fixture), swiftNameSuffix: "Record", strict: true)
        let allowed = Set(keywords + types + schemas.map(\.swiftName))
        let identifier = try NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#)
        let stringLiteral = try NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#)
        var named = Set<String>()
        for source in try generate(fixture).values {
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                var code = String(line)
                if let comment = code.range(of: "//") { code = String(code[..<comment.lowerBound]) }
                code = stringLiteral.stringByReplacingMatches(
                    in: code, range: NSRange(code.startIndex..., in: code), withTemplate: "\"\""
                )
                for match in identifier.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                    named.insert(String(code[Range(match.range, in: code)!]))
                }
            }
        }
        XCTAssertEqual(named.subtracting(allowed).sorted(), [], "a type the emitter names is missing from swift-reserved-names.json")
    }
}
