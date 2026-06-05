import Foundation

// Tiny no-deps CLI flag parser. ArgumentParser would be nicer, but pulling
// in another package for a 30-line tool isn't worth the build-graph weight
// — this binary is invoked by the SwiftPM build plugin on every consumer
// build, so its dependency closure pays a recurring rebuild cost.
struct CLIArgs {
    var input: String = ""
    var output: String = ""
    /// Strict/CI mode: regenerate in memory and compare against the
    /// on-disk generated files. Exit non-zero (listing the offending
    /// files) if anything differs, is missing, or is a stale leftover —
    /// without writing. Mirrors `js-bao-codegen-v2 --check` for the
    /// "is generated code up to date?" CI gate.
    var check: Bool = false
    // Default `public` so an app-side companion file can extend the
    // generated type with `public extension TodoItem { ... }` (the shape
    // the agent guide demonstrates) without hitting Swift's "public
    // modifier cannot be used in extensions that declare members on an
    // internal type" diagnostic. Pass `--access internal` to opt out.
    var accessLevel: String = "public"
    var moduleImport: String = "JsBaoClient"
    var swiftNameSuffix: String = "Record"
    /// Reject unknown TOML keys (typo'd `requierd`, stray `descroption`,
    /// …) at parse time. Default true, mirroring js-bao's
    /// `loadSchemaFromTomlString` strict mode; `--no-strict` opts into
    /// the legacy "silently drop unknown keys" behavior.
    var strict: Bool = true

    static func parse(_ argv: [String]) -> CLIArgs? {
        var a = CLIArgs()
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            switch arg {
            case "--input":
                i += 1; guard i < argv.count else { return nil }
                a.input = argv[i]
            case "--output":
                i += 1; guard i < argv.count else { return nil }
                a.output = argv[i]
            case "--access":
                i += 1; guard i < argv.count else { return nil }
                a.accessLevel = argv[i]
            case "--module-import":
                i += 1; guard i < argv.count else { return nil }
                a.moduleImport = argv[i]
            case "--name-suffix":
                i += 1; guard i < argv.count else { return nil }
                a.swiftNameSuffix = argv[i]
            case "--check":
                a.check = true
            case "--no-strict":
                a.strict = false
            case "--help", "-h":
                return nil
            default:
                FileHandle.standardError.write(Data("unknown flag: \(arg)\n".utf8))
                return nil
            }
            i += 1
        }
        if a.input.isEmpty || a.output.isEmpty { return nil }
        let allowedAccess: Set<String> = ["internal", "public"]
        if !allowedAccess.contains(a.accessLevel) {
            FileHandle.standardError.write(Data(
                "--access must be one of: internal, public\n".utf8
            ))
            return nil
        }
        return a
    }
}

func usage() {
    let text = """
    swift-bao-codegen — generate Swift PrimitiveModel structs from a TOML schema.

    USAGE:
      swift-bao-codegen --input <path/to/schema.toml> --output <dir> [options]

    OPTIONS:
      --input <file>          Input TOML schema (required)
      --output <dir>          Output directory; one .swift file per [models.X] (required)
      --access <level>        internal | public  (default: public)
      --module-import <name>  Module exporting PrimitiveModel/PrimitiveSchema/etc.
                              (default: JsBaoClient)
      --name-suffix <suffix>  Default suffix appended to PascalCase(model name).
                              (default: Record). Override per model with
                              [models.<name>] class_name = "..."
      --check                 Don't write. Regenerate in memory and compare
                              against the on-disk generated files; exit non-zero
                              (listing stale/missing/changed files) if they
                              differ. For CI "is generated code up to date?".
      --no-strict             Don't reject unknown TOML keys. By default (strict)
                              an unknown key at the model / field / relationship /
                              unique-constraint level fails codegen, mirroring
                              js-bao's tomlLoader. Pass this for legacy lenient
                              parsing (unknown keys silently dropped).

    Each run also emits a `GeneratedModels.swift` registration barrel that
    aggregates every model (`GeneratedModels.all` + `register(on:)`).

    Generated files have a header banner; running again only writes a file if
    its content actually changed (Xcode rebuild signals stay quiet on no-op).
    """
    print(text)
}

@discardableResult
func run() -> Int32 {
    guard let args = CLIArgs.parse(CommandLine.arguments) else {
        usage()
        return 2
    }

    // Read TOML.
    let inputURL = URL(fileURLWithPath: args.input)
    let tomlString: String
    do {
        tomlString = try String(contentsOf: inputURL, encoding: .utf8)
    } catch {
        FileHandle.standardError.write(Data(
            "swift-bao-codegen: cannot read \(inputURL.path): \(error)\n".utf8
        ))
        return 1
    }

    // Parse.
    let schemas: [ParsedSchema]
    do {
        schemas = try TomlParser.parse(
            tomlString: tomlString,
            swiftNameSuffix: args.swiftNameSuffix,
            strict: args.strict
        )
    } catch let err as CodegenError {
        FileHandle.standardError.write(Data("swift-bao-codegen: \(err.description)\n".utf8))
        return 1
    } catch {
        FileHandle.standardError.write(Data("swift-bao-codegen: \(error)\n".utf8))
        return 1
    }

    let outputURL = URL(fileURLWithPath: args.output)

    // Build the cross-model name map so relationship accessors can name
    // their typed return types (`task` → `TaskRecord?`).
    var swiftNamesByModel: [String: String] = [:]
    for schema in schemas {
        swiftNamesByModel[schema.name] = schema.swiftName
    }

    let emitter = SwiftEmitter(options: EmitOptions(
        accessLevel: args.accessLevel,
        moduleImport: args.moduleImport,
        sourcePath: inputURL.lastPathComponent,
        swiftNamesByModel: swiftNamesByModel
    ))

    // Detect Swift-name collisions (two TOML models with the same
    // resolved swiftName would clobber each other) before rendering.
    var collisions: [String: [String]] = [:]
    for schema in schemas {
        collisions["\(schema.swiftName).swift", default: []].append(schema.name)
    }
    for (fileName, models) in collisions where models.count > 1 {
        FileHandle.standardError.write(Data(
            "swift-bao-codegen: \(fileName) would be written by multiple models: \(models.joined(separator: ", ")). Disambiguate with [models.<name>] class_name = \"...\".\n".utf8
        ))
        return 1
    }
    // The registration barrel uses a fixed filename — reject a model
    // whose resolved Swift name would collide with it.
    if collisions[SwiftEmitter.barrelFileName] != nil {
        FileHandle.standardError.write(Data(
            "swift-bao-codegen: a model resolves to the reserved barrel filename \(SwiftEmitter.barrelFileName). Disambiguate with [models.<name>] class_name = \"...\".\n".utf8
        ))
        return 1
    }

    // Render every output (model files + registration barrel) in memory,
    // in a stable order, before touching disk. `--check` compares this
    // against on-disk; the normal path writes it.
    var rendered: [(fileName: String, source: String)] = []
    for schema in schemas {
        rendered.append(("\(schema.swiftName).swift", emitter.emit(schema: schema)))
    }
    // The barrel is emitted even for an empty schema list — registering
    // zero models is harmless, and a consumer can reference
    // `GeneratedModels.all` unconditionally.
    rendered.append((SwiftEmitter.barrelFileName, emitter.emitBarrel(schemas: schemas)))
    let emittedFiles = Set(rendered.map(\.fileName))

    // --check: regenerate in memory, compare to disk, never write.
    if args.check {
        return runCheck(rendered: rendered, emittedFiles: emittedFiles, outputURL: outputURL)
    }

    // Ensure output dir exists.
    do {
        try FileManager.default.createDirectory(
            at: outputURL, withIntermediateDirectories: true
        )
    } catch {
        FileHandle.standardError.write(Data(
            "swift-bao-codegen: cannot create \(outputURL.path): \(error)\n".utf8
        ))
        return 1
    }

    for (fileName, source) in rendered {
        let fileURL = outputURL.appendingPathComponent(fileName)
        do {
            try writeIfChanged(source, to: fileURL)
        } catch {
            FileHandle.standardError.write(Data(
                "swift-bao-codegen: cannot write \(fileURL.path): \(error)\n".utf8
            ))
            return 1
        }
    }

    // Sweep: remove stale .swift files in the output dir that we didn't
    // emit on this run. Only sweeps files that look like ours (start with
    // the generated header), so we never delete user-authored neighbors
    // that happen to live in the same directory.
    do {
        let existing = try FileManager.default.contentsOfDirectory(
            at: outputURL, includingPropertiesForKeys: nil
        )
        for url in existing where url.pathExtension == "swift" {
            if emittedFiles.contains(url.lastPathComponent) { continue }
            if let contents = try? String(contentsOf: url, encoding: .utf8),
               contents.hasPrefix("// Generated by swift-bao-codegen") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    } catch {
        // A stat failure on the output dir isn't fatal — emitting succeeded.
    }

    return 0
}

/// Strict/CI comparison: for each would-be output, diff it against the
/// on-disk file (missing / differs), and flag any owned-but-unexpected
/// generated file still on disk (stale). Writes nothing. Returns 0 when
/// every file is up to date, 1 otherwise (after listing the offenders on
/// stderr). Mirrors `js-bao-codegen-v2 --check`.
private func runCheck(
    rendered: [(fileName: String, source: String)],
    emittedFiles: Set<String>,
    outputURL: URL
) -> Int32 {
    var mismatches: [(file: String, reason: String)] = []

    for (fileName, expected) in rendered {
        let fileURL = outputURL.appendingPathComponent(fileName)
        let actual = try? String(contentsOf: fileURL, encoding: .utf8)
        if actual == nil {
            mismatches.append((fileName, "missing"))
        } else if actual != expected {
            mismatches.append((fileName, "differs"))
        }
    }

    // Owned-but-unexpected generated files left on disk count as stale —
    // catches a model dropped from the TOML without re-running codegen.
    if let existing = try? FileManager.default.contentsOfDirectory(
        at: outputURL, includingPropertiesForKeys: nil
    ) {
        for url in existing where url.pathExtension == "swift" {
            if emittedFiles.contains(url.lastPathComponent) { continue }
            if let contents = try? String(contentsOf: url, encoding: .utf8),
               contents.hasPrefix("// Generated by swift-bao-codegen") {
                mismatches.append((url.lastPathComponent, "stale"))
            }
        }
    }

    if mismatches.isEmpty {
        return 0
    }

    var msg = "swift-bao-codegen: --check failed: \(mismatches.count) file(s) out of date.\n"
    for m in mismatches.sorted(by: { $0.file < $1.file }) {
        msg += "  \(m.reason): \(m.file)\n"
    }
    msg += "Re-run swift-bao-codegen (without --check) to regenerate.\n"
    FileHandle.standardError.write(Data(msg.utf8))
    return 1
}

private func writeIfChanged(_ contents: String, to url: URL) throws {
    if let existing = try? String(contentsOf: url, encoding: .utf8),
       existing == contents {
        return
    }
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

exit(run())
