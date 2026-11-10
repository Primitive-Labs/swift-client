import Foundation
import XCTest
@testable import swift_bao_codegen

/// `swift-bao-codegen` over a db3 type whose field refs a shared enum in
/// `schemas/` (#5545 behaviors 15–17, project `unified-schemas` phase 11).
///
/// The tool reads `schemas/*.toml` beside the `db3-types/` it is given and
/// expands `ref = "Status"` into `type = "string"`, `enum = [...]` before the
/// field is read, so every generated file equals the hand-expanded type's. A
/// ref that does not name exactly one plain string enum is refused with
/// js-bao's sentence (`packages/js-bao/src/models/sharedEnums.ts`, mirrored by
/// hand); the case list below is the js-bao tests' own.
///
/// Hermetic: `CodegenInputs` over temporary directories, `CodegenRun` over
/// in-memory documents, and one spawned run of the built tool.
final class SharedEnumCodegenHermeticTests: XCTestCase {

    private static let common = """
        [defs.Status]
        type = "string"
        enum = ["open", "doing", "done"]
        description = "Where a task is."

        [defs.Kind]
        type = "string"
        enum = ["bug", "chore"]
        """

    private static func workspace(_ status: String) -> String {
        """
        [type]
        name = "workspace"

        [models.tasks]
        class_name = "Task"

        [models.tasks.fields.title]
        type = "string"

        [models.tasks.fields.status]
        \(status)
        indexed = true
        default = "open"
        """
    }

    private static let ref = #"ref = "Status""#
    private static let expanded = #"type = "string"\#nenum = ["open", "doing", "done"]"#
    private static let profile = """
        [type]
        name = "profile"

        [models.people]
        class_name = "Person"

        [models.people.fields.name]
        type = "string"
        """

    private static let noKeys = (db3: [String](), function: [String](), prompt: [String]())

    private func index(
        _ files: [(String, String)]?,
        dir: String = "schemas/",
        keys: (db3: [String], function: [String], prompt: [String]) = noKeys
    ) -> SharedEnums {
        SharedEnums(files: files, dir: dir, db3: keys.db3, function: keys.function, prompt: keys.prompt)
    }

    private func render(_ documents: [(String, String)], sharedEnums: [SharedEnums?]? = nil) throws -> [String: String] {
        let files = try CodegenRun.render(
            documents: documents.map { (sourceName: $0.0, source: $0.1) },
            sharedEnums: sharedEnums,
            emptyLabel: "",
            accessLevel: "public",
            moduleImport: "JsBaoClient",
            swiftNameSuffix: "Record",
            strict: true
        )
        return Dictionary(uniqueKeysWithValues: files.map { ($0.fileName, $0.source) })
    }

    private func failure(
        _ documents: [(String, String)], sharedEnums: [SharedEnums?],
        file: StaticString = #filePath, line: UInt = #line
    ) -> String {
        do {
            let files = try render(documents, sharedEnums: sharedEnums)
            XCTFail("expected a refusal, got \(files.keys.sorted())", file: file, line: line)
            return ""
        } catch let error as CodegenError {
            return error.description
        } catch {
            XCTFail("expected a CodegenError, got \(error)", file: file, line: line)
            return ""
        }
    }

    private func sandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "swift-bao-5545-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func put(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Behavior 15: render

    func testARefRendersEveryFileByteIdenticalToTheHandExpandedType() throws {
        let shared = index([("common", Self.common)])
        let ref = try render([("workspace.toml", Self.workspace(Self.ref)), ("profile.toml", Self.profile)], sharedEnums: [shared, shared])
        let hand = try render([("workspace.toml", Self.workspace(Self.expanded)), ("profile.toml", Self.profile)])
        XCTAssertEqual(ref.keys.sorted(), ["GeneratedModels.swift", "Person.swift", "Task.swift"])
        XCTAssertEqual(ref, hand)
        XCTAssertTrue(ref["Task.swift"]!.contains("case doing"), ref["Task.swift"]!)

        // One document reads the same.
        XCTAssertEqual(
            try render([("workspace.toml", Self.workspace(Self.ref))], sharedEnums: [shared]),
            try render([("workspace.toml", Self.workspace(Self.expanded))])
        )
    }

    /// js-bao's sentence for each refusal, as `db3-shared-enums-resolver-5545`
    /// and `db3-shared-enums-loader-5545` assert it.
    private static let refusals: [(ref: String, files: [(String, String)], keys: (db3: [String], function: [String], prompt: [String]), sentence: String)] = {
        let other = "[defs.Status]\ntype = \"string\"\nenum = [\"x\"]\n"
        let notRef = #"a db3 field refs only a shared enum in schemas/; write "<Name>", "<file>.<Name>" or "schemas.<file>.<Name>"."#
        let def = { (body: String) in [("common", "[defs.Status]\n\(body)\n")] }
        let notEnum = { (what: String) in
            "schemas/common.toml#Status is not a shared enum: it declares \(what); a db3 field refs only a def with type = \"string\" and a non-empty enum of distinct strings."
        }
        let commonFile = [("common", common)]
        return [
            (#""Missing""#, commonFile, noKeys, "no schemas/ file declares Missing; fix the name, or add [defs.Missing] to a schemas/ file."),
            (#""Status""#, [("zeta", other), ("common", common)], noKeys,
             "more than one schemas/ file declares Status; use a long form: schemas.common.Status, schemas.zeta.Status."),
            (#""shared.Status""#, commonFile, noKeys,
             #"there is no schemas/shared.toml; a db3 field refs only a shared enum in schemas/, so fix the file name or write "schemas.<file>.Status"."#),
            (#""common.Status""#, commonFile, (db3: [], function: ["common"], prompt: []),
             "common is a key in more than one family; use a long form: fn.common.Status, schemas.common.Status."),
            (#""common.Status""#, commonFile, (db3: [], function: [], prompt: ["common"]),
             "common is a key in more than one family; use a long form: prompt.common.Status, schemas.common.Status."),
            (#""common.Status""#, commonFile, (db3: ["common"], function: ["common"], prompt: ["common"]),
             "common is a key in more than one family; use a long form: db3.common.Status, fn.common.Status, prompt.common.Status, schemas.common.Status."),
            (#""billing.Status""#, commonFile, (db3: [], function: ["billing"], prompt: []),
             #"there is no schemas/billing.toml; a db3 field refs only a shared enum in schemas/, so fix the file name or write "schemas.<file>.Status"."#),
            (#""schemas.common.Priority""#, commonFile, noKeys,
             "schemas/common.toml declares no Priority (it declares Kind, Status); fix the name, or add [defs.Priority] there."),
            (#""schemas.empty.Priority""#, [("empty", "# nothing\n")], noKeys,
             "schemas/empty.toml declares no Priority; fix the name, or add [defs.Priority] there."),
            (#""Missing""#, [("broken", "a = = 1\n"), ("common", common)], noKeys,
             "no schemas/ file declares Missing; fix the name, or add [defs.Missing] to a schemas/ file (schemas/broken.toml could not be read)."),
            (#""Status""#, [("a", other), ("b", other), ("c", "a = = 1\n")], noKeys,
             "more than one schemas/ file declares Status; use a long form: schemas.a.Status, schemas.b.Status."),
            (#""platform.Status""#, commonFile, noKeys,
             #"the platform prefix is reserved; name a shared enum in schemas/ as "schemas.<file>.<Name>"."#),
            (#""common.Status#declared""#, commonFile, noKeys,
             "a projection (#declared) applies to a db3 model ref and a shared enum has none; drop the suffix."),
            (#""db3.workspace.tasks""#, commonFile, noKeys, notRef),
            (#""schemas.common.Status.extra""#, commonFile, noKeys, notRef),
            (#""a..b""#, commonFile, noKeys, notRef),
            (#""""#, commonFile, noKeys, notRef),
            (#"" Status""#, commonFile, noKeys, notRef),
            ("3", commonFile, noKeys, notRef),
            (#""Status""#, def("type = \"object\"\n[defs.Status.properties.a]\ntype = \"string\""), noKeys, notEnum(#"type = "object""#)),
            (#""Status""#, def("type = \"number\"\nenum = [1, 2]"), noKeys, notEnum(#"type = "number""#)),
            (#""Status""#, def("enum = [\"a\"]"), noKeys, notEnum("no type")),
            (#""Status""#, def("type = \"string\""), noKeys, notEnum("no enum")),
            (#""Status""#, def("type = \"string\"\nenum = [\"a\"]\npattern = \"^a$\""), noKeys, notEnum("pattern")),
            (#""Status""#, def("type = \"string\"\nenum = [\"a\"]\npattern = \"^a$\"\nformat = \"email\""), noKeys, notEnum("format")),
            (#""Status""#, def("type = \"string\"\nenum = [\"a\"]\nmax_length = 3"), noKeys, notEnum("max_length")),
            (#""Status""#, def("type = \"string\"\nenum = [\"a\"]\nmaxLength = 3"), noKeys, notEnum("maxLength")),
            (#""Status""#, def("type = \"string\"\nenum = [\"a\"]\ndefault = \"a\""), noKeys, notEnum("default")),
            (#""Status""#, def("type = \"string\"\nenum = [\"a\"]\nnullable = true"), noKeys, notEnum("nullable")),
            (#""Status""#, def("type = \"string\"\nenum = [\"a\"]\nref = \"Other\""), noKeys, notEnum("ref")),
            (#""Status""#, def("type = \"string\"\nenum = [\"a\"]\n\"$ref\" = \"#/$defs/Other\""), noKeys, notEnum("$ref")),
            (#""Status""#, def("type = \"string\"\nenum = []"), noKeys, notEnum("an empty enum")),
            (#""Status""#, def("type = \"string\"\nenum = \"a\""), noKeys, notEnum("an enum that is not a list")),
            (#""Status""#, def("type = \"string\"\nenum = [\"a\", 2]"), noKeys, notEnum("a non-string enum member")),
            (#""Status""#, def("type = \"string\"\nenum = [\"open\", \"done\", \"open\"]"), noKeys, notEnum(#"an enum that repeats a value ("open")"#)),
        ]
    }()

    func testEachRefusalIsJsBaosSentenceAfterTheModelAndFieldPrefix() {
        for (ref, files, keys, sentence) in Self.refusals {
            let shared = index(files, keys: keys)
            let message = failure([("workspace.toml", Self.workspace("ref = \(ref)"))], sharedEnums: [shared])
            XCTAssertEqual(message, "[models.tasks.fields.status]: ref \(ref): \(sentence)", ref)
        }
    }

    func testTypeOrEnumBesideRefIsRefusedNamingThem() {
        let shared = index([("common", Self.common)])
        for (status, sentence) in [
            ("ref = \"Status\"\ntype = \"string\"", "type cannot sit beside ref; the shared enum supplies it, so remove it."),
            ("ref = \"Status\"\nenum = [\"open\"]", "enum cannot sit beside ref; the shared enum supplies it, so remove it."),
            ("type = \"string\"\nref = \"Status\"\nenum = [\"open\"]", "type and enum cannot sit beside ref; the shared enum supplies both, so remove them."),
        ] {
            XCTAssertEqual(
                failure([("workspace.toml", Self.workspace(status))], sharedEnums: [shared]),
                "[models.tasks.fields.status]: ref \"Status\": \(sentence)"
            )
        }
    }

    func testARefIntoAFileThatDoesNotParseNamesTheFileAndItsFirstErrorLine() {
        let message = failure([("workspace.toml", Self.workspace(#"ref = "broken.Status""#))], sharedEnums: [index([("broken", "a = = 1\n")])])
        XCTAssertTrue(message.hasPrefix(#"[models.tasks.fields.status]: ref "broken.Status": schemas/broken.toml could not be read ("#), message)
        XCTAssertTrue(message.hasSuffix("); fix the file."), message)
        XCTAssertFalse(message.contains("\n"), message)
    }

    func testARefWithNoSchemasDirectoryNamesTheDirectoryLookedFor() {
        XCTAssertEqual(
            failure([("workspace.toml", Self.workspace(Self.ref))], sharedEnums: [index(nil, dir: "/tmp/app/schemas/")]),
            #"[models.tasks.fields.status]: ref "Status": no /tmp/app/schemas/ directory was found; add one beside db3-types/ declaring [defs.Status]."#
        )
    }

    func testAmongSeveralDocumentsARefusalNamesTheFile() {
        let shared = index([("common", Self.common)])
        XCTAssertEqual(
            failure([("profile.toml", Self.profile), ("workspace.toml", Self.workspace(#"ref = "Missing""#))], sharedEnums: [shared, shared]),
            #"workspace.toml: [models.tasks.fields.status]: ref "Missing": no schemas/ file declares Missing; fix the name, or add [defs.Missing] to a schemas/ file."#
        )
    }

    func testTheInputsTypeNamesAreDb3KeysForThePairRule() throws {
        let documents = [("common.toml", "[type]\nname = \"common\"\n"), ("workspace.toml", Self.workspace(#"ref = "common.Status""#))]
        let inputs = documents.map { CodegenInput(path: "/app/db3-types/\($0.0)", sourceName: $0.0, source: $0.1) }
        XCTAssertEqual(CodegenInputs.typeNames(inputs), ["common", "workspace"])
        let shared = index([("common", Self.common)], keys: (db3: CodegenInputs.typeNames(inputs), function: [], prompt: []))
        XCTAssertEqual(
            failure(documents, sharedEnums: [shared, shared]),
            #"workspace.toml: [models.tasks.fields.status]: ref "common.Status": common is a key in more than one family; use a long form: db3.common.Status, schemas.common.Status."#
        )
    }

    // MARK: - Behavior 16: inputs and main

    func testSchemasBesideADirectoryOrAFileInputAreFoundInNameOrder() throws {
        let root = try sandbox()
        try put(Self.workspace(Self.ref), at: root.appending(path: "db3-types/workspace.toml"))
        try put(Self.common, at: root.appending(path: "schemas/common.toml"))
        try put("[defs.Kind]\ntype = \"string\"\nenum = [\"a\"]\n", at: root.appending(path: "schemas/alpha.toml"))
        try put("not toml", at: root.appending(path: "schemas/notes.txt"))

        for input in [root.appending(path: "db3-types").path, root.appending(path: "db3-types/workspace.toml").path] {
            let inputs = try CodegenInputs.read(try CodegenInputs.expand([input]))
            let shared = CodegenInputs.sharedEnumFiles(for: inputs)
            XCTAssertEqual(shared.count, 1)
            XCTAssertEqual(shared[0].stems, ["alpha", "common"])
            XCTAssertEqual(shared[0].db3, ["workspace"])
            XCTAssertEqual(
                try render(inputs.map { ($0.sourceName, $0.source) }, sharedEnums: shared),
                try render([("workspace.toml", Self.workspace(Self.expanded))])
            )
        }
    }

    func testWithNoSchemasDirectoryARefIsRefusedNamingTheDirectory() throws {
        let root = try sandbox()
        try put(Self.workspace(Self.ref), at: root.appending(path: "db3-types/workspace.toml"))
        let inputs = try CodegenInputs.read(try CodegenInputs.expand([root.appending(path: "db3-types").path]))
        let shared = CodegenInputs.sharedEnumFiles(for: inputs)
        let dir = root.appending(path: "schemas").standardizedFileURL.path(percentEncoded: false)
        XCTAssertEqual(
            failure([("workspace.toml", Self.workspace(Self.ref))], sharedEnums: shared),
            "[models.tasks.fields.status]: ref \"Status\": no \(dir)/ directory was found; add one beside db3-types/ declaring [defs.Status]."
        )
    }

    /// The built `swift-bao-codegen`, beside this test bundle.
    private func codegenBinary() throws -> URL {
        let bundle = Bundle(for: Self.self).bundleURL
        let candidates = [
            bundle.deletingLastPathComponent().appendingPathComponent("swift-bao-codegen"),
            bundle.appendingPathComponent("swift-bao-codegen"),
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            XCTFail("swift-bao-codegen is not built beside the test bundle: \(candidates.map(\.path))")
            throw CocoaError(.fileNoSuchFile)
        }
        return binary
    }

    private func spawn(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = try codegenBinary()
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testTheBuiltToolReadsSchemasBesideItsInput() throws {
        let root = try sandbox()
        try put(Self.workspace(Self.ref), at: root.appending(path: "db3-types/workspace.toml"))
        try put(Self.common, at: root.appending(path: "schemas/common.toml"))
        let output = root.appending(path: "Generated")
        let run = try spawn(["--input", root.appending(path: "db3-types").path, "--output", output.path])
        XCTAssertEqual(run.status, 0, run.output)
        let task = try String(contentsOf: output.appending(path: "Task.swift"), encoding: .utf8)
        XCTAssertEqual(task, try render([("workspace.toml", Self.workspace(Self.expanded))])["Task.swift"])

        let check = try spawn(["--input", root.appending(path: "db3-types").path, "--output", output.path, "--check"])
        XCTAssertEqual(check.status, 0, check.output)

        try put(Self.workspace(#"ref = "Missing""#), at: root.appending(path: "db3-types/workspace.toml"))
        let refused = try spawn(["--input", root.appending(path: "db3-types").path, "--output", output.path])
        XCTAssertNotEqual(refused.status, 0, refused.output)
        XCTAssertTrue(refused.output.contains(#"[models.tasks.fields.status]: ref "Missing": no schemas/ file declares Missing"#), refused.output)
    }

    // MARK: - Behavior 17: a type without a ref

    func testATypeWithoutARefRendersTheSameWithOrWithoutSchemas() throws {
        let shared = index([("common", Self.common)])
        let documents = [("workspace.toml", Self.workspace(Self.expanded)), ("profile.toml", Self.profile)]
        XCTAssertEqual(try render(documents, sharedEnums: [shared, shared]), try render(documents))
        XCTAssertEqual(try render(documents, sharedEnums: [index(nil), index(nil)]), try render(documents))
    }

    func testWithoutSharedEnumsARefIsTodaysMissingType() {
        XCTAssertEqual(
            failure([("workspace.toml", Self.workspace(Self.ref))], sharedEnums: []),
            "Model `tasks` field `status` is missing required `type`"
        )
    }
}
