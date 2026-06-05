import XCTest

/// **Codegen-output parity.**
///
/// The end-to-end harness in `E2EQueryParityTests` proves that records
/// round-trip across the Swift/JS boundary when both sides drive
/// CRUD/query through their respective codegen tools. This file
/// proves the *artifact* layer underneath: given the same TOML, do
/// `swift-bao-codegen` and `js-bao-codegen-v2` agree on which models
/// exist, which fields they have, and which relationships they
/// expose?
///
/// What this test pins:
///   1. **Class-name parity.** Each `[models.X]` produces exactly one
///      generated source file on each side, and the file names line
///      up — Swift's `<ClassName>.swift` ↔ TS's
///      `<ClassName>.generated.ts`. The schema.toml carries an
///      explicit `class_name = "..."` on every model so both codegens
///      land on the same name; this test enforces it.
///   2. **Field-set parity.** Every TOML field declared under
///      `[models.X.fields.Y]` shows up in both generated artifacts.
///      Swift emits stored properties + a `FieldDescriptor` entry;
///      TS emits an `<Attrs>` interface property + an interface
///      method on the declaration-merged class type.
///   3. **Relationship-name parity.** Every `[models.X.relationships.R]`
///      becomes an accessor on both sides. Swift records it via a
///      `RelationshipDescriptor` literal; TS via an interface method
///      signature on `<Name>`.
///   4. **Visible side-by-side.** Both generated files are attached to
///      the test result via `XCTAttachment` so the human reading the
///      test report can compare them line-by-line without re-running
///      the codegens.
///
/// What this test does NOT try to assert:
///   - Byte equality of generated content. The two languages emit
///     fundamentally different shapes (Swift: full struct with init/
///     ser/deser; TS: empty class shell + declaration-merged
///     interface + barrel-driven runtime registration). Insisting on
///     byte equality would force one language to mimic the other.
///   - Type-level fidelity. Swift's `Double?` vs TS's `number?` are
///     equivalent at the schema layer; this test treats type strings
///     opaquely and only checks set membership.
///
/// Skipped if either codegen binary is missing (e.g. `swift build` or
/// `pnpm install` hasn't run).
final class CodegenOutputParityTests: XCTestCase {

    /// Models we expect both codegens to produce, with the explicit
    /// class names declared in `schema.toml`. Drift this list (or
    /// the TOML) and the test fails — that's the gate keeping the
    /// two codegens in lockstep.
    private static let expectedModels: [(toml: String, className: String)] = [
        ("tasks",          "TaskRecord"),
        ("everything",     "Everything"),
        ("users",          "User"),
        ("posts",          "Post"),
        ("tags",           "Tag"),
        ("post_tag_links", "PostTagLink"),
    ]

    /// Per-model field set that should be present on BOTH sides.
    /// Keys match the TOML key under `[models.<name>.fields.<field>]`.
    private static let expectedFields: [String: Set<String>] = [
        "tasks":          ["id", "title", "priority", "completed", "tags", "createdAt"],
        "everything":     ["id", "label", "intSmall", "intLarge", "floatPrecise",
                           "floatNeg", "flag", "textChinese", "textEmoji",
                           "textSpecial", "tsZ", "tsOffset", "tsFractional", "tags"],
        "users":          ["id", "name"],
        "posts":          ["id", "title", "userId", "createdAt"],
        "tags":           ["id", "name"],
        "post_tag_links": ["id", "postId", "tagId"],
    ]

    /// Per-model relationship names that should appear on BOTH sides.
    /// Empty for models with no relationships (everything, tasks,
    /// tags, post_tag_links).
    private static let expectedRelationships: [String: Set<String>] = [
        "tasks":          [],
        "everything":     [],
        "users":          ["posts"],
        "posts":          ["author", "tags"],
        "tags":           [],
        "post_tag_links": [],
    ]

    // MARK: - The single big test

    /// Run both codegens against the same shared schema.toml, then
    /// assert structural parity for every expected model. This is one
    /// fat test on purpose — the fixture cost is identical for one
    /// vs. many assertions, and a single test result keeps the
    /// XCTAttachment dump readable end-to-end.
    func testCodegenOutputParityForSharedSchema() throws {
        let schemaURL = sharedSchemaURL()

        // 1. Run the Swift codegen against a temp output dir.
        let swiftOutDir = try makeTempDir(prefix: "swift-codegen")
        try runSwiftCodegen(input: schemaURL, output: swiftOutDir)

        // 2. Run the TS codegen. v2's barrel hard-codes
        //    `import "./<basename>?raw"`, so the schema must sit
        //    beside the generated index.ts. We copy the TOML into the
        //    output dir before invoking.
        let tsOutDir = try makeTempDir(prefix: "ts-codegen")
        let tsSchemaCopy = tsOutDir.appendingPathComponent("schema.toml")
        try FileManager.default.copyItem(at: schemaURL, to: tsSchemaCopy)
        try runTsCodegen(input: tsSchemaCopy, output: tsOutDir)

        // 3. Attach every generated file to the test result so the
        //    human reviewing this test sees exactly what each side
        //    emitted, side by side.
        try attachGeneratedFiles(dir: swiftOutDir, namePrefix: "[swift]")
        try attachGeneratedFiles(dir: tsOutDir,    namePrefix: "[typescript]")

        // 4. Class-name parity: every expected model has exactly one
        //    generated file on each side, named after the resolved
        //    class name.
        let swiftFiles = try listFiles(in: swiftOutDir, ext: ".swift")
        let tsFiles    = try listFiles(in: tsOutDir,    ext: ".generated.ts")

        // The Swift codegen also emits a `GeneratedModels.swift`
        // registration barrel (the analogue of the TS `index.ts`, which
        // the `.generated.ts` filter above already excludes). Drop it
        // before the one-file-per-model comparison.
        let swiftModelFiles = swiftFiles
            .map { $0.lastPathComponent }
            .filter { $0 != "GeneratedModels.swift" }

        XCTAssertEqual(
            Set(swiftModelFiles),
            Set(Self.expectedModels.map { "\($0.className).swift" }),
            "Swift codegen should produce one <ClassName>.swift per model"
        )
        XCTAssertEqual(
            Set(tsFiles.map { $0.lastPathComponent }),
            Set(Self.expectedModels.map { "\($0.className).generated.ts" }),
            "TS codegen should produce one <ClassName>.generated.ts per model"
        )

        // 5. Per-model: field-set parity + relationship-name parity.
        for (toml, className) in Self.expectedModels {
            let swiftSrc = try String(
                contentsOf: swiftOutDir.appendingPathComponent("\(className).swift"),
                encoding: .utf8
            )
            let tsSrc = try String(
                contentsOf: tsOutDir.appendingPathComponent("\(className).generated.ts"),
                encoding: .utf8
            )

            let swiftFields = extractSwiftFieldNames(from: swiftSrc)
            let tsFields = extractTsFieldNames(from: tsSrc, className: className)

            XCTAssertEqual(
                swiftFields,
                Self.expectedFields[toml],
                "[\(toml)] Swift fields don't match expected"
            )
            XCTAssertEqual(
                tsFields,
                Self.expectedFields[toml],
                "[\(toml)] TS fields don't match expected"
            )
            XCTAssertEqual(
                swiftFields,
                tsFields,
                "[\(toml)] Swift and TS field sets diverge — codegens drifted"
            )

            let swiftRels = extractSwiftRelationshipNames(from: swiftSrc)
            let tsRels = extractTsRelationshipNames(from: tsSrc, className: className)

            XCTAssertEqual(
                swiftRels,
                Self.expectedRelationships[toml],
                "[\(toml)] Swift relationship names don't match expected"
            )
            XCTAssertEqual(
                tsRels,
                Self.expectedRelationships[toml],
                "[\(toml)] TS relationship names don't match expected"
            )
            XCTAssertEqual(
                swiftRels,
                tsRels,
                "[\(toml)] Swift and TS relationship name sets diverge"
            )
        }

        // 6. TS barrel sanity: the v2-emitted `index.ts` should list
        //    every class in `_modelPairs`. The Swift side has no
        //    barrel — `static let primitiveSchema` is baked into
        //    each struct.
        let tsBarrel = try String(
            contentsOf: tsOutDir.appendingPathComponent("index.ts"),
            encoding: .utf8
        )
        for (toml, className) in Self.expectedModels {
            XCTAssertTrue(
                tsBarrel.contains("modelName: \"\(toml)\", class: \(className)"),
                "TS barrel missing pair for \(toml) → \(className)"
            )
        }
    }

    // MARK: - Codegen runners

    private func runSwiftCodegen(input: URL, output: URL) throws {
        let bin = try locateSwiftCodegenBinary()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["--input", input.path, "--output", output.path]
        let stderr = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTFail("swift-bao-codegen exit \(proc.terminationStatus): \(err)")
            throw NSError(domain: "swift-bao-codegen", code: Int(proc.terminationStatus))
        }
    }

    private func runTsCodegen(input: URL, output: URL) throws {
        let nodePath = try CrossPlatformHarness.nodePath()
        let bin = try locateTsCodegenBinary()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [
            bin, "generate",
            "--input", input.path,
            "--output", output.path,
        ]
        let stderr = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTFail("js-bao-codegen-v2 exit \(proc.terminationStatus): \(err)")
            throw NSError(domain: "js-bao-codegen-v2", code: Int(proc.terminationStatus))
        }
    }

    // MARK: - Binary lookup

    /// `swift-bao-codegen` is built at `.build/<arch>/<config>/SwiftBaoCodegen`.
    /// We scan the build dir for the binary so the test works under both
    /// `swift build` (default arch) and `swift test` (which builds debug).
    private func locateSwiftCodegenBinary() throws -> String {
        let swiftClientRoot = Self.swiftClientRoot
        let buildDir = swiftClientRoot.appendingPathComponent(".build")
        for config in ["debug", "release"] {
            let direct = buildDir
                .appendingPathComponent(config)
                .appendingPathComponent("SwiftBaoCodegen")
            if FileManager.default.isExecutableFile(atPath: direct.path) {
                return direct.path
            }
        }
        if let archDirs = try? FileManager.default.contentsOfDirectory(
            at: buildDir, includingPropertiesForKeys: nil
        ) {
            for archDir in archDirs {
                for config in ["debug", "release"] {
                    let candidate = archDir
                        .appendingPathComponent(config)
                        .appendingPathComponent("SwiftBaoCodegen")
                    if FileManager.default.isExecutableFile(atPath: candidate.path) {
                        return candidate.path
                    }
                }
            }
        }
        throw XCTSkip(
            "SwiftBaoCodegen binary not built. " +
            "Run: swift build --target SwiftBaoCodegen"
        )
    }

    /// `js-bao-codegen-v2` is shipped from the workspace's
    /// `node_modules/js-bao/dist/codegen-v2.cjs`. Walk up from this
    /// test file to find the hoisted node_modules.
    private func locateTsCodegenBinary() throws -> String {
        var dir = Self.thisDir
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent(
                "node_modules/js-bao/dist/codegen-v2.cjs"
            )
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw XCTSkip(
            "js-bao-codegen-v2 not found. Run `pnpm install` at the repo root."
        )
    }

    // MARK: - Field / relationship extractors
    //
    // These are intentionally small, regex-free string scans. They
    // know just enough about each codegen's output format to pull
    // out the field/relationship names — anything more is over-fit.
    // If a codegen's output shape changes, the extractor needs to
    // change too; that's a feature, not a bug, because the test
    // pins expected behavior across both.

    /// Swift output:
    ///   `internal static let primitiveSchema = PrimitiveSchema(`
    ///   `    name: "tasks",`
    ///   `    fields: [`
    ///   `        "id":        FieldDescriptor(...),`
    ///   `        "title":     FieldDescriptor(... required: true),`
    ///   `        ...`
    ///   `    ]...`
    ///
    /// We extract the keys inside the `fields:` literal block.
    private func extractSwiftFieldNames(from src: String) -> Set<String> {
        return extractKeysInBlock(src: src, openMarker: "fields: [")
    }

    /// TS output:
    ///   `export interface <Name>Attrs {`
    ///   `  id?: string;`
    ///   `  title: string;`
    ///   `  ...`
    ///   `}`
    ///
    /// We pull names out of the `<Name>Attrs` interface body.
    private func extractTsFieldNames(from src: String, className: String) -> Set<String> {
        let header = "export interface \(className)Attrs {"
        guard let start = src.range(of: header) else { return [] }
        let after = src[start.upperBound...]
        guard let close = after.range(of: "\n}") else { return [] }
        let body = after[..<close.lowerBound]
        var names = Set<String>()
        for rawLine in body.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Each line: `<name>?: <type>;`  or  `<name>: <type>;`
            guard let colon = line.firstIndex(of: ":") else { continue }
            var name = String(line[..<colon])
            if name.hasSuffix("?") { name = String(name.dropLast()) }
            name = name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }

    /// Swift output:
    ///   `relationships: [`
    ///   `    "author": RelationshipDescriptor(...),`
    ///   `    "tags":   RelationshipDescriptor(...),`
    ///   `]`
    ///
    /// Extract the leading-quoted keys of the literal.
    private func extractSwiftRelationshipNames(from src: String) -> Set<String> {
        return extractKeysInBlock(src: src, openMarker: "relationships: [")
    }

    /// TS output (declaration-merged interface):
    ///   `export interface <Name> extends <Name>Attrs, BaseModel {`
    ///   `  author(): Promise<User | null>;`
    ///   `  tags(options?: PaginationOptions): Promise<PaginatedResult<Tag>>;`
    ///   `  addTag(target: Tag | string): Promise<void>;`
    ///   `  removeTag(target: Tag | string): Promise<void>;`
    ///   `}`
    ///
    /// We treat the user-facing accessor name as the relationship key.
    /// The companion `add<Target>` / `remove<Target>` methods aren't
    /// "relationships" themselves — they're auto-paired affordances —
    /// so we drop them.
    private func extractTsRelationshipNames(from src: String, className: String) -> Set<String> {
        let header = "export interface \(className) extends \(className)Attrs, BaseModel {"
        guard let start = src.range(of: header) else { return [] }
        let after = src[start.upperBound...]
        guard let close = after.range(of: "\n}") else { return [] }
        let body = after[..<close.lowerBound]
        var names = Set<String>()
        for rawLine in body.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Lines we care about look like `name(...)`. Lines with
            // just a property `field: type;` won't be present in
            // this interface body — Attrs holds those.
            guard let paren = line.firstIndex(of: "(") else { continue }
            let name = String(line[..<paren])
            // Drop add/remove pairs.
            if name.hasPrefix("add") || name.hasPrefix("remove") { continue }
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }

    /// Pull leading-quoted keys out of a `[...]` literal that opens
    /// with `openMarker`. Used by both the Swift fields and Swift
    /// relationships extractors. Stops at the matching closing `]`
    /// at the same brace depth — robust to nested `(...)`.
    private func extractKeysInBlock(src: String, openMarker: String) -> Set<String> {
        guard let openRange = src.range(of: openMarker) else { return [] }
        let after = src[openRange.upperBound...]
        var depth = 1
        var bodyEnd = after.startIndex
        for idx in after.indices {
            let c = after[idx]
            if c == "[" { depth += 1 }
            if c == "]" {
                depth -= 1
                if depth == 0 {
                    bodyEnd = idx
                    break
                }
            }
        }
        let body = after[after.startIndex..<bodyEnd]
        var names = Set<String>()
        for rawLine in body.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\"") else { continue }
            let afterQuote = line.dropFirst()
            guard let endQuote = afterQuote.firstIndex(of: "\"") else { continue }
            let name = String(afterQuote[..<endQuote])
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }

    // MARK: - Filesystem helpers

    private func makeTempDir(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    private func listFiles(in dir: URL, ext: String) throws -> [URL] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )
        return entries
            .filter { $0.lastPathComponent.hasSuffix(ext) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Attach every regular file under `dir` to the test result so
    /// the human can read what each codegen emitted right inside
    /// Xcode's test report.
    private func attachGeneratedFiles(dir: URL, namePrefix: String) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                    .isRegularFile, isFile else { continue }
            let data = (try? Data(contentsOf: url)) ?? Data()
            let attach = XCTAttachment(data: data)
            attach.name = "\(namePrefix) \(url.lastPathComponent)"
            attach.lifetime = .keepAlways
            add(attach)
        }
    }

    // MARK: - Path helpers

    private static var thisDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    private static var swiftClientRoot: URL {
        thisDir
            .deletingLastPathComponent()  // .../JsBaoClientTests/
            .deletingLastPathComponent()  // .../Tests/
            .deletingLastPathComponent()  // .../swift-client/
    }

    /// The TOML driving both codegens — the one E2EQueryParityTests
    /// already consumes for its end-to-end runtime parity tests.
    private func sharedSchemaURL() -> URL {
        Self.thisDir.appendingPathComponent("E2E/swift/Models/schema.toml")
    }
}
