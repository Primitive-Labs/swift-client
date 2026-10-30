import Foundation
import XCTest

/// `bao-codegen.json` may name several schemas with `inputs` (#5025
/// behaviour 12).
///
/// An app whose clients open several kinds of db3 keeps one type file per
/// kind under `db3-types/`. The plugin reads `{"inputs": [...]}` (files or
/// directories, resolved against the target directory as `input` is) and
/// emits ONE build command carrying every `--input`, whose outputs are the
/// union of the predicted model files plus the one `GeneratedModels.swift`.
/// `{"input": "..."}` alone resolves exactly as before, through the frozen
/// `JsBaoCodegenConfig`.
///
/// **Why this file mirrors the plugin:** a test target cannot import plugin
/// code, so the plugin's `inputs` resolver is copied verbatim at the bottom
/// of this file, between the `PLUGIN-INPUTS-MIRROR` markers, and
/// `testPluginSourceMatchesTheMirror` fails if the two differ by one byte —
/// the `PluginConfigHermeticTests` arrangement, for a second region. The
/// copy calls the `JsBaoCodegenConfig` mirrored there.
///
/// Hermetic: temporary directories, no toolchain, no server.
final class PluginInputsHermeticTests: XCTestCase {

    private static let schema = """
        [models.tasks]
        [models.tasks.fields.id]
        type = "id"
        """

    /// `<tmp>/<uuid>/Sources/MyApp` (the target directory) beside a
    /// `<tmp>/<uuid>/db3-types/` holding `b.toml`, `a.toml`, a nested
    /// directory and a non-TOML file.
    private func makeSandbox() throws -> (targetDir: URL, types: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "js-bao-5025-\(UUID().uuidString)")
        let targetDir = root.appending(path: "Sources/MyApp")
        let types = root.appending(path: "db3-types")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: types.appending(path: "nested"), withIntermediateDirectories: true)
        for name in ["b.toml", "a.toml", "nested/c.toml"] {
            try Self.schema.write(to: types.appending(path: name), atomically: true, encoding: .utf8)
        }
        try "notes".write(to: types.appending(path: "README.md"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? fileManager.removeItem(at: root) }
        return (targetDir, types)
    }

    private func writeConfig(_ json: String, in targetDir: URL) throws {
        try json.write(
            to: targetDir.appending(path: JsBaoCodegenConfig.filename), atomically: true, encoding: .utf8)
    }

    private func names(_ urls: [URL]?) -> [String] {
        (urls ?? []).map { $0.lastPathComponent }
    }

    private func failure(_ targetDir: URL, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            let resolved = try JsBaoCodegenInputs.resolve(targetDirectory: targetDir)
            XCTFail("expected a thrown error, got \(String(describing: resolved))", file: file, line: line)
            return ""
        } catch let error as JsBaoCodegenConfigError {
            return error.description
        } catch {
            XCTFail("expected JsBaoCodegenConfigError, got \(error)", file: file, line: line)
            return ""
        }
    }

    // MARK: - Resolution

    func testInputsFilesResolveAgainstTheTargetDirectoryInOrder() throws {
        let box = try makeSandbox()
        try writeConfig(#"{ "inputs": ["../../db3-types/b.toml", "../../db3-types/a.toml"] }"#, in: box.targetDir)
        let resolved = try XCTUnwrap(JsBaoCodegenInputs.resolve(targetDirectory: box.targetDir))
        XCTAssertEqual(names(resolved), ["b.toml", "a.toml"])
        XCTAssertEqual(
            resolved.first?.path(percentEncoded: false),
            box.types.appending(path: "b.toml").standardizedFileURL.path(percentEncoded: false))
    }

    func testADirectoryContributesItsTomlFilesInNameOrderOnce() throws {
        let box = try makeSandbox()
        try writeConfig(#"{ "inputs": ["../../db3-types", "../../db3-types/a.toml"] }"#, in: box.targetDir)
        XCTAssertEqual(names(try JsBaoCodegenInputs.resolve(targetDirectory: box.targetDir)), ["a.toml", "b.toml"])
    }

    func testInputAloneResolvesAsBefore() throws {
        let box = try makeSandbox()
        try writeConfig(#"{ "input": "../../db3-types/a.toml" }"#, in: box.targetDir)
        XCTAssertEqual(
            try JsBaoCodegenInputs.resolve(targetDirectory: box.targetDir),
            try JsBaoCodegenConfig.resolveInput(targetDirectory: box.targetDir).map { [$0] })
    }

    func testNoConfigFileReturnsNilSoTheScanGoverns() throws {
        let box = try makeSandbox()
        XCTAssertNil(try JsBaoCodegenInputs.resolve(targetDirectory: box.targetDir))
    }

    func testAMissingPathThrowsNamingTheConfigAndThePath() throws {
        let box = try makeSandbox()
        try writeConfig(#"{ "inputs": ["../../db3-types/a.toml", "../../db3-types/gone.toml"] }"#, in: box.targetDir)
        let message = failure(box.targetDir)
        XCTAssertTrue(message.contains(JsBaoCodegenConfig.filename), message)
        XCTAssertTrue(message.contains("\"../../db3-types/gone.toml\""), message)
        XCTAssertTrue(message.contains("no such file or directory"), message)
    }

    func testInputAndInputsTogetherOrAnEmptyListAreRefused() throws {
        let box = try makeSandbox()
        try writeConfig(#"{ "input": "../../db3-types/a.toml", "inputs": ["../../db3-types"] }"#, in: box.targetDir)
        XCTAssertTrue(failure(box.targetDir).contains("names both \"input\" and \"inputs\""))
        try writeConfig(#"{ "inputs": [] }"#, in: box.targetDir)
        XCTAssertTrue(failure(box.targetDir).contains("non-empty list of paths"))
    }

    /// 5025-C003: a scaffold's empty `db3-types/` still gets a build command,
    /// over the directory itself, so the tool writes the empty barrel.
    func testAnEmptyDirectoryResolvesToNoFilesAndIsHandedToTheToolAsADirectory() throws {
        let box = try makeSandbox()
        let empty = box.types.deletingLastPathComponent().appending(path: "empty-types")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try "notes".write(to: empty.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try writeConfig(#"{ "inputs": ["../../empty-types"] }"#, in: box.targetDir)
        XCTAssertEqual(try JsBaoCodegenInputs.resolve(targetDirectory: box.targetDir), [])
        let directories = try JsBaoCodegenInputs.directories(targetDirectory: box.targetDir)
        let trimmed = { (url: URL) in
            String(url.path(percentEncoded: false).reversed().drop(while: { $0 == "/" }).reversed())
        }
        XCTAssertEqual(directories.map(trimmed), [trimmed(empty.standardizedFileURL)])
        XCTAssertEqual(
            JsBaoCodegenInputs.outputs(predicted: [], barrel: "GeneratedModels.swift"), ["GeneratedModels.swift"])
    }

    func testDirectoriesAreEmptyForFilesAndForInputAlone() throws {
        let box = try makeSandbox()
        try writeConfig(#"{ "inputs": ["../../db3-types/a.toml"] }"#, in: box.targetDir)
        XCTAssertEqual(try JsBaoCodegenInputs.directories(targetDirectory: box.targetDir), [])
        try writeConfig(#"{ "input": "../../db3-types/a.toml" }"#, in: box.targetDir)
        XCTAssertEqual(try JsBaoCodegenInputs.directories(targetDirectory: box.targetDir), [])
    }

    // MARK: - The one build command

    func testOneCommandCarriesEveryInputAndTheUnionOfOutputs() throws {
        let output = URL(fileURLWithPath: "/work/GeneratedModels")
        let inputs = [URL(fileURLWithPath: "/types/a.toml"), URL(fileURLWithPath: "/types/b.toml")]
        XCTAssertEqual(
            JsBaoCodegenInputs.arguments(inputs: inputs, outputDirectory: output),
            ["--input", "/types/a.toml", "--input", "/types/b.toml", "--output", "/work/GeneratedModels"])
        XCTAssertEqual(
            JsBaoCodegenInputs.outputs(
                predicted: [["Account.swift", "GeneratedModels.swift"], ["Holding.swift", "Account.swift", "GeneratedModels.swift"]],
                barrel: "GeneratedModels.swift"),
            ["Account.swift", "Holding.swift", "GeneratedModels.swift"])
    }

    // MARK: - The plugin uses it

    private static let mirrorBegin = "// PLUGIN-INPUTS-MIRROR: BEGIN"
    private static let mirrorEnd = "// PLUGIN-INPUTS-MIRROR: END"

    private var pluginSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SwiftBaoCodegenTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // swift-client
            .appending(path: "Plugins/JsBaoCodegenPlugin/JsBaoCodegenPlugin.swift")
    }

    private func mirroredRegion(of text: String) -> [String]? {
        let lines = text.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == Self.mirrorBegin }),
              let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == Self.mirrorEnd }),
              begin < end
        else { return nil }
        return Array(lines[(begin + 1)..<end])
    }

    func testPluginSourceMatchesTheMirror() throws {
        let plugin = try XCTUnwrap(
            mirroredRegion(of: try String(contentsOf: pluginSourceURL, encoding: .utf8)),
            "no PLUGIN-INPUTS-MIRROR region in JsBaoCodegenPlugin.swift")
        let mirror = try XCTUnwrap(
            mirroredRegion(of: try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)),
            "no PLUGIN-INPUTS-MIRROR region in this test file")
        XCTAssertGreaterThan(mirror.count, 50)
        let drift = "the plugin's inputs resolver and the mirror below have drifted — paste "
            + "the plugin's version between the PLUGIN-INPUTS-MIRROR markers"
        if let offset = zip(plugin, mirror).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            XCTFail("\(drift)\n  line \(offset + 1) in plugin: \(plugin[offset])\n  line \(offset + 1) in mirror: \(mirror[offset])")
        }
        XCTAssertEqual(plugin.count, mirror.count, drift)
    }

    func testThePluginBuildsOneCommandFromTheResolvedInputs() throws {
        let source = try String(contentsOf: pluginSourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("JsBaoCodegenInputs.resolve(targetDirectory: targetDirectory)"))
        XCTAssertTrue(source.contains("JsBaoCodegenInputs.arguments(inputs: configured, outputDirectory: outputDir)"))
        XCTAssertTrue(source.contains("JsBaoCodegenInputs.outputs("))
    }

    func testThePluginHandsAnEmptyConfiguredDirectoryToTheTool() throws {
        let source = try String(contentsOf: pluginSourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("JsBaoCodegenInputs.directories(targetDirectory: targetDirectory)"))
    }
}

// MARK: - Mirrored from Plugins/JsBaoCodegenPlugin/JsBaoCodegenPlugin.swift
//
// Verbatim copy: `testPluginSourceMatchesTheMirror` compares these bytes
// against the plugin source. Keep the marker comments exactly as they are.

// PLUGIN-INPUTS-MIRROR: BEGIN
/// `bao-codegen.json`'s `inputs` form: several schema files, each named
/// directly or through its directory, generated together by ONE build
/// command into the one `GeneratedModels` directory, so the codegen tool
/// writes one barrel over all of them and its stale-file sweep sees every
/// model. An app whose clients open several kinds of db3 points it at its
/// `db3-types/` directory:
/// ```json
/// { "inputs": ["../../primitive/dev/db3-types"] }
/// ```
enum JsBaoCodegenInputs {

    /// The schema files the target's `bao-codegen.json` names, in order, or
    /// `nil` when there is no config file (the scan governs).
    ///
    /// With `inputs`, each entry resolves against the target directory as
    /// `input` does; a directory contributes every `*.toml` directly inside
    /// it, in name order, and a file named twice counts once. An entry that
    /// does not exist throws, naming the config and the path; it never
    /// degrades to the scan. Without `inputs`, the config is
    /// `JsBaoCodegenConfig.resolveInput`'s, exactly as before.
    static func resolve(targetDirectory: URL) throws -> [URL]? {
        try resolveEntries(targetDirectory: targetDirectory)?.files
    }

    /// The directories `inputs` names, in order. When they hold no schema
    /// yet (a scaffold's empty `db3-types/`), the build command hands the
    /// codegen tool the directories themselves, and it writes the empty
    /// barrel, so `GeneratedModels` exists before the first type file does.
    static func directories(targetDirectory: URL) throws -> [URL] {
        try resolveEntries(targetDirectory: targetDirectory)?.directories ?? []
    }

    private static func resolveEntries(
        targetDirectory: URL
    ) throws -> (files: [URL], directories: [URL])? {
        let filename = JsBaoCodegenConfig.filename
        let configURL = targetDirectory.appending(path: filename)
        let configPath = configURL.path(percentEncoded: false)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: configPath) else { return nil }

        let object = (try? Data(contentsOf: configURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        guard let object, let rawInputs = object["inputs"] else {
            return try JsBaoCodegenConfig.resolveInput(targetDirectory: targetDirectory)
                .map { (files: [$0], directories: []) }
        }
        if object["input"] != nil {
            throw JsBaoCodegenConfigError(
                description: "\(filename) at \(configPath) names both \"input\" and \"inputs\"; "
                    + "keep one. \"inputs\" takes a list: {\"inputs\": [\"<path>\", ...]}."
            )
        }
        guard let entries = rawInputs as? [String], !entries.isEmpty else {
            throw JsBaoCodegenConfigError(
                description: "\(filename) at \(configPath) has an \"inputs\" that is not a "
                    + "non-empty list of paths; expected {\"inputs\": [\"<path>\", ...]}."
            )
        }

        let baseDirectory = URL(
            fileURLWithPath: targetDirectory.path(percentEncoded: false), isDirectory: true)
        var files: [URL] = []
        var directories: [URL] = []
        var seen: Set<String> = []
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw JsBaoCodegenConfigError(
                    description: "\(filename) at \(configPath) has an empty entry in \"inputs\"; "
                        + "expected a path to a schema TOML or a directory of them."
                )
            }
            let resolved =
                trimmed.hasPrefix("/")
                ? URL(fileURLWithPath: trimmed).standardizedFileURL
                : URL(fileURLWithPath: trimmed, relativeTo: baseDirectory).standardizedFileURL
            let resolvedPath = resolved.path(percentEncoded: false)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
                throw JsBaoCodegenConfigError(
                    description: "\(filename) at \(configPath) names input \"\(trimmed)\", "
                        + "which resolves to \(resolvedPath) — no such file or directory."
                )
            }
            var members = [resolved]
            if isDirectory.boolValue {
                directories.append(resolved)
                members = try fileManager.contentsOfDirectory(atPath: resolvedPath)
                    .filter { $0.hasSuffix(".toml") }
                    .sorted()
                    .map { resolved.appending(path: $0) }
                    .filter {
                        var memberIsDirectory: ObjCBool = false
                        return fileManager.fileExists(
                            atPath: $0.path(percentEncoded: false), isDirectory: &memberIsDirectory)
                            && !memberIsDirectory.boolValue
                    }
            }
            for member in members where seen.insert(member.path(percentEncoded: false)).inserted {
                files.append(member)
            }
        }
        return (files: files, directories: directories)
    }

    /// The codegen tool's arguments for one build command over `inputs`.
    static func arguments(inputs: [URL], outputDirectory: URL) -> [String] {
        inputs.flatMap { ["--input", $0.path(percentEncoded: false)] }
            + ["--output", outputDirectory.path(percentEncoded: false)]
    }

    /// The files one build command over several inputs writes: each input's
    /// predicted model files once, in input order, then the barrel.
    static func outputs(predicted: [[String]], barrel: String) -> [String] {
        var files: [String] = []
        var seen: Set<String> = [barrel]
        for name in predicted.joined() where seen.insert(name).inserted {
            files.append(name)
        }
        return files + [barrel]
    }
}
// PLUGIN-INPUTS-MIRROR: END
