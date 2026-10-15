import Foundation
import XCTest
@testable import swift_bao_codegen

/// `swift-bao-codegen` refuses a field name that breaks a generated model on
/// either client (#4505), and `type` and `_`-prefixed names (#3501), with
/// js-bao's exact `[models.<model>.fields.<field>]: <sentence>` — so a schema
/// the JavaScript codegen refuses never codegens cleanly here either.
///
/// The refusal sits behind `rejectReservedFieldNames`, js-bao's loader option:
/// the plugin passes `true`; a test that needs to build a model the plugin
/// would refuse (the compiled probe in `ReservedFieldNamesInvariantHermeticTests`)
/// passes `false`.
///
/// Hermetic: TOML strings in, the parser's error out; the binary half runs the
/// built `swift-bao-codegen` on a temp file.
final class TomlParserReservedFieldHermeticTests: XCTestCase {

    private func schema(declaring name: String, extra: String = "type = \"string\"") -> String {
        """
        [models.post.fields.id]
        type = "id"

        [models.post.fields.title]
        type = "string"

        [models.post.fields.\(name)]
        \(extra)
        """
    }

    private func sentence(_ name: String) -> String {
        if name == "type" { return "Field 'type' is reserved (maps to internal _type column in queries)" }
        if name.hasPrefix("_") { return "Field '\(name)' is reserved (fields starting with '_' are internal)" }
        return "Field '\(name)' is reserved (\(ReservedFieldNames.reasons[name] ?? "?"))"
    }

    private func assertRefused(_ toml: String, naming name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(
            try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record", rejectReservedFieldNames: true),
            name, file: file, line: line
        ) { error in
            guard case CodegenError.reservedFieldName = error else {
                return XCTFail("\(name): expected .reservedFieldName, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(
                String(describing: error),
                "[models.post.fields.\(name)]: \(sentence(name))",
                file: file, line: line
            )
        }
    }

    func testRefusesEveryListedNameTypeAndTheUnderscorePrefix() {
        XCTAssertFalse(ReservedFieldNames.reasons.isEmpty)
        for name in ReservedFieldNames.reasons.keys.sorted() + ["type", "_data"] {
            assertRefused(schema(declaring: name), naming: name)
        }
    }

    func testTheSentenceIsJsBaosForAJavaScriptAndASwiftName() {
        assertRefused(schema(declaring: "syncState"), naming: "syncState")
        XCTAssertEqual(sentence("syncState"), "Field 'syncState' is reserved (a record property on the JavaScript client)")
        XCTAssertEqual(sentence("related"), "Field 'related' is reserved (the generated struct's query-time includes on the Swift client)")
    }

    func testTheRefusalRunsBeforeTheFieldTypeCheck() {
        // No `type` key: js-bao reports the reserved name first, and so does this.
        assertRefused(schema(declaring: "syncState", extra: "indexed = true"), naming: "syncState")
        assertRefused(schema(declaring: "related", extra: "type = \"nonsense\""), naming: "related")
    }

    func testWithoutTheFlagAStoredSchemaStillParsesAndKeepsTheField() throws {
        for name in ["syncState", "related", "save", "type"] {
            let parsed = try TomlParser.parse(
                tomlString: schema(declaring: name), swiftNameSuffix: "Record", rejectReservedFieldNames: false
            )
            XCTAssertTrue(parsed.first?.fieldOrder.contains(name) == true, name)
        }
        // The default is the read path's: no refusal.
        XCTAssertNoThrow(try TomlParser.parse(tomlString: schema(declaring: "syncState"), swiftNameSuffix: "Record"))
    }

    func testAcceptsIdEveryExemptNameAndLookalikes() throws {
        var toml = "[models.post.fields.id]\ntype = \"id\"\n"
        for name in ReservedFieldNames.exempt.sorted() + ["syncStatus", "a_b", "Save", "sync_state"] {
            toml += "\n[models.post.fields.\(name)]\ntype = \"string\"\n"
        }
        let parsed = try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record", rejectReservedFieldNames: true)
        XCTAssertEqual(
            Set(parsed.first?.fieldOrder ?? []),
            Set(["id", "syncStatus", "a_b", "Save", "sync_state"]).union(ReservedFieldNames.exempt)
        )
    }

    // MARK: - The binary

    /// The built `swift-bao-codegen`, in the products directory beside this
    /// test bundle. `swift test` builds it with the test target.
    private func codegenBinary() throws -> URL {
        let bundle = Bundle(for: Self.self).bundleURL
        let candidates = [
            bundle.deletingLastPathComponent().appendingPathComponent("swift-bao-codegen"),
            bundle.appendingPathComponent("swift-bao-codegen"),
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            XCTFail("swift-bao-codegen is not built beside the test bundle: \(candidates.map(\.path))")
            throw CocoaError(.fileNoSuchFile)
        }
        return binary
    }

    func testTheBinaryExitsNonZeroAndWritesNothing() throws {
        let binary = try codegenBinary()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("reserved-field-4505-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let input = scratch.appendingPathComponent("schema.toml")
        try schema(declaring: "syncState").write(to: input, atomically: true, encoding: .utf8)
        let output = scratch.appendingPathComponent("Generated")

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--input", input.path, "--output", output.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let printed = String(decoding: data, as: UTF8.self)

        XCTAssertNotEqual(process.terminationStatus, 0, printed)
        XCTAssertTrue(printed.contains("[models.post.fields.syncState]: \(sentence("syncState"))"), printed)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
        XCTAssertEqual(written, [], "the output directory is absent or empty")
    }
}
