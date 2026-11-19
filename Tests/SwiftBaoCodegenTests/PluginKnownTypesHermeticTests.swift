import Foundation
import XCTest

/// `bao-codegen.json` may say `"knownTypesOnly": true` (#6024, Step 0f):
/// the SwiftPM codegen plugin then hands `swift-bao-codegen`
/// `--known-types-only` on the build command it makes from the config, so a
/// package that runs the plugin turns the known-type guard on from its
/// existing codegen configuration.
///
/// **Why this file mirrors the plugin:** a test target cannot import plugin
/// code, so the plugin's `JsBaoCodegenKnownTypes` is copied at the bottom of
/// this file, between the `PLUGIN-KNOWN-TYPES-MIRROR` markers, and
/// `testPluginSourceMatchesTheMirror` fails if the two regions' code differs.
/// Comment lines and blank lines are left out of that comparison, so a
/// wording change to the plugin's documentation does not fail it. The copy
/// uses the `JsBaoCodegenConfig` and `JsBaoCodegenConfigError` mirrored in
/// `PluginConfigHermeticTests`.
///
/// Hermetic: temporary directories, no toolchain, no server.
final class PluginKnownTypesHermeticTests: XCTestCase {

    private func makeTargetDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "js-bao-6024-plugin-\(UUID().uuidString)")
        let targetDir = root.appending(path: "Sources/MyApp")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return targetDir
    }

    private func writeConfig(_ json: String, in targetDir: URL) throws {
        try json.write(
            to: targetDir.appending(path: JsBaoCodegenConfig.filename), atomically: true, encoding: .utf8)
    }

    // MARK: - The key

    func testNoConfigFileAddsNoFlag() throws {
        let targetDir = try makeTargetDirectory()
        XCTAssertFalse(try JsBaoCodegenKnownTypes.enabled(targetDirectory: targetDir))
        XCTAssertEqual(try JsBaoCodegenKnownTypes.arguments(targetDirectory: targetDir), [])
    }

    func testAConfigWithoutTheKeyAddsNoFlag() throws {
        let targetDir = try makeTargetDirectory()
        try writeConfig(#"{ "inputs": ["../../primitive/dev/db3-types"] }"#, in: targetDir)
        XCTAssertEqual(try JsBaoCodegenKnownTypes.arguments(targetDirectory: targetDir), [])
    }

    func testTrueBesideInputsAddsTheFlag() throws {
        let targetDir = try makeTargetDirectory()
        try writeConfig(
            #"{ "inputs": ["../../primitive/dev/db3-types"], "knownTypesOnly": true }"#, in: targetDir)
        XCTAssertTrue(try JsBaoCodegenKnownTypes.enabled(targetDirectory: targetDir))
        XCTAssertEqual(try JsBaoCodegenKnownTypes.arguments(targetDirectory: targetDir), ["--known-types-only"])
    }

    func testTrueBesideOneInputAddsTheFlag() throws {
        let targetDir = try makeTargetDirectory()
        try writeConfig(#"{ "input": "../../models.toml", "knownTypesOnly": true }"#, in: targetDir)
        XCTAssertEqual(try JsBaoCodegenKnownTypes.arguments(targetDirectory: targetDir), ["--known-types-only"])
    }

    func testFalseAddsNoFlag() throws {
        let targetDir = try makeTargetDirectory()
        try writeConfig(#"{ "inputs": ["../../types"], "knownTypesOnly": false }"#, in: targetDir)
        XCTAssertEqual(try JsBaoCodegenKnownTypes.arguments(targetDirectory: targetDir), [])
    }

    func testAValueThatIsNotTrueOrFalseThrowsNamingTheConfig() throws {
        for value in [#""yes""#, "1", "0", "[true]"] {
            let targetDir = try makeTargetDirectory()
            try writeConfig(#"{ "inputs": ["../../types"], "knownTypesOnly": \#(value) }"#, in: targetDir)
            XCTAssertThrowsError(try JsBaoCodegenKnownTypes.enabled(targetDirectory: targetDir), value) { error in
                let description = (error as? JsBaoCodegenConfigError)?.description ?? ""
                XCTAssertTrue(description.contains(JsBaoCodegenConfig.filename), description)
                XCTAssertTrue(description.contains("knownTypesOnly"), description)
            }
        }
    }

    func testBrokenJSONIsLeftToTheSchemaResolver() throws {
        let targetDir = try makeTargetDirectory()
        try writeConfig(#"{ "knownTypesOnly": "#, in: targetDir)
        XCTAssertFalse(try JsBaoCodegenKnownTypes.enabled(targetDirectory: targetDir))
    }

    // MARK: - The plugin uses it

    private static let mirrorBegin = "// PLUGIN-KNOWN-TYPES-MIRROR: BEGIN"
    private static let mirrorEnd = "// PLUGIN-KNOWN-TYPES-MIRROR: END"

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

    /// The region's code: its lines without comment lines and blank lines.
    /// (The region holds no comment after code on the same line.)
    private func codeOf(_ region: [String]) -> [String] {
        region.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("//")
        }
    }

    func testPluginSourceMatchesTheMirror() throws {
        let plugin = codeOf(try XCTUnwrap(
            mirroredRegion(of: try String(contentsOf: pluginSourceURL, encoding: .utf8)),
            "no PLUGIN-KNOWN-TYPES-MIRROR region in JsBaoCodegenPlugin.swift"))
        let mirror = codeOf(try XCTUnwrap(
            mirroredRegion(of: try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)),
            "no PLUGIN-KNOWN-TYPES-MIRROR region in this test file"))
        XCTAssertGreaterThan(mirror.count, 20)
        let drift = "the code of the plugin's knownTypesOnly reader and the mirror below have drifted — paste "
            + "the plugin's version between the PLUGIN-KNOWN-TYPES-MIRROR markers (comment and blank lines are not compared)"
        if let offset = zip(plugin, mirror).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            XCTFail("\(drift)\n  code line \(offset + 1) in plugin: \(plugin[offset])\n  code line \(offset + 1) in mirror: \(mirror[offset])")
        }
        XCTAssertEqual(plugin.count, mirror.count, drift)
    }

    func testTheConfiguredBuildCommandCarriesTheKeysArguments() throws {
        let source = try String(contentsOf: pluginSourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains(
            "let knownTypes = try JsBaoCodegenKnownTypes.arguments(targetDirectory: targetDirectory)"))
        XCTAssertTrue(source.contains(
            "JsBaoCodegenInputs.arguments(inputs: configured, outputDirectory: outputDir)\n"
                + "                    + knownTypes,"))
    }
}

// MARK: - Mirrored from Plugins/JsBaoCodegenPlugin/JsBaoCodegenPlugin.swift
//
// Copy: `testPluginSourceMatchesTheMirror` compares this region's code (comment
// and blank lines left out) with the plugin source's. Keep the marker comments
// exactly as they are.

// PLUGIN-KNOWN-TYPES-MIRROR: BEGIN
/// `bao-codegen.json`'s optional `knownTypesOnly` key (#6024). `true` hands
/// the codegen tool `--known-types-only`, so the `GeneratedModels` barrel
/// carries `db3Types` and `register(on:)` turns the client's known-type
/// guard on. It sits beside the `input` or `inputs` that names the schema:
/// ```json
/// { "inputs": ["../../primitive/dev/db3-types"], "knownTypesOnly": true }
/// ```
enum JsBaoCodegenKnownTypes {

    /// The config's shape for this key alone; `JSONDecoder` reads only
    /// `true` or `false` as a `Bool`.
    private struct Shape: Decodable {
        let knownTypesOnly: Bool?
    }

    /// Whether the target's `bao-codegen.json` says `"knownTypesOnly": true`.
    /// `false` with no config file, or a config without the key. A value
    /// that is not `true` or `false` throws, naming the config: it never
    /// degrades to off. A config that cannot be read or parsed is left to
    /// the schema resolver, which throws for it.
    static func enabled(targetDirectory: URL) throws -> Bool {
        let filename = JsBaoCodegenConfig.filename
        let configURL = targetDirectory.appending(path: filename)
        let configPath = configURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: configPath),
              let data = try? Data(contentsOf: configURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = object["knownTypesOnly"]
        else { return false }
        guard let shape = try? JSONDecoder().decode(Shape.self, from: data) else {
            throw JsBaoCodegenConfigError(
                description: "\(filename) at \(configPath) has a \"knownTypesOnly\" that is not "
                    + "true or false (\(raw)); expected {\"knownTypesOnly\": true}."
            )
        }
        return shape.knownTypesOnly == true
    }

    /// The codegen tool's arguments the key adds: `--known-types-only`, or none.
    static func arguments(targetDirectory: URL) throws -> [String] {
        try enabled(targetDirectory: targetDirectory) ? ["--known-types-only"] : []
    }
}
// PLUGIN-KNOWN-TYPES-MIRROR: END
