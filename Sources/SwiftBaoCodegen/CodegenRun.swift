import Foundation

/// One schema input: its path, the name generated headers give it (its
/// basename) and its contents.
struct CodegenInput {
    var path: String
    var sourceName: String
    var source: String
}

/// The files `--input` names (#5025): each a TOML file, or a directory
/// contributing every `*.toml` directly inside it, in name order.
enum CodegenInputs {

    /// The input files, in order. A directory contributes the `*.toml` files
    /// directly inside it, sorted by name; subdirectories and other files are
    /// ignored. A file named twice is read once, at its first position.
    static func expand(_ inputs: [String]) throws -> [String] {
        let fileManager = FileManager.default
        var files: [String] = []
        var seen: Set<String> = []
        for input in inputs {
            let url = URL(fileURLWithPath: input).standardizedFileURL
            let path = url.path(percentEncoded: false)
            var isDirectory: ObjCBool = false
            var members = [path]
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                members = try fileManager.contentsOfDirectory(atPath: path)
                    .filter { $0.hasSuffix(".toml") }
                    .sorted()
                    .map { url.appending(path: $0).path(percentEncoded: false) }
                    .filter {
                        var memberIsDirectory: ObjCBool = false
                        return fileManager.fileExists(atPath: $0, isDirectory: &memberIsDirectory)
                            && !memberIsDirectory.boolValue
                    }
            }
            for member in members where seen.insert(member).inserted {
                files.append(member)
            }
        }
        return files
    }

    /// Read each file, named by its basename.
    static func read(_ paths: [String]) throws -> [CodegenInput] {
        try paths.map { path in
            let url = URL(fileURLWithPath: path)
            return CodegenInput(
                path: path,
                sourceName: url.lastPathComponent,
                source: try String(contentsOf: url, encoding: .utf8)
            )
        }
    }
}

/// Everything one `swift-bao-codegen` run writes, rendered in memory: one
/// file per model over every input, then the registration barrel. Pure, so
/// `--check` and the hermetic tests read exactly what a run writes.
enum CodegenRun {

    /// Render `documents` (each a file's basename and contents). A model's
    /// file names the input that declared it; the barrel names every input,
    /// or `emptyLabel` when there is none. For one input the output is what
    /// a single `--input` has always written.
    static func render(
        documents: [(sourceName: String, source: String)],
        emptyLabel: String,
        accessLevel: String,
        moduleImport: String,
        swiftNameSuffix: String,
        strict: Bool
    ) throws -> [(fileName: String, source: String)] {
        // An authoring door, like js-bao-codegen-v2: a field name that
        // breaks a generated model on either client is refused here.
        let schemas = try TomlParser.parseAll(
            documents: documents,
            swiftNameSuffix: swiftNameSuffix,
            strict: strict,
            rejectReservedFieldNames: true
        )

        // Detect Swift-name collisions (two TOML models with the same
        // resolved swiftName would clobber each other) before rendering.
        var modelsByFile: [String: [String]] = [:]
        var fileOrder: [String] = []
        for schema in schemas {
            let fileName = "\(schema.swiftName).swift"
            if modelsByFile[fileName] == nil { fileOrder.append(fileName) }
            modelsByFile[fileName, default: []].append(schema.name)
        }
        for fileName in fileOrder where modelsByFile[fileName]!.count > 1 {
            throw CodegenError.swiftNameCollision(fileName: fileName, models: modelsByFile[fileName]!)
        }
        // The registration barrel uses a fixed filename — reject a model
        // whose resolved Swift name would collide with it.
        if modelsByFile[SwiftEmitter.barrelFileName] != nil {
            throw CodegenError.reservedBarrelName(fileName: SwiftEmitter.barrelFileName)
        }

        // The cross-model name map lets relationship accessors name their
        // typed return types (`task` → `TaskRecord?`), across every input.
        var options = EmitOptions(
            accessLevel: accessLevel,
            moduleImport: moduleImport,
            sourcePath: "",
            swiftNamesByModel: Dictionary(uniqueKeysWithValues: schemas.map { ($0.name, $0.swiftName) })
        )
        var rendered: [(fileName: String, source: String)] = []
        for schema in schemas {
            options.sourcePath = schema.sourceName
            rendered.append(("\(schema.swiftName).swift", SwiftEmitter(options: options).emit(schema: schema)))
        }
        // The barrel is emitted even for an empty schema list — registering
        // zero models is harmless, and a consumer can reference
        // `GeneratedModels.all` unconditionally.
        options.sourcePath = documents.isEmpty
            ? emptyLabel
            : documents.map(\.sourceName).joined(separator: ", ")
        rendered.append((SwiftEmitter.barrelFileName, SwiftEmitter(options: options).emitBarrel(schemas: schemas)))
        return rendered
    }
}
