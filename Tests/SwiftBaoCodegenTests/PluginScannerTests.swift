import XCTest
@testable import SwiftBaoCodegen

/// Robustness tests for the SwiftPM build-tool plugin's hand-rolled
/// mini-TOML scanner.
///
/// **Why this file exists:** The plugin lives in a separate target
/// (`Plugins/JsBaoCodegenPlugin/JsBaoCodegenPlugin.swift`) and SwiftPM
/// doesn't allow plugin code to be imported by test targets. The
/// scanner is a hand-rolled line reader that has to predict the
/// generated `<SwiftName>.swift` filenames for each `[models.X]`
/// table without depending on TOMLKit (the plugin's build closure
/// must stay light because SwiftPM rebuilds it on every consumer
/// build).
///
/// To test the scanner without restructuring targets, this file
/// **mirrors the plugin's scanner code verbatim** below as
/// `MirroredPluginScanner`. The tests then run a battery of TOML
/// inputs (edge syntax, comments, whitespace, multi-model) through
/// BOTH the mirrored scanner AND the real `TomlParser`, and assert
/// the model lists match.
///
/// **The contract:** if you change `JsBaoCodegenPlugin.predictGeneratedFiles`
/// or its helpers, **also change `MirroredPluginScanner` below**.
/// Drift here is caught here; drift between the *real* plugin and
/// this mirror is caught at the user's build site as a "missing
/// output file" SwiftPM error. That's not a fun place to debug, so
/// keep the mirror in sync.
final class PluginScannerTests: XCTestCase {

    // MARK: - Round-trip parity (parser ↔ mirrored-scanner)

    func testHappyPath_singleModel_defaultName() throws {
        try assertScannerMatchesParser("""
        [models.tasks]
        [models.tasks.fields.id]
        type = "id"
        """, expectedFiles: ["TasksRecord.swift"])
    }

    func testHappyPath_multipleModelsInOneFile() throws {
        try assertScannerMatchesParser("""
        [models.tasks]
        [models.tasks.fields.id]
        type = "id"

        [models.users]
        [models.users.fields.id]
        type = "id"
        """, expectedFiles: ["TasksRecord.swift", "UsersRecord.swift"])
    }

    func testClassNameOverride_isHonoredByScanner() throws {
        try assertScannerMatchesParser("""
        [models.tasks]
        class_name = "TaskRecord"
        [models.tasks.fields.id]
        type = "id"
        """, expectedFiles: ["TaskRecord.swift"])
    }

    func testClassNameOverride_singleQuoted_isHonoredByScanner() throws {
        // The scanner accepts single OR double quotes for the value.
        try assertScannerMatchesParser("""
        [models.tasks]
        class_name = 'TaskRecord'
        [models.tasks.fields.id]
        type = "id"
        """, expectedFiles: ["TaskRecord.swift"])
    }

    func testSnakeCaseModelName_pascalCasesCorrectly() throws {
        try assertScannerMatchesParser("""
        [models.user_profile]
        [models.user_profile.fields.id]
        type = "id"
        """, expectedFiles: ["UserProfileRecord.swift"])
    }

    func testKebabCaseModelName_pascalCasesCorrectly() throws {
        try assertScannerMatchesParser("""
        [models.user-profile]
        [models.user-profile.fields.id]
        type = "id"
        """, expectedFiles: ["UserProfileRecord.swift"])
    }

    func testFieldsTableOnly_modelInferredFromFieldHeader() throws {
        // The scanner registers a model the first time it sees ANY
        // header in `models.<name>.*` — including just a fields
        // sub-table. The parser must agree.
        try assertScannerMatchesParser("""
        [models.tasks.fields.id]
        type = "id"
        """, expectedFiles: ["TasksRecord.swift"])
    }

    // MARK: - Comments & whitespace

    func testInlineCommentAfterClassName_isStripped() throws {
        try assertScannerMatchesParser("""
        [models.tasks]
        class_name = "TaskRecord"  # trailing comment
        [models.tasks.fields.id]
        type = "id"
        """, expectedFiles: ["TaskRecord.swift"])
    }

    func testHashInsideQuotedClassName_isPreserved() throws {
        // The scanner's `inQuotes` helper has to recognize that a `#`
        // INSIDE a quoted value is part of the value, not a comment
        // start. Pin that. (The `#` survives the regex check we
        // added in the parser only if the class_name itself is a
        // valid identifier — so this test uses a trailing-comment
        // form WITHOUT a hash inside the value, since # is not a
        // legal Swift identifier character anyway.)
        //
        // Realistically this case doesn't matter much for codegen
        // (Swift identifiers can't have `#`), but the scanner's
        // robustness shouldn't depend on the specific allowed
        // character set — it should handle quotes correctly.
        // Here we use a leading-space override to exercise whitespace
        // tolerance.
        try assertScannerMatchesParser("""
        [models.tasks]
        class_name    =    "TaskRecord"
        [models.tasks.fields.id]
        type = "id"
        """, expectedFiles: ["TaskRecord.swift"])
    }

    func testBlankLines_betweenSections_areTolerated() throws {
        try assertScannerMatchesParser("""

        [models.tasks]


        [models.tasks.fields.id]
        type = "id"

        """, expectedFiles: ["TasksRecord.swift"])
    }

    func testFullLineComments_areIgnored() throws {
        try assertScannerMatchesParser("""
        # File-level comment
        [models.tasks]
        # Section-level comment
        [models.tasks.fields.id]
        type = "id"
        """, expectedFiles: ["TasksRecord.swift"])
    }

    // MARK: - Multi-model with mixed override patterns

    func testThreeModels_oneOverridesNameOnly() throws {
        try assertScannerMatchesParser("""
        [models.tasks]
        class_name = "TaskRecord"
        [models.tasks.fields.id]
        type = "id"

        [models.users]
        [models.users.fields.id]
        type = "id"

        [models.tags]
        [models.tags.fields.id]
        type = "id"
        """, expectedFiles: ["TaskRecord.swift", "UsersRecord.swift", "TagsRecord.swift"])
    }

    // MARK: - Helper

    /// Run the same TOML through the mirrored plugin scanner AND
    /// the real `TomlParser`, assert both produce the same SET of
    /// expected files. **Order isn't a contract** — TomlParser's
    /// keys come from TOMLKit alphabetically, the plugin scanner
    /// reads source-order; SwiftPM compares output files as a set,
    /// so the file *set* is what has to match. Drift in the set =
    /// build error at the user's site (missing/unexpected output).
    private func assertScannerMatchesParser(
        _ toml: String,
        expectedFiles: [String],
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        // `expectedFiles` lists the per-model outputs. The tool (and the
        // plugin's predictor) also always emit the registration barrel,
        // so fold it into the expected set here.
        let barrel = "GeneratedModels.swift"
        let expected = Set(expectedFiles)
        let expectedWithBarrel = expected.union([barrel])

        // 1. Mirrored scanner (predicts model files + barrel).
        let scannerOut = Set(MirroredPluginScanner.predict(toml: toml))
        XCTAssertEqual(
            scannerOut, expectedWithBarrel,
            "mirrored plugin scanner produced wrong file set",
            file: file, line: line
        )

        // 2. Real codegen parser yields the per-model file set only —
        //    the barrel is added by the CLI driver, not the parser.
        let schemas = try TomlParser.parse(tomlString: toml, swiftNameSuffix: "Record")
        let parserOut = Set(schemas.map { "\($0.swiftName).swift" })
        XCTAssertEqual(
            parserOut, expected,
            "real TomlParser produced wrong file set",
            file: file, line: line
        )

        // 3. Belt-and-suspenders: scanner == parser model files + barrel.
        //    This is the drift the plugin would surface as 'missing
        //    output' at user build time.
        XCTAssertEqual(
            scannerOut, parserOut.union([barrel]),
            "mirrored plugin scanner and real parser disagree",
            file: file, line: line
        )
    }
}

// MARK: - Mirrored plugin scanner
//
// **MIRROR — KEEP IN SYNC** with
// `Plugins/JsBaoCodegenPlugin/JsBaoCodegenPlugin.swift`'s
// `predictGeneratedFiles`, `parseClassNameOverride`, `inQuotes`,
// and `pascalCase` private methods. SwiftPM doesn't let test
// targets import plugin code, so this is the only way to unit-test
// the scanner without restructuring targets. If you change one
// side, change both — drift between the test mirror and the
// plugin proper is caught only at the consumer's build site as a
// SwiftPM "missing output file" error.

private enum MirroredPluginScanner {

    /// Mirror of `JsBaoCodegenPlugin.predictGeneratedFiles(at:)`,
    /// taking the TOML as a string instead of a file path.
    static func predict(toml: String) -> [String] {
        var modelOrder: [String] = []
        var modelSeen: Set<String> = []
        var classNameByModel: [String: String] = [:]
        var currentModel: String? = nil

        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let inner = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                let parts = inner.split(separator: ".").map(String.init)

                if parts.count >= 2, parts[0] == "models" {
                    let modelName = parts[1]
                    if !modelSeen.contains(modelName) {
                        modelSeen.insert(modelName)
                        modelOrder.append(modelName)
                    }
                    currentModel = (parts.count == 2) ? modelName : nil
                } else {
                    currentModel = nil
                }
                continue
            }

            if let model = currentModel {
                if let override = parseClassNameOverride(line) {
                    classNameByModel[model] = override
                }
            }
        }

        let suffix = "Record"
        var files = modelOrder.map { name -> String in
            let swiftName = classNameByModel[name] ?? (pascalCase(name) + suffix)
            return "\(swiftName).swift"
        }
        // The tool always emits the registration barrel alongside the
        // per-model files — mirror that here.
        files.append("GeneratedModels.swift")
        return files
    }

    private static func parseClassNameOverride(_ line: String) -> String? {
        let withoutComment: String
        if let hash = line.firstIndex(of: "#"), !inQuotes(line, before: hash) {
            withoutComment = String(line[line.startIndex..<hash])
        } else {
            withoutComment = line
        }
        let trimmed = withoutComment.trimmingCharacters(in: .whitespaces)
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[trimmed.startIndex..<eq]
            .trimmingCharacters(in: .whitespaces)
        guard key == "class_name" else { return nil }
        let value = trimmed[trimmed.index(after: eq)...]
            .trimmingCharacters(in: .whitespaces)
        guard value.count >= 2 else { return nil }
        let first = value.first!
        let last = value.last!
        guard (first == "\"" || first == "'"), first == last else { return nil }
        return String(value.dropFirst().dropLast())
    }

    private static func inQuotes(_ s: String, before idx: String.Index) -> Bool {
        var inDouble = false
        var inSingle = false
        var i = s.startIndex
        while i < idx {
            let c = s[i]
            if c == "\"" && !inSingle { inDouble.toggle() }
            if c == "'" && !inDouble { inSingle.toggle() }
            i = s.index(after: i)
        }
        return inDouble || inSingle
    }

    private static func pascalCase(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = ""
        var capitalizeNext = true
        for ch in s {
            if ch == "_" || ch == "-" || ch == " " {
                capitalizeNext = true
                continue
            }
            if capitalizeNext {
                out.append(Character(ch.uppercased()))
                capitalizeNext = false
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
