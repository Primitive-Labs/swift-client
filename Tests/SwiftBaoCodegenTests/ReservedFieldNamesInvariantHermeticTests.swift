import Foundation
import XCTest
@testable import swift_bao_codegen

/// The reserved field-name list stays in step with what a generated Swift
/// model carries (#4505).
///
/// `SwiftEmitter` puts members of its own on every generated struct and its
/// facade extension (`related`, `CodingKeys`, `discardChanges`, `save(in:)`, …),
/// and the struct satisfies protocol requirements (`primitiveValues()`,
/// `hashValue`, `encode(to:)`). A declared field that shares a name with one
/// of them can redeclare it. Every such name must be classified by
/// `packages/js-bao/src/utils/reservedFieldNames.json` — reserved, on either
/// client's account, or exempt with the reason it works on both — so a member
/// the emitter grows fails here until the list says what it is.
///
/// Two halves:
///  - the inventory reads the comment-stripped `SwiftEmitter.swift` (the
///    source-text convention of `ClientSourceText` in the client's tests) and
///    classifies every literal member name it emits; it never reads `breaks`,
///    because the union is what an author must avoid;
///  - the ground truth regenerates the committed
///    `JsBaoClientTests/CodegenAcceptance/GeneratedReservedFieldProbe/ReservedFieldProbe.swift`
///    — a model declaring `id`, every exempt name and every reserved name that
///    breaks only JavaScript — and finds it byte-identical, so `swift test`
///    compiling that target is the proof each of those names coexists with the
///    struct's own members.
///
/// The names that break the struct are not compiled per run (it would take a
/// scratch package build each time). Their evidence is the one-off probe that
/// filled the list: one generated model per candidate name, built as part of
/// this package's test target, where exactly these failed —
///
///     related         invalid redeclaration of 'related'; does not conform to 'Encodable'
///     CodingKeys      ambiguous use of 'CodingKeys'; does not conform to 'Encodable'
///     discardChanges  invalid redeclaration of 'discardChanges()'
///     markAllChanged  invalid redeclaration of 'markAllChanged()'
///     primitiveValues invalid redeclaration of 'primitiveValues()'
///     hashValue       ambiguous use of 'hashValue'
///
/// — and every other candidate (the facade's `save`, `delete`,
/// `upsertByUnique`, the statics, `hash`, `encode`, `PrimitiveRecord`'s
/// `snapshot`, `fieldNames`, `rawValue`, `recordLogSeq`, `syncState`, and every
/// `BaseModel` member) built clean. A new `swift` entry repeats that probe.
final class ReservedFieldNamesInvariantHermeticTests: XCTestCase {

    // MARK: - Source text

    /// The `swift-client` package root.
    private static var packageRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        // .../Tests/SwiftBaoCodegenTests/<this file>
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    private static var repoRoot: URL { packageRoot.deletingLastPathComponent() }

    /// Inside the monorepo, not the published SwiftPM mirror (which carries
    /// nothing above `swift-client/`). The marker is the pnpm workspace file.
    private static var isMonorepoCheckout: Bool {
        FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("pnpm-workspace.yaml").path)
    }

    private static func packageFile(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Drops `//` line comments, so wording in a doc comment never decides a check.
    private static func stripComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// The emitter's source without the registration barrel, whose
    /// `GeneratedModels` enum is a separate type, not a model.
    private static func emitterModelSource() throws -> String {
        let source = stripComments(try packageFile("Sources/SwiftBaoCodegen/SwiftEmitter.swift"))
        let start = try XCTUnwrap(source.range(of: "func emitBarrel(schemas:"), "missing anchor: emitBarrel")
        let end = try XCTUnwrap(
            source.range(of: "private func header(schema:", range: start.upperBound..<source.endIndex),
            "missing anchor: header(schema:)"
        )
        return String(source[..<start.lowerBound]) + String(source[end.lowerBound...])
    }

    /// A member declaration the emitter writes at member depth (four spaces
    /// into the struct or the facade extension), with a LITERAL name: one
    /// followed by an interpolation (`include\(…)`, `\(method)`) depends on
    /// the schema and is not a fixed name.
    private static var emittedMember: NSRegularExpression {
        try! NSRegularExpression(
            pattern: #""    (?:\\\(access\) )?((?:private\(set\) |static |mutating |nonisolated )*)(?:var|let|func|enum|struct|class|typealias) ([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_\\])"#
        )
    }

    /// Literal member names in `source`, split by whether they are static.
    static func emittedMemberNames(_ source: String) -> (instance: Set<String>, statics: Set<String>) {
        var instance = Set<String>()
        var statics = Set<String>()
        let range = NSRange(source.startIndex..., in: source)
        for match in emittedMember.matches(in: source, range: range) {
            guard let modifiers = Range(match.range(at: 1), in: source),
                  let name = Range(match.range(at: 2), in: source) else { continue }
            if source[modifiers].contains("static") {
                statics.insert(String(source[name]))
            } else {
                instance.insert(String(source[name]))
            }
        }
        return (instance, statics)
    }

    /// Requirements a generated struct satisfies: the client's two model
    /// protocols, read from source, plus `Hashable` and `Encodable`.
    private static func protocolRequirementNames() throws -> Set<String> {
        let source = stripComments(try packageFile("Sources/JsBaoClient/Schema/PrimitiveModel.swift"))
        var names: Set<String> = ["hashValue", "hash", "encode"]
        for proto in ["public protocol PrimitiveModel:", "public protocol PrimitiveRowDecodable"] {
            let start = try XCTUnwrap(source.range(of: proto), "missing anchor: \(proto)")
            let end = try XCTUnwrap(source.range(of: "\n}", range: start.upperBound..<source.endIndex))
            let body = String(source[start.upperBound..<end.lowerBound])
            let requirement = try NSRegularExpression(pattern: #"(?:var|func) ([A-Za-z_][A-Za-z0-9_]*)"#)
            for match in requirement.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                if let name = Range(match.range(at: 1), in: body) { names.insert(String(body[name])) }
            }
        }
        return names
    }

    // MARK: - Classification

    /// Names the list leaves unclassified, sorted. Never reads `breaks`.
    static func unclassified(_ names: some Sequence<String>) -> [String] {
        Set(names.filter { name in
            !(name == "id" || name.hasPrefix("_")
              || ReservedFieldNames.reasons[name] != nil || ReservedFieldNames.exempt.contains(name))
        }).sorted()
    }

    private static func message(_ missing: [String], _ whereFound: String) -> String {
        "\(whereFound) has members packages/js-bao/src/utils/reservedFieldNames.json does not classify: "
            + "\(missing.joined(separator: ", ")). Probe each (a generated model with a field of that name, "
            + "built on both clients), add it to \"reserved\" or \"exempt\", and run `pnpm gen:reserved-fields`."
    }

    // MARK: - Inventory

    func testEveryLiteralMemberTheEmitterWritesIsClassified() throws {
        let (instance, statics) = Self.emittedMemberNames(try Self.emitterModelSource())
        // The reader really sees the struct's and the facade's members.
        for expected in ["related", "_explicitId", "_changedFields", "discardChanges", "markAllChanged",
                         "primitiveValues", "CodingKeys", "hash", "save", "upsertByUnique", "delete"] {
            XCTAssertTrue(instance.contains(expected), "the inventory missed instance member \(expected)")
        }
        for expected in ["modelName", "primitiveSchema", "query", "queryPaged", "count", "findAll", "find",
                         "findByUnique", "queryOne", "subscribe", "aggregate", "autoStampFields"] {
            XCTAssertTrue(statics.contains(expected), "the inventory missed static member \(expected)")
        }
        // Interpolated names (`include\(Rel)`, `allowed\(Field)Values`) are not fixed names.
        XCTAssertFalse(statics.contains("include"))
        XCTAssertFalse(statics.contains("allowed"))

        let missingInstance = Self.unclassified(instance)
        XCTAssertEqual(missingInstance, [], Self.message(missingInstance, "SwiftEmitter's generated struct"))
        let missingStatics = Self.unclassified(statics)
        XCTAssertEqual(missingStatics, [], Self.message(missingStatics, "SwiftEmitter's generated statics"))
    }

    func testEveryProtocolRequirementTheStructSatisfiesIsClassified() throws {
        let requirements = try Self.protocolRequirementNames()
        XCTAssertTrue(requirements.isSuperset(of: ["id", "primitiveValues", "modelName", "primitiveSchema", "hashValue", "encode"]))
        let missing = Self.unclassified(requirements)
        XCTAssertEqual(missing, [], Self.message(missing, "The generated struct's protocol requirements"))
    }

    func testAMemberTheListDoesNotClassifyFailsNamingIt() {
        let synthetic = #"        out += "    \(access) var brandNewMember: Int = 0\n""#
        let (instance, _) = Self.emittedMemberNames(synthetic)
        XCTAssertEqual(instance, ["brandNewMember"])
        let missing = Self.unclassified(instance.union(["related", "save"]))
        XCTAssertEqual(missing, ["brandNewMember"])
        XCTAssertTrue(Self.message(missing, "SwiftEmitter's generated struct").contains("brandNewMember"))
    }

    func testANameReservedOnEitherClientsAccountIsClassified() {
        // `save` breaks only JavaScript, `related` only Swift: both are on the list.
        XCTAssertEqual(Self.unclassified(["save", "delete", "related", "discardChanges"]), [])
    }

    // MARK: - The two generated copies

    func testTheTwoGeneratedCopiesAreIdentical() throws {
        let client = try Self.packageFile("Sources/JsBaoClient/RecordLog/ReservedFieldNames.generated.swift")
        let codegen = try Self.packageFile("Sources/SwiftBaoCodegen/ReservedFieldNames.generated.swift")
        XCTAssertEqual(client, codegen, "run `pnpm gen:reserved-fields`")
    }

    // MARK: - Ground truth: the compiled probe model

    static let probePath = "Tests/JsBaoClientTests/CodegenAcceptance/GeneratedReservedFieldProbe/ReservedFieldProbe.swift"

    /// The probe schema: `id` first, then every other name in code-point order.
    static func probeToml(_ names: [String]) -> String {
        var toml = "[models.reserved_field_probe]\nclass_name = \"ReservedFieldProbe\"\n\n"
        toml += "[models.reserved_field_probe.fields.id]\ntype = \"id\"\nauto_assign = true\n"
        for name in names.sorted() where name != "id" {
            toml += "\n[models.reserved_field_probe.fields.\(name)]\ntype = \"string\"\n"
        }
        return toml
    }

    func testTheCompiledProbeModelIsTheEmittersOutput() throws {
        guard Self.isMonorepoCheckout else {
            throw XCTSkip("packages/js-bao is not published with the Swift package; the probe's names come from its list")
        }
        let json = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("packages/js-bao/src/utils/reservedFieldNames.json"),
            encoding: .utf8
        )
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let reserved = try XCTUnwrap(parsed["reserved"] as? [String: [String: Any]])
        let exempt = try XCTUnwrap(parsed["exempt"] as? [String: String])
        let swiftCoexists = reserved.filter { !(($0.value["breaks"] as? [String]) ?? []).contains("swift") }.keys
        // Sanity: the JavaScript-only names the issue is about are in the probe.
        XCTAssertTrue(Set(swiftCoexists).isSuperset(of: ["syncState", "save", "delete", "constructor"]))

        let names = Array(exempt.keys) + Array(swiftCoexists)
        let schemas = try TomlParser.parse(
            tomlString: Self.probeToml(names), swiftNameSuffix: "Record", rejectReservedFieldNames: false
        )
        let schema = try XCTUnwrap(schemas.first)
        let emitter = SwiftEmitter(options: EmitOptions(
            accessLevel: "internal",
            moduleImport: "JsBaoClient",
            sourcePath: "ReservedFieldProbe.toml",
            swiftNamesByModel: [schema.name: schema.swiftName]
        ))
        let expected = emitter.emit(schema: schema)
        let committed = try Self.packageFile(Self.probePath)
        if committed != expected {
            let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("ReservedFieldProbe.swift")
            try? expected.write(to: fresh, atomically: true, encoding: .utf8)
            XCTFail("\(Self.probePath) is not the emitter's output for the current list; copy \(fresh.path) over it")
        }
    }
}
