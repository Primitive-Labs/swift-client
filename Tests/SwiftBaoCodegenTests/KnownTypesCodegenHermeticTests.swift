import Foundation
import XCTest
@testable import swift_bao_codegen

/// `swift-bao-codegen --known-types-only` (#6024 behaviors 28, 29, 47).
///
/// Under the flag the `GeneratedModels` barrel carries `db3Types`: the
/// setting and every input type file's db3 type name (its `[type] name`,
/// else its stem), archived ones marked, and `register(on:)` registers it,
/// also when no model was generated. Without the flag the generated code is
/// what it was (comments are not compared).
///
/// Hermetic: `CodegenRun` over in-memory documents, and the CLI's flag parse.
final class KnownTypesCodegenHermeticTests: XCTestCase {

    private static let notes = """
    [type]
    name = "notes6024"

    [models.note6024]
    class_name = "Note6024"

    [models.note6024.fields.title]
    type = "string"
    """

    private static let ledgers = """
    [type]
    name = "ledgers6024"
    archived = true
    create = "admins"

    [models.ledger6024]
    class_name = "Ledger6024"

    [models.ledger6024.fields.total]
    type = "number"
    """

    private func render(_ documents: [(String, String)], knownTypesOnly: Bool? = nil) throws -> [String: String] {
        let files: [(fileName: String, source: String)]
        if let knownTypesOnly {
            files = try CodegenRun.render(
                documents: documents.map { (sourceName: $0.0, source: $0.1) },
                emptyLabel: "db3-types/",
                accessLevel: "public",
                moduleImport: "JsBaoClient",
                swiftNameSuffix: "Record",
                strict: true,
                knownTypesOnly: knownTypesOnly
            )
        } else {
            files = try CodegenRun.render(
                documents: documents.map { (sourceName: $0.0, source: $0.1) },
                emptyLabel: "db3-types/",
                accessLevel: "public",
                moduleImport: "JsBaoClient",
                swiftNameSuffix: "Record",
                strict: true
            )
        }
        return Dictionary(uniqueKeysWithValues: files.map { ($0.fileName, $0.source) })
    }

    // MARK: - Behavior 28

    func testTheFlagIsParsed() {
        let args = CLIArgs.parse(["swift-bao-codegen", "--input", "db3-types", "--output", "out", "--known-types-only"])
        XCTAssertEqual(args?.knownTypesOnly, true)
        XCTAssertEqual(CLIArgs.parse(["swift-bao-codegen", "--input", "db3-types", "--output", "out"])?.knownTypesOnly, false)
    }

    func testTheBarrelCarriesEveryTypeAndRegistersThem() throws {
        let stem = "[type]\n\n[models.task6024]\nclass_name = \"Task6024\"\n\n[models.task6024.fields.title]\ntype = \"string\"\n"
        let barrel = try XCTUnwrap(try render(
            [("ledgers.toml", Self.ledgers), ("notes.toml", Self.notes), ("profile.toml", "[type]\nname = \"profile6024\"\n"), ("tasks.toml", stem),
             ("notes-again.toml", "[type]\nname = \"notes6024\"\n")],
            knownTypesOnly: true
        )["GeneratedModels.swift"])
        XCTAssertTrue(barrel.contains("""
            public static let db3Types = PrimitiveDb3Types(knownTypesOnly: true, types: [
                PrimitiveDb3Types.DeclaredType(name: "ledgers6024", archived: true),
                PrimitiveDb3Types.DeclaredType(name: "notes6024"),
                PrimitiveDb3Types.DeclaredType(name: "profile6024"),
                PrimitiveDb3Types.DeclaredType(name: "tasks"),
            ])
        """), barrel)
        let registerTypes = try XCTUnwrap(barrel.range(of: "client.registerDb3Types(db3Types)"))
        let registerModels = try XCTUnwrap(barrel.range(of: "client.registerModels(all)"))
        XCTAssertLessThan(registerTypes.lowerBound, registerModels.lowerBound, "the types are registered before the models")
    }

    // MARK: - Behavior 47

    func testNoModelsStillDeclaresTheSettingWithAnEmptyList() throws {
        let barrel = try XCTUnwrap(try render([], knownTypesOnly: true)["GeneratedModels.swift"])
        XCTAssertTrue(barrel.contains("public static let db3Types = PrimitiveDb3Types(knownTypesOnly: true, types: [\n    ])"), barrel)
        XCTAssertTrue(barrel.contains("client.registerDb3Types(db3Types)"), barrel)
    }

    // MARK: - Behavior 29 (pin)

    func testWithoutTheFlagTheCommittedGoldensCodeIsEmitted() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appending(path: "Tests/SwiftBaoCodegenTests/Fixtures/known-types-6024")
        let goldens = root.appending(path: "Tests/SwiftBaoCodegenTests/Goldens/known-types-6024")
        var documents: [(String, String)] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: fixtures.path(percentEncoded: false)).sorted() where name.hasSuffix(".toml") {
            documents.append((name, try String(contentsOf: fixtures.appending(path: name), encoding: .utf8)))
        }
        var committed: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: goldens.path(percentEncoded: false)) where name.hasSuffix(".golden") {
            committed[String(name.dropLast(".golden".count))] = try String(contentsOf: goldens.appending(path: name), encoding: .utf8)
        }
        for flag in [nil, false] as [Bool?] {
            let rendered = try render(documents, knownTypesOnly: flag)
            XCTAssertEqual(rendered.keys.sorted(), committed.keys.sorted())
            for (name, text) in rendered {
                XCTAssertEqual(Self.codeLines(text), Self.codeLines(committed[name] ?? ""), "\(name) differs")
                XCTAssertFalse(text.contains("db3Types"), "\(name) declares no types")
            }
        }
    }

    /// Generated Swift without its comments, line by line.
    private static func codeLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .map { line in
                var trimmed = line
                while trimmed.hasSuffix(" ") { trimmed.removeLast() }
                return trimmed
            }
            .filter { !$0.isEmpty }
    }
}
