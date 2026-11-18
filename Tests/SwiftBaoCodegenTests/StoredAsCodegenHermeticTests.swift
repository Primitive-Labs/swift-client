import Foundation
import XCTest
@testable import swift_bao_codegen

/// `swift-bao-codegen` over a db3 type that renames a field (#6023 behaviors
/// 26, 27, 28, 46's naming half, E2, E3, E6). Replaces #6022's guard test.
///
/// The parser takes `storedAs`, strict or not, and refuses what js-bao's
/// loader refuses, with the same sentences. The emitted model keeps the
/// current name as its Swift property and uses the stored name wherever the
/// generated code names the field to the runtime: `primitiveSchema` keys,
/// constraint fields, `primitiveValues()`, the row and record initializers,
/// change tracking and `CodingKeys`. `primitiveSchema` carries the
/// current-to-stored map and the type it comes from. A type that declares no
/// `storedAs` emits the code it did (comments are not compared).
///
/// Hermetic: `TomlParser` and `CodegenRun` over in-memory documents.
final class StoredAsCodegenHermeticTests: XCTestCase {

    private static func workspace(_ storedAs: String? = "due", key: String = "dueAt", name: String = "workspace") -> String {
        """
        [type]
        name = "\(name)"

        [models.tasks]
        class_name = "Task"

        [models.tasks.fields.title]
        type = "string"

        [models.tasks.fields.\(key)]
        type = "number"
        unique = true
        default = 3
        \(storedAs.map { "storedAs = \"\($0)\"" } ?? "")

        [[models.tasks.unique_constraints]]
        name = "title_due"
        fields = ["title", "\(key)"]
        """
    }

    private func render(_ documents: [(String, String)]) throws -> [String: String] {
        let files = try CodegenRun.render(
            documents: documents.map { (sourceName: $0.0, source: $0.1) },
            emptyLabel: "",
            accessLevel: "public",
            moduleImport: "JsBaoClient",
            swiftNameSuffix: "Record",
            strict: true
        )
        return Dictionary(uniqueKeysWithValues: files.map { ($0.fileName, $0.source) })
    }

    private func refusal(_ source: String) -> String {
        do {
            _ = try TomlParser.parse(tomlString: source, swiftNameSuffix: "Record", strict: true)
            XCTFail("expected a refusal")
            return ""
        } catch {
            return String(describing: error)
        }
    }

    // MARK: - Behavior 26

    func testTheParserTakesStoredAsStrictAndNot() throws {
        for strict in [true, false] {
            let schemas = try TomlParser.parse(tomlString: Self.workspace(), swiftNameSuffix: "Record", strict: strict)
            XCTAssertEqual(schemas[0].fields["dueAt"]?.storedAs, "due")
            XCTAssertEqual(schemas[0].typeNames, ["workspace"])
        }
    }

    func testTheParserRefusesWhatJsBaoRefusesWithItsSentences() {
        let field = "[models.tasks.fields.dueAt]"
        XCTAssertEqual(refusal(Self.workspace("")), "\(field): storedAs must be a non-empty string naming the field's stored name")
        XCTAssertEqual(refusal(Self.workspace("id")), "\(field): storedAs \"id\" names the record's id; a field's stored name is never id")
        XCTAssertEqual(
            refusal(Self.workspace("_due")),
            "\(field): storedAs \"_due\" is reserved: Field '_due' is reserved (fields starting with '_' are internal)"
        )
        XCTAssertEqual(
            refusal(Self.workspace("due-date")),
            "\(field): storedAs \"due-date\" is not an identifier (a letter, then letters, digits or _)"
        )
        XCTAssertEqual(
            refusal(Self.workspace("title")),
            "\(field): storedAs \"title\" is the key of another declared field; a stored name belongs to one field"
        )
        let onId = Self.workspace() + "\n\n[models.tasks.fields.id]\ntype = \"id\"\nauto_assign = true\nstoredAs = \"key\"\n"
        XCTAssertEqual(refusal(onId), "[models.tasks.fields.id]: storedAs cannot be set on the id field")
        let shared = Self.workspace() + "\n\n[models.tasks.fields.alsoDue]\ntype = \"number\"\nstoredAs = \"due\"\n"
        XCTAssertTrue(refusal(shared).contains("storedAs \"due\" is also the stored name of"), refusal(shared))
        XCTAssertTrue(refusal(shared).hasSuffix("; a stored name belongs to one field"), refusal(shared))
    }

    // MARK: - Behavior 27 (pin)

    func testATypeWithoutStoredAsEmitsTheCommittedGoldensCode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Tests/SwiftBaoCodegenTests/Fixtures/stored-as-6023/tasks6023.toml"), encoding: .utf8)
        let goldens = root.appending(path: "Tests/SwiftBaoCodegenTests/Goldens/stored-as-6023")
        var committed: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: goldens.path(percentEncoded: false)) where name.hasSuffix(".golden") {
            committed[String(name.dropLast(".golden".count))] = try String(contentsOf: goldens.appending(path: name), encoding: .utf8)
        }
        let rendered = try render([("tasks6023.toml", source)])
        XCTAssertEqual(rendered.keys.sorted(), committed.keys.sorted())
        for (name, text) in rendered {
            XCTAssertEqual(Self.codeLines(text), Self.codeLines(committed[name] ?? ""), "\(name) differs")
        }
    }

    /// Generated Swift without its comments: the code the emitter writes,
    /// line by line, so the comparison holds no documentation wording.
    private static func codeLines(_ text: String) -> [String] {
        var out: [String] = []
        var inBlock = false
        for raw in text.components(separatedBy: "\n") {
            var line = raw
            if inBlock {
                guard let end = line.range(of: "*/") else { continue }
                line = String(line[end.upperBound...])
                inBlock = false
            }
            while let start = line.range(of: "/*") {
                if let end = line.range(of: "*/", range: start.upperBound..<line.endIndex) {
                    line.removeSubrange(start.lowerBound..<end.upperBound)
                } else {
                    line = String(line[..<start.lowerBound])
                    inBlock = true
                    break
                }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") { continue }
            out.append(String(line.reversed().drop(while: { $0 == " " }).reversed()))
        }
        return out
    }

    // MARK: - Behavior 28

    func testTheEmitterUsesTheStoredNameWhereTheRuntimeReadsAField() throws {
        let swift = try XCTUnwrap(render([("workspace.toml", Self.workspace())])["Task.swift"])
        XCTAssertTrue(swift.contains("public var dueAt: Double?"), swift)
        XCTAssertFalse(swift.contains("var due:"))
        XCTAssertTrue(swift.contains("case id, title, dueAt = \"due\""), swift)
        XCTAssertTrue(swift.contains("\"due\":"), swift)
        XCTAssertFalse(swift.contains("\"dueAt\": FieldDescriptor"), swift)
        XCTAssertTrue(swift.contains("ConstraintDescriptor(name: \"title_due\", fields: [\"title\", \"due\"])"), swift)
        XCTAssertTrue(swift.contains("fieldNames: [\"dueAt\": \"due\"]"), swift)
        XCTAssertTrue(swift.contains("fieldNameTypes: [\"workspace\"]"), swift)
        XCTAssertTrue(swift.contains("record[\"due\"]?.asNumber"), swift)
        XCTAssertTrue(swift.contains("record.holds(\"due\")"), swift)
        XCTAssertTrue(swift.contains("row[\"due\"]?.numberValue"), swift)
        XCTAssertTrue(swift.contains("_changedFields.insert(\"due\")"), swift)
        XCTAssertFalse(swift.contains("record[\"dueAt\"]"))
        XCTAssertFalse(swift.contains("row[\"dueAt\"]"))
        // `upsertOn` names the field by its current name; the constraint is the one the server enforces.
        XCTAssertTrue(swift.contains("case dueAt = \"dueAt\""), swift)
        XCTAssertTrue(swift.contains("= \"tasks_due_unique\""), swift)
    }

    func testTheTypesOfEveryInputThatDeclaresTheRenamedModelAreListed() throws {
        let files = try render([("a.toml", Self.workspace(name: "alpha")), ("b.toml", Self.workspace(name: "beta"))])
        XCTAssertTrue(try XCTUnwrap(files["Task.swift"]).contains("fieldNameTypes: [\"alpha\", \"beta\"]"))
    }

    func testATypeThatNamesTheRenamedModelThroughTypeModelsIsListed() throws {
        let household = """
        [type]
        name = "household"
        models = ["tasks"]

        [models.accounts]
        class_name = "Account"

        [models.accounts.fields.name]
        type = "string"
        """
        let files = try render([("household.toml", household), ("reference.toml", Self.workspace(name: "reference"))])
        XCTAssertTrue(try XCTUnwrap(files["Task.swift"]).contains("fieldNameTypes: [\"household\", \"reference\"]"))
    }

    // MARK: - Edges

    /// E2: `storedAs` equal to the key means nothing; E6: a cleared renamed field is not generated.
    func testStoredAsEqualToTheKeyAndAClearedRenamedField() throws {
        let same = try XCTUnwrap(render([("workspace.toml", Self.workspace("dueAt"))])["Task.swift"])
        XCTAssertFalse(same.contains("fieldNames:"))
        XCTAssertTrue(same.contains("case id, title, dueAt\n"), same)
        let cleared = Self.workspace().replacingOccurrences(of: "unique = true\n", with: "deprecated = true\ncleared = true\n")
            .replacingOccurrences(of: "\n[[models.tasks.unique_constraints]]\nname = \"title_due\"\nfields = [\"title\", \"dueAt\"]", with: "")
        let swift = try XCTUnwrap(render([("workspace.toml", cleared)])["Task.swift"])
        XCTAssertFalse(swift.contains("dueAt"), swift)
        XCTAssertFalse(swift.contains("fieldNames:"), swift)
    }
}

/// The renamed model committed under `JsBaoClientTests/CodegenAcceptance/RenamedField`
/// is what the emitter writes for its fixture, so the compiled acceptance
/// tests exercise current output.
final class StoredAsCommittedModelHermeticTests: XCTestCase {
    func testTheCommittedRenamedModelIsTheEmittersOutput() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Tests/SwiftBaoCodegenTests/Fixtures/stored-as-6023/renamed-6023.toml"), encoding: .utf8)
        let files = try CodegenRun.render(
            documents: [(sourceName: "renamed-6023.toml", source: source)],
            emptyLabel: "", accessLevel: "public", moduleImport: "JsBaoClient", swiftNameSuffix: "Record", strict: true
        )
        let generated = try XCTUnwrap(files.first { $0.fileName == "RenamedTask6023.swift" }?.source)
        let committed = try String(
            contentsOf: root.appending(path: "Tests/JsBaoClientTests/CodegenAcceptance/RenamedField/RenamedTask6023.swift"), encoding: .utf8)
        XCTAssertTrue(Array(generated.utf8) == Array(committed.utf8), "regenerate RenamedTask6023.swift from renamed-6023.toml")
    }
}
