import Foundation

// Tiny no-deps CLI flag parser. ArgumentParser would be nicer, but pulling
// in another package for a 30-line tool isn't worth the build-graph weight
// — this binary is invoked by the SwiftPM build plugin on every consumer
// build, so its dependency closure pays a recurring rebuild cost.
struct CLIArgs {
    var input: String = ""
    var output: String = ""
    var accessLevel: String = "internal"
    var moduleImport: String = "JsBaoClient"
    var swiftNameSuffix: String = "Record"

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
      --access <level>        internal | public  (default: internal)
      --module-import <name>  Module exporting PrimitiveModel/PrimitiveSchema/etc.
                              (default: JsBaoClient)
      --name-suffix <suffix>  Default suffix appended to PascalCase(model name).
                              (default: Record). Override per model with
                              [models.<name>] class_name = "..."

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
            swiftNameSuffix: args.swiftNameSuffix
        )
    } catch let err as CodegenError {
        FileHandle.standardError.write(Data("swift-bao-codegen: \(err.description)\n".utf8))
        return 1
    } catch {
        FileHandle.standardError.write(Data("swift-bao-codegen: \(error)\n".utf8))
        return 1
    }

    // Ensure output dir exists.
    let outputURL = URL(fileURLWithPath: args.output)
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

    // Emit.
    let emitter = SwiftEmitter(options: EmitOptions(
        accessLevel: args.accessLevel,
        moduleImport: args.moduleImport,
        sourcePath: inputURL.lastPathComponent
    ))

    var emittedFiles = Set<String>()
    var collisions: [String: [String]] = [:]
    for schema in schemas {
        let fileName = "\(schema.swiftName).swift"
        collisions[fileName, default: []].append(schema.name)
        emittedFiles.insert(fileName)
    }
    // Detect Swift-name collisions (two TOML models with the same
    // resolved swiftName would clobber each other).
    for (fileName, models) in collisions where models.count > 1 {
        FileHandle.standardError.write(Data(
            "swift-bao-codegen: \(fileName) would be written by multiple models: \(models.joined(separator: ", ")). Disambiguate with [models.<name>] class_name = \"...\".\n".utf8
        ))
        return 1
    }

    for schema in schemas {
        let source = emitter.emit(schema: schema)
        let fileURL = outputURL.appendingPathComponent("\(schema.swiftName).swift")
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

private func writeIfChanged(_ contents: String, to url: URL) throws {
    if let existing = try? String(contentsOf: url, encoding: .utf8),
       existing == contents {
        return
    }
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

exit(run())
