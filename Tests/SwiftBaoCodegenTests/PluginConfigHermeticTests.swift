import Foundation
import XCTest

/// The SwiftPM build-tool plugin must accept an explicit schema path (#2889).
///
/// One Primitive app with two clients — a web tree and a Swift tree in
/// sibling directories — needs exactly ONE `models.toml`, because the TOML
/// keys are wire field names and a drifting second copy orphans the other
/// client's records. The plugin used to discover its input only by scanning
/// `target.sourceFiles` for a file NAMED `models.toml`, so the schema had to
/// live inside the SwiftPM target; the only working arrangement was a
/// symlink, which does not survive a checkout on a filesystem without
/// symlink support. An optional `bao-codegen.json` at the root of the
/// target's source directory now names the schema instead.
///
/// **Why this file mirrors the plugin:** SwiftPM does not allow plugin code
/// to be imported by a test target, so the plugin's config helper is copied
/// verbatim at the bottom of this file, between the `PLUGIN-CONFIG-MIRROR`
/// markers — the same trade-off `PluginScannerTests` documents. Unlike that
/// file, the copy here is not on the honor system:
/// `testPluginSourceMatchesTheMirror` reads
/// `Plugins/JsBaoCodegenPlugin/JsBaoCodegenPlugin.swift` off disk and fails
/// if the two regions differ by one byte. **If you change the plugin's
/// config helper, paste the new version below.**
///
/// Hermetic: temporary directories and source files, no toolchain, no server.
final class PluginConfigHermeticTests: XCTestCase {

    // MARK: - Sandbox helpers

    private static let sampleToml = """
        [models.tasks]
        [models.tasks.fields.id]
        type = "id"
        """

    /// `<tmp>/<uuid>/Sources/MyApp` (the "target directory"), with a shared
    /// schema at `<tmp>/<uuid>/models/models.toml` — outside the target, the
    /// layout the issue describes.
    private func makeSandbox() throws -> (root: URL, targetDir: URL, sharedSchema: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "js-bao-2889-\(UUID().uuidString)")
        let targetDir = root.appending(path: "Sources/MyApp")
        let schemaDir = root.appending(path: "models")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: schemaDir, withIntermediateDirectories: true)
        let schema = schemaDir.appending(path: "models.toml")
        try Self.sampleToml.write(to: schema, atomically: true, encoding: .utf8)
        addTeardownBlock { try? fileManager.removeItem(at: root) }
        return (root, targetDir, schema)
    }

    private func writeConfig(_ json: String, in targetDir: URL) throws {
        try json.write(
            to: targetDir.appending(path: JsBaoCodegenConfig.filename),
            atomically: true,
            encoding: .utf8)
    }

    /// Run `resolveInput` expecting a throw, and return the error's message.
    private func messageFromFailure(
        targetDir: URL, file: StaticString = #filePath, line: UInt = #line
    ) -> String {
        do {
            let resolved = try JsBaoCodegenConfig.resolveInput(targetDirectory: targetDir)
            XCTFail(
                "expected a thrown error, got \(String(describing: resolved))",
                file: file, line: line)
            return ""
        } catch let error as JsBaoCodegenConfigError {
            return error.description
        } catch {
            XCTFail("expected JsBaoCodegenConfigError, got \(error)", file: file, line: line)
            return ""
        }
    }

    private func standardPath(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }

    // MARK: - Resolution

    func testRelativeInputEscapingTheTarget_resolvesAgainstTheTargetDirectory() throws {
        let box = try makeSandbox()
        try writeConfig(#"{ "input": "../../models/models.toml" }"#, in: box.targetDir)

        let resolved = try JsBaoCodegenConfig.resolveInput(targetDirectory: box.targetDir)

        XCTAssertEqual(
            resolved.map(standardPath), standardPath(box.sharedSchema),
            "a relative input resolves against the target directory, so a schema "
                + "outside the package is reachable")
    }

    func testAbsoluteInput_isUsedAsIs() throws {
        let box = try makeSandbox()
        let absolute = standardPath(box.sharedSchema)
        try writeConfig("{ \"input\": \"\(absolute)\" }", in: box.targetDir)

        let resolved = try JsBaoCodegenConfig.resolveInput(targetDirectory: box.targetDir)

        XCTAssertEqual(resolved.map(standardPath), absolute)
    }

    func testInputInsideTheTarget_stillWorks() throws {
        let box = try makeSandbox()
        let inside = box.targetDir.appending(path: "models.toml")
        try Self.sampleToml.write(to: inside, atomically: true, encoding: .utf8)
        try writeConfig(#"{ "input": "models.toml" }"#, in: box.targetDir)

        let resolved = try JsBaoCodegenConfig.resolveInput(targetDirectory: box.targetDir)

        XCTAssertEqual(
            resolved.map(standardPath), standardPath(inside),
            "the config replaces the scan; the same file is selected either way")
    }

    func testNoConfigFile_returnsNilSoTheScanGoverns() throws {
        let box = try makeSandbox()

        XCTAssertNil(
            try JsBaoCodegenConfig.resolveInput(targetDirectory: box.targetDir),
            "with no config the plugin must fall back to its filename scan, unchanged")
    }

    // MARK: - Loud failures (never a silent fallback to the scan)

    func testMissingResolvedFile_namesTheConfigAndTheResolvedPath() throws {
        let box = try makeSandbox()
        try writeConfig(#"{ "input": "../../models/nope.toml" }"#, in: box.targetDir)

        let message = messageFromFailure(targetDir: box.targetDir)

        XCTAssertTrue(message.contains(JsBaoCodegenConfig.filename), message)
        XCTAssertTrue(
            message.contains(
                standardPath(
                    box.sharedSchema.deletingLastPathComponent().appending(path: "nope.toml"))),
            message)
    }

    func testMalformedJson_throwsNamingTheConfig() throws {
        let box = try makeSandbox()
        try writeConfig("{ \"input\": ", in: box.targetDir)

        XCTAssertTrue(
            messageFromFailure(targetDir: box.targetDir).contains(JsBaoCodegenConfig.filename))
    }

    func testMissingInputKey_throwsNamingTheConfig() throws {
        let box = try makeSandbox()
        try writeConfig(#"{ "output": "Generated" }"#, in: box.targetDir)

        let message = messageFromFailure(targetDir: box.targetDir)
        XCTAssertTrue(message.contains(JsBaoCodegenConfig.filename), message)
        XCTAssertTrue(message.contains("input"), message)
    }

    func testEmptyInput_throwsNamingTheConfig() throws {
        let box = try makeSandbox()
        try writeConfig(#"{ "input": "   " }"#, in: box.targetDir)

        let message = messageFromFailure(targetDir: box.targetDir)
        XCTAssertTrue(message.contains(JsBaoCodegenConfig.filename), message)
        XCTAssertTrue(message.lowercased().contains("empty"), message)
    }

    func testNonStringInput_throwsNamingTheConfig() throws {
        let box = try makeSandbox()
        try writeConfig(#"{ "input": 42 }"#, in: box.targetDir)

        XCTAssertTrue(
            messageFromFailure(targetDir: box.targetDir).contains(JsBaoCodegenConfig.filename))
    }

    func testInputsArray_saysExactlyOneInputIsSupported() throws {
        let box = try makeSandbox()
        try writeConfig(#"{ "inputs": ["../../models/models.toml"] }"#, in: box.targetDir)

        let message = messageFromFailure(targetDir: box.targetDir)
        XCTAssertTrue(message.contains(JsBaoCodegenConfig.filename), message)
        XCTAssertTrue(message.contains("exactly"), message)
        XCTAssertTrue(message.contains("\"input\""), message)
    }

    // MARK: - Mirror drift guard

    private static let mirrorBegin = "// PLUGIN-CONFIG-MIRROR: BEGIN"
    private static let mirrorEnd = "// PLUGIN-CONFIG-MIRROR: END"

    /// `#filePath` is this file under `swift-client/Tests/SwiftBaoCodegenTests/`.
    private var pluginSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SwiftBaoCodegenTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // swift-client
            .appending(path: "Plugins/JsBaoCodegenPlugin/JsBaoCodegenPlugin.swift")
    }

    /// The lines strictly between the marker LINES. Matching whole lines (not
    /// substrings) keeps the two marker constants just above from being
    /// mistaken for the markers themselves.
    private func mirroredRegion(
        of text: String, source: String, file: StaticString = #filePath, line: UInt = #line
    ) -> [String] {
        let lines = text.components(separatedBy: "\n")
        let markerIndex = { (marker: String) -> Int? in
            lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == marker }
        }
        guard let begin = markerIndex(Self.mirrorBegin), let end = markerIndex(Self.mirrorEnd),
            begin < end
        else {
            XCTFail("no PLUGIN-CONFIG-MIRROR region in \(source)", file: file, line: line)
            return []
        }
        return Array(lines[(begin + 1)..<end])
    }

    func testPluginSourceMatchesTheMirror() throws {
        let pluginSource = try String(contentsOf: pluginSourceURL, encoding: .utf8)
        let thisSource = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)

        let plugin = mirroredRegion(of: pluginSource, source: "JsBaoCodegenPlugin.swift")
        let mirror = mirroredRegion(of: thisSource, source: "this test file")

        // The mirror below is ~100 lines; an empty region means the markers
        // moved, not that the helper is trivially in sync.
        XCTAssertGreaterThan(mirror.count, 50)

        let drift = "the plugin's config helper and the mirror below have drifted — paste "
            + "the plugin's version between the PLUGIN-CONFIG-MIRROR markers"
        // Report the first differing line rather than dumping both copies.
        if let offset = zip(plugin, mirror).enumerated().first(where: { $0.element.0 != $0.element.1 }
        )?.offset {
            XCTFail(
                "\(drift)\n  line \(offset + 1) in plugin: \(plugin[offset])"
                    + "\n  line \(offset + 1) in mirror: \(mirror[offset])")
        }
        XCTAssertEqual(plugin.count, mirror.count, drift)
    }

    func testPluginConsultsTheConfigBeforeScanning() throws {
        let pluginSource = try String(contentsOf: pluginSourceURL, encoding: .utf8)

        // How the target's directory URL is spelled is the plugin's business
        // (PackagePlugin's URL accessors are tools-version gated); that it
        // asks the config first is not.
        XCTAssertTrue(
            pluginSource.contains("JsBaoCodegenConfig.resolveInput(targetDirectory:"),
            "the plugin must consult bao-codegen.json before falling back to its scan")
    }
}

// MARK: - Mirrored from Plugins/JsBaoCodegenPlugin/JsBaoCodegenPlugin.swift
//
// Verbatim copy: `testPluginSourceMatchesTheMirror` compares these bytes
// against the plugin source. Keep the marker comments exactly as they are.

// PLUGIN-CONFIG-MIRROR: BEGIN
/// Error thrown when a `bao-codegen.json` exists but cannot be honored.
/// The plugin fails the build instead of falling back to the filename
/// scan — a silent fallback would generate against the wrong schema.
struct JsBaoCodegenConfigError: Error, CustomStringConvertible {
    let description: String
}

/// Optional per-target codegen configuration: `bao-codegen.json` at the
/// root of the target's source directory, shape `{ "input": "<path>" }`.
///
/// It exists so one shared `models.toml` can live OUTSIDE the SwiftPM
/// target (#2889): a web client and a Swift client in sibling directories
/// must read the same schema file, because the TOML keys are wire field
/// names and a second copy that drifts orphans the other client's records.
///
/// Exactly one input, deliberately: every build command the plugin emits
/// writes into a single `GeneratedModels` directory, where the codegen tool
/// emits one barrel and sweeps generated files it did not write on that
/// run. Two schemas in one target would delete each other's output.
enum JsBaoCodegenConfig {

    /// Config filename, looked up directly on disk rather than through
    /// `target.sourceFiles` so consumers can `exclude:` it from the target.
    static let filename = "bao-codegen.json"

    /// Resolve the configured schema for a target's source directory.
    ///
    /// Returns `nil` only when no config file exists — the caller then falls
    /// back to the `*schema.toml` / `models.toml` scan. A config that exists
    /// but is unusable throws; it never degrades to the scan.
    static func resolveInput(targetDirectory: URL) throws -> URL? {
        let configURL = targetDirectory.appending(path: filename)
        let configPath = configURL.path(percentEncoded: false)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: configPath) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw JsBaoCodegenConfigError(
                description: "\(filename) at \(configPath) could not be read: \(error)"
            )
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw JsBaoCodegenConfigError(
                description: "\(filename) at \(configPath) is not valid JSON: "
                    + "\(error.localizedDescription)"
            )
        }

        guard let object = parsed as? [String: Any] else {
            throw JsBaoCodegenConfigError(
                description: "\(filename) at \(configPath) must be a JSON object "
                    + "of the form {\"input\": \"<path>\"}."
            )
        }

        // Caught explicitly: an `inputs` array is the obvious guess, and
        // silently ignoring it would codegen from the wrong schema.
        if object["inputs"] != nil {
            throw JsBaoCodegenConfigError(
                description: "\(filename) at \(configPath) uses \"inputs\"; exactly "
                    + "one \"input\" is supported per target, because the plugin "
                    + "routes every schema into one GeneratedModels directory whose "
                    + "barrel and stale-file sweep cannot host two schemas."
            )
        }

        guard let rawInput = object["input"] else {
            throw JsBaoCodegenConfigError(
                description: "\(filename) at \(configPath) is missing the required "
                    + "\"input\" key; expected {\"input\": \"<path>\"}."
            )
        }

        guard let inputPath = rawInput as? String else {
            throw JsBaoCodegenConfigError(
                description: "\(filename) at \(configPath) has a non-string \"input\" "
                    + "(\(rawInput)); expected a path to a schema TOML."
            )
        }

        let trimmed = inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw JsBaoCodegenConfigError(
                description: "\(filename) at \(configPath) has an empty \"input\"; "
                    + "expected a path to a schema TOML."
            )
        }

        // Relative paths resolve against the target directory, so
        // "../../models/models.toml" reaches a shared schema outside the
        // package; absolute paths are used as-is.
        //
        // The base is rebuilt with `isDirectory: true`: relative resolution
        // drops the base's last component unless the URL is known to be a
        // directory, which would silently shift every `../` up one level.
        let baseDirectory = URL(
            fileURLWithPath: targetDirectory.path(percentEncoded: false), isDirectory: true)
        let resolved =
            trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed).standardizedFileURL
            : URL(fileURLWithPath: trimmed, relativeTo: baseDirectory).standardizedFileURL

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(
            atPath: resolved.path(percentEncoded: false), isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue else {
            throw JsBaoCodegenConfigError(
                description: "\(filename) at \(configPath) names input \"\(trimmed)\", "
                    + "which resolves to \(resolved.path(percentEncoded: false)) — "
                    + "no such file."
            )
        }

        return resolved
    }
}
// PLUGIN-CONFIG-MIRROR: END
