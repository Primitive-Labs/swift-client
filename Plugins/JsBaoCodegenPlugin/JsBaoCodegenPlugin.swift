import PackagePlugin
import Foundation

/// SwiftPM build tool plugin: scans the consuming target's source files
/// for `*schema.toml` files (and the JS-canonical `models.toml`, #944) and
/// runs `swift-bao-codegen` against each.
/// Output Swift files land in the plugin's per-target work directory and
/// are appended to the target's source list automatically by SwiftPM.
///
/// Wiring (consumer side):
/// ```swift
/// .target(
///   name: "MyApp",
///   dependencies: [.product(name: "JsBaoClient", package: "JsBaoClient")],
///   plugins: [.plugin(name: "JsBaoCodegenPlugin", package: "JsBaoClient")]
/// )
/// ```
///
/// Selection rule: any source file whose name ends in `schema.toml` (case
/// sensitive), or is exactly `models.toml`, is treated as input. The
/// narrow rule keeps unrelated TOML files in the target (e.g. tool
/// configs) from accidentally getting codegen'd, while `models.toml`
/// matches js-bao's `js-bao-codegen-v2` input so one shared file feeds
/// both runtimes (#944).
///
/// Schema outside the target — e.g. one `models.toml` shared with a web
/// client in a sibling directory (#2889)? Add `bao-codegen.json` at the
/// root of the target's source directory:
/// ```json
/// { "input": "../../models/models.toml" }
/// ```
/// The path resolves against the target directory (absolute paths are used
/// as-is). Several schemas — one db3 type file per kind of database the app
/// opens (#5025) — are `{ "inputs": ["<file or directory>", ...] }`, which
/// generates every model into one barrel; see `JsBaoCodegenInputs` below.
/// When the file is present it replaces the scan; when it is absent nothing
/// changes. Also `exclude: ["bao-codegen.json"]` in the target so
/// SwiftPM doesn't warn about an unhandled resource.
///
/// Why `buildCommand` (not `prebuildCommand`): modern SwiftPM rejects
/// prebuild commands that point at source-built executables ("a prebuild
/// command cannot use executables built from source"). `buildCommand`
/// requires outputs to be declared up front, so the plugin does a tiny
/// header-only scan of each `schema.toml` (no TOMLKit dependency — that
/// would balloon the plugin's build closure) to predict the generated
/// `<SwiftName>.swift` filenames the codegen tool will emit. The scan
/// has to agree with `SwiftBaoCodegen.TomlParser` on naming rules.
@main
struct JsBaoCodegenPlugin: BuildToolPlugin {

    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) async throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }

        // The tool's target name and executable product name are the same
        // string (#3560), which is what makes this lookup work under both
        // build systems: `native` resolves an in-package tool dep as a
        // product, while `swiftbuild` (SwiftPM's default from Swift 6.4 /
        // Xcode 27) paths the tool by product name but schedules the build
        // by target name. Keep this in step with `dependencies:` on the
        // plugin target in `Package.swift`.
        let tool = try context.tool(named: "swift-bao-codegen")
        let outputDir = context.pluginWorkDirectoryURL.appending(path: "GeneratedModels")

        // A `bao-codegen.json` naming the schema replaces the scan entirely
        // (#2889) — that is how a shared `models.toml` outside the target,
        // feeding a web client and this one, gets selected. An unusable
        // config throws rather than falling back to the scan, which would
        // codegen from the wrong schema.
        //
        // `target.directoryURL`, not `target.directory`: `Path` is deprecated
        // in favour of `URL`, and reading `.string` off it warned on every
        // consumer build (#2966). The URL accessor arrived in
        // PackageDescription 6.1, which is why the manifest declares
        // swift-tools-version 6.1.
        let targetDirectory = target.directoryURL

        // A configured schema list (`input`, or #5025's `inputs`: files or
        // directories) is ONE build command over every file: the tool writes
        // one barrel over all of them, and its stale-file sweep sees every
        // model. One `input` is the command it has always been. Directories
        // that hold no schema yet are handed to the tool as directories, so
        // it still writes the (empty) barrel.
        if let files = try JsBaoCodegenInputs.resolve(targetDirectory: targetDirectory) {
            let configured = files.isEmpty
                ? try JsBaoCodegenInputs.directories(targetDirectory: targetDirectory) : files
            guard !configured.isEmpty else { return [] }
            let barrel = "GeneratedModels.swift"
            let predicted = try files.map { try predictGeneratedFiles(at: $0) }
            let outputs = JsBaoCodegenInputs.outputs(predicted: predicted, barrel: barrel)
            return [.buildCommand(
                displayName: "swift-bao-codegen \(configured.map { $0.lastPathComponent }.joined(separator: ", "))",
                executable: tool.url,
                arguments: JsBaoCodegenInputs.arguments(inputs: configured, outputDirectory: outputDir),
                inputFiles: files,
                outputFiles: outputs.map { outputDir.appending(path: $0) }
            )]
        }

        // Otherwise: every `*schema.toml` in the target, plus the bare
        // `models.toml` filename js-bao's codegen reads (#944) — so a
        // single `models.toml` drives both the JS and Swift generators
        // without renaming. The `hasSuffix("schema.toml")` rule still
        // accepts `models.schema.toml`, `app.schema.toml`, etc.; the
        // explicit `models.toml` match adds the JS-canonical name.
        let inputs =
            target.sourceFiles
            .filter {
                let name = $0.url.lastPathComponent
                return name.hasSuffix("schema.toml") || name == "models.toml"
            }
            .map { $0.url }

        guard !inputs.isEmpty else { return [] }

        var commands: [Command] = []
        for input in inputs {
            // Predict the generated file names so SwiftPM can declare
            // them as outputs of the build command. The codegen tool
            // itself remains the canonical writer — this scan only has
            // to agree on which filenames will exist.
            let predicted = try predictGeneratedFiles(at: input)
            let outputs = predicted.map { outputDir.appending(path: $0) }

            commands.append(.buildCommand(
                displayName: "swift-bao-codegen \(input.lastPathComponent)",
                executable: tool.url,
                arguments: [
                    "--input", input.path(percentEncoded: false),
                    "--output", outputDir.path(percentEncoded: false),
                ],
                inputFiles: [input],
                outputFiles: outputs
            ))
        }
        return commands
    }

    // MARK: - TOML header scan

    /// Read a `schema.toml` and return the list of generated filenames
    /// (`<SwiftName>.swift`) the codegen tool will produce. Uses a
    /// minimal line scanner — TOMLKit is not available to plugins
    /// without a heavyweight dep, and we only need to identify
    /// `[models.X]` headers and any per-model `class_name` override.
    /// The scan mirrors `SwiftBaoCodegen.TomlParser` / `Naming.pascalCase`.
    private func predictGeneratedFiles(at url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)

        // Track ordered set of model names so the same TOML always
        // produces the same output list (set semantics don't care
        // about order, but we want stable build commands).
        var modelOrder: [String] = []
        var modelSeen: Set<String> = []
        var classNameByModel: [String: String] = [:]

        // We only look for `class_name = "..."` directly under
        // `[models.<name>]` (parts.count == 2). Sub-tables like
        // `[models.<name>.fields.<f>]` clear the current-model
        // pointer so a stray `class_name` inside a field's table
        // is ignored.
        var currentModel: String? = nil

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let inner = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                let parts = inner.split(separator: ".").map(String.init)

                // Need at least `models.<name>`.
                if parts.count >= 2, parts[0] == "models" {
                    let modelName = parts[1]
                    if !modelSeen.contains(modelName) {
                        modelSeen.insert(modelName)
                        modelOrder.append(modelName)
                    }
                    // Only `[models.<X>]` itself opens scope for
                    // top-level keys like `class_name`.
                    currentModel = (parts.count == 2) ? modelName : nil
                } else {
                    currentModel = nil
                }
                continue
            }

            // Inside `[models.<X>]`, harvest class_name.
            if let model = currentModel {
                if let override = parseClassNameOverride(line) {
                    classNameByModel[model] = override
                }
            }
        }

        // Resolve filenames in the same order the codegen tool emits.
        let suffix = "Record"
        var files = modelOrder.map { name -> String in
            let swiftName = classNameByModel[name] ?? (pascalCase(name) + suffix)
            return "\(swiftName).swift"
        }
        // The tool always emits a registration barrel alongside the
        // per-model files (`GeneratedModels.all` + `register(on:)`).
        // Declare it as an output so SwiftPM picks it up — keep this
        // literal in sync with `SwiftEmitter.barrelFileName`.
        files.append("GeneratedModels.swift")
        return files
    }

    /// Match `class_name = "Foo"` (single- or double-quoted, with optional
    /// whitespace). Returns the raw value if matched.
    private func parseClassNameOverride(_ line: String) -> String? {
        // Strip a trailing inline comment so `key = "val" # note` works.
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

    /// Cheap: were we inside a quoted string when we hit the `#`?
    /// Counts unescaped quote runs to the left.
    private func inQuotes(_ s: String, before idx: String.Index) -> Bool {
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

    /// Mirror of `Naming.pascalCase` in the codegen tool. Keep these in
    /// sync — divergence would mean SwiftPM declares output files that
    /// the codegen tool never writes (build error: missing output).
    private func pascalCase(_ s: String) -> String {
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

// MARK: - bao-codegen.json inputs
//
// Mirrored verbatim in Tests/SwiftBaoCodegenTests/PluginInputsHermeticTests.swift,
// which compares these bytes against its copy (`testPluginSourceMatchesTheMirror`)
// — edit both, and keep the marker comments exactly as they are.
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

// MARK: - bao-codegen.json
//
// Mirrored verbatim in Tests/SwiftBaoCodegenTests/PluginConfigHermeticTests.swift,
// because SwiftPM does not let a test target import plugin code. That file's
// `testPluginSourceMatchesTheMirror` compares these bytes against its copy, so
// edit both — and keep the marker comments exactly as they are.
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
