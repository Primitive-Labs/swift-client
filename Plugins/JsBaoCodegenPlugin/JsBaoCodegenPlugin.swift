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
/// both runtimes (#944). Need to use a different filename? Pass `--input`
/// via a custom plugin or a build-phase script — the plugin is meant for
/// the common case.
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

        // Look up by the executable *target* name (matches the plugin's
        // `dependencies: ["SwiftBaoCodegen"]` in `Package.swift`). The
        // product name `swift-bao-codegen` doesn't resolve here because
        // SwiftPM only allows tools that appear in the plugin's
        // dependency list.
        let tool = try context.tool(named: "SwiftBaoCodegen")
        let outputDir = context.pluginWorkDirectory.appending("GeneratedModels")

        // Find every `*schema.toml` in the target, plus the bare
        // `models.toml` filename js-bao's codegen reads (#944) — so a
        // single `models.toml` drives both the JS and Swift generators
        // without renaming. The `hasSuffix("schema.toml")` rule still
        // accepts `models.schema.toml`, `app.schema.toml`, etc.; the
        // explicit `models.toml` match adds the JS-canonical name.
        let inputs = target.sourceFiles
            .filter {
                let name = $0.path.lastComponent
                return name.hasSuffix("schema.toml") || name == "models.toml"
            }
            .map { $0.path }

        guard !inputs.isEmpty else { return [] }

        var commands: [Command] = []
        for input in inputs {
            // Predict the generated file names so SwiftPM can declare
            // them as outputs of the build command. The codegen tool
            // itself remains the canonical writer — this scan only has
            // to agree on which filenames will exist.
            let predicted = try predictGeneratedFiles(at: input)
            let outputs = predicted.map { outputDir.appending($0) }

            commands.append(.buildCommand(
                displayName: "swift-bao-codegen \(input.lastComponent)",
                executable: tool.path,
                arguments: [
                    "--input", input.string,
                    "--output", outputDir.string,
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
    private func predictGeneratedFiles(at path: Path) throws -> [String] {
        let url = URL(fileURLWithPath: path.string)
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
