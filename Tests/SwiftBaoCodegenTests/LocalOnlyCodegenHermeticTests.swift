import Foundation
import XCTest
@testable import swift_bao_codegen

/// `swift-bao-codegen` embeds a local-only type's declarations (#6025
/// behaviors 26 and 27, spec criteria 9 and 10).
///
/// For each input type file with `[type] allowLocalOnly = true`, the barrel's
/// `db3Types` carries the type's declarations in install shape and their
/// content hash, registered by `register(on:)`. The hash and the declarations
/// equal what `Fixtures/local-only-6025/expected.json` records, which a JS
/// unit test (`codegen-local-only-swift-fixtures-6025`) holds to
/// js-bao-codegen-v2 and to the server's revision hash. Codegen stops,
/// naming the file and the hook, on an opted-in type file that declares a
/// hook. A build with no opted-in type is generated as before.
///
/// Hermetic: `CodegenRun` over the fixture files, read in memory.
final class LocalOnlyCodegenHermeticTests: XCTestCase {

    /// The shared enum a fixture field refs, as the JS test writes it at run time.
    private static let sharedEnums = "[defs.Status]\ntype = \"string\"\nenum = [\"open\", \"doing\", \"done\"]\n"

    private static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/local-only-6025")
    }

    /// The fixture's type files, by name, with `edit` applied (a `nil` text drops the file).
    private func documents(_ edit: [String: String?] = [:]) throws -> [(String, String)] {
        let dir = Self.fixtures.appending(path: "db3-types")
        var out: [(String, String)] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).sorted() where name.hasSuffix(".toml") {
            if let replaced = edit[name] {
                if let text = replaced { out.append((name, text)) }
                continue
            }
            out.append((name, try String(contentsOf: dir.appending(path: name), encoding: .utf8)))
        }
        return out
    }

    private func text(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appending(path: "db3-types/\(name)"), encoding: .utf8)
    }

    private func resolvers(_ documents: [(String, String)]) -> [SharedEnums?] {
        let inputs = documents.map { CodegenInput(path: "/fixture/db3-types/\($0.0)", sourceName: $0.0, source: $0.1) }
        let shared = SharedEnums(
            files: [("common", Self.sharedEnums)], dir: "/fixture/schemas/", db3: CodegenInputs.typeNames(inputs), objects: true
        )
        return documents.map { _ in shared }
    }

    private func render(_ documents: [(String, String)], knownTypesOnly: Bool = false) throws -> [String: String] {
        let files = try CodegenRun.render(
            documents: documents.map { (sourceName: $0.0, source: $0.1) },
            sharedEnums: resolvers(documents),
            emptyLabel: "db3-types/",
            accessLevel: "public",
            moduleImport: "JsBaoClient",
            swiftNameSuffix: "Record",
            strict: true,
            knownTypesOnly: knownTypesOnly
        )
        return Dictionary(uniqueKeysWithValues: files.map { ($0.fileName, $0.source) })
    }

    /// `expected.json`: per opted-in type, its hash and declarations as canonical JSON.
    private func expected() throws -> [String: [String: String]] {
        let data = try Data(contentsOf: Self.fixtures.appending(path: "expected.json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
    }

    // MARK: - Behavior 26

    func testEveryCrossCheckFixtureHashesAsJsBaoAndTheServer() throws {
        let documents = try documents()
        let declared = try LocalOnlyDeclarations.of(
            documents: documents.map { (sourceName: $0.0, source: $0.1) }, sharedEnums: resolvers(documents)
        )
        let expected = try expected()
        XCTAssertEqual(declared.keys.sorted(), expected.keys.sorted())
        for (type, recorded) in expected {
            XCTAssertEqual(declared[type]?.hash, recorded["hash"], "\(type)'s hash")
            XCTAssertEqual(declared[type]?.modelsJSON, recorded["modelsJSON"], "\(type)'s declarations")
        }
    }

    func testTheBarrelRegistersTheOptedInTypesWithTheirDeclarations() throws {
        let barrel = try XCTUnwrap(try render(try documents())["GeneratedModels.swift"])
        let expected = try expected()
        XCTAssertTrue(barrel.contains("public static let db3Types = PrimitiveDb3Types(knownTypesOnly: false, types: [\n"), barrel)
        // Only the opted-in types: catalog6025 does not allow local-only db3s.
        XCTAssertFalse(barrel.contains("\"catalog6025\""), barrel)
        for (type, recorded) in expected {
            XCTAssertTrue(barrel.contains("PrimitiveDb3Types.DeclaredType(name: \"\(type)\", localOnly: PrimitiveDb3Types.LocalOnlyDeclarations("), barrel)
            XCTAssertTrue(barrel.contains("hash: \"\(recorded["hash"]!)\""), barrel)
        }
        XCTAssertTrue(barrel.contains("client.registerDb3Types(db3Types)"), barrel)
    }

    func testWithTheFlagOneListCarriesTheKnownTypesAndTheDeclarations() throws {
        let barrel = try XCTUnwrap(try render(try documents(), knownTypesOnly: true)["GeneratedModels.swift"])
        XCTAssertTrue(barrel.contains("public static let db3Types = PrimitiveDb3Types(knownTypesOnly: true, types: [\n"), barrel)
        XCTAssertTrue(barrel.contains("PrimitiveDb3Types.DeclaredType(name: \"catalog6025\"),\n"), barrel)
        XCTAssertTrue(barrel.contains("PrimitiveDb3Types.DeclaredType(name: \"journal6025\", localOnly: "), barrel)
        XCTAssertEqual(barrel.components(separatedBy: "static let db3Types").count, 2, "one list")
    }

    func testTheHashMovesWithTheDeclarationsAndNotWithARename() throws {
        let journal = try text("journal.toml")
        let base = try XCTUnwrap(try declarations(["journal.toml": journal])["journal6025"])
        let renamed = journal.replacingOccurrences(of: "[models.entry6025.fields.weight]", with: "[models.entry6025.fields.heft]\nstoredAs = \"weight\"")
        XCTAssertEqual(try declarations(["journal.toml": renamed])["journal6025"]?.hash, base.hash)
        let grown = journal + "\n[models.entry6025.fields.notes]\ntype = \"string\"\n"
        XCTAssertNotEqual(try declarations(["journal.toml": grown])["journal6025"]?.hash, base.hash)
    }

    func testJavaScriptNumberText() {
        let cases: [(Double, String)] = [
            (1.5, "1.5"), (3, "3"), (-2, "-2"), (0, "0"), (-0.0, "0"), (1e21, "1e+21"), (1e20, "100000000000000000000"),
            (1e-7, "1e-7"), (0.000001, "0.000001"), (123456789012345.6, "123456789012345.6"), (0.1, "0.1"),
            (1.2345e-10, "1.2345e-10"), (5e-324, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"), (1e16, "10000000000000000"),
        ]
        for (value, text) in cases { XCTAssertEqual(CanonicalJSON.jsNumber(value), text, "\(value)") }
    }

    private func declarations(_ edit: [String: String?]) throws -> [String: LocalOnlyTypeDeclarations] {
        let documents = try documents(edit)
        return try LocalOnlyDeclarations.of(documents: documents.map { (sourceName: $0.0, source: $0.1) }, sharedEnums: resolvers(documents))
    }

    // MARK: - Behavior 27

    func testCodegenStopsOnAnOptedInTypeFileWithAHook() throws {
        let journal = try text("journal.toml")
        let cases: [(String, String)] = [
            ("triggers", journal + "\n[triggers.entry6025]\ntriggers = [{ name = \"stamp\", on = \"create\", set = { weight = \"1\" } }]\n"),
            ("autoPopulatedFields", journal.replacingOccurrences(
                of: "allowLocalOnly = true", with: "allowLocalOnly = true\nautoPopulatedFields = { entry6025 = { title = \"auth.uid\" } }"
            )),
            ("timestamps", journal.replacingOccurrences(of: "allowLocalOnly = true", with: "allowLocalOnly = true\ntimestamps = { create = \"createdAt\" }")),
        ]
        for (hook, edited) in cases {
            XCTAssertThrowsError(try render(try documents(["journal.toml": edited])), hook) { error in
                let message = (error as? CodegenError)?.description ?? "\(error)"
                XCTAssertTrue(message.contains("journal.toml"), message)
                XCTAssertTrue(message.contains(hook), message)
                XCTAssertTrue(message.contains("allowLocalOnly"), message)
            }
        }
    }

    func testAHookOnATypeFileThatDoesNotOptInIsLeftAlone() throws {
        let catalog = try text("catalog.toml").replacingOccurrences(
            of: "name = \"catalog6025\"", with: "name = \"catalog6025\"\ntimestamps = { create = \"createdAt\" }"
        )
        XCTAssertNoThrow(try render(try documents(["catalog.toml": catalog])))
    }

    func testAModelNoInputDeclaresStopsCodegen() throws {
        XCTAssertThrowsError(try render(try documents(["catalog.toml": nil]))) { error in
            let message = (error as? CodegenError)?.description ?? "\(error)"
            XCTAssertTrue(message.contains("journal.toml"), message)
            XCTAssertTrue(message.contains("[type] models names \"tag6025\""), message)
        }
    }

    func testADefaultSwiftCannotPrintAsJsBaoDoesStopsCodegen() throws {
        let ledger = try text("ledger.toml")
        for (written, why) in [("2026-03-04T05:06:07Z", "offset zero"), ("2026-03-04T05:06:07.123456", "finer than a millisecond")] {
            let edited = ledger.replacingOccurrences(of: "default = 2026-03-04T05:06:07.250", with: "default = \(written)")
            XCTAssertThrowsError(try render(try documents(["ledger.toml": edited])), written) { error in
                let message = (error as? CodegenError)?.description ?? "\(error)"
                XCTAssertTrue(message.contains("ledger.toml"), message)
                XCTAssertTrue(message.contains(why), message)
            }
        }
    }

    // MARK: - Spec criterion 10 (pin)

    func testABuildWithNoOptedInTypeIsGeneratedAsBefore() throws {
        let none = try documents(["journal.toml": nil, "ledger.toml": nil])
        let plain = try XCTUnwrap(try render(none)["GeneratedModels.swift"])
        XCTAssertFalse(plain.contains("db3Types"), plain)
        let known = try XCTUnwrap(try render(none, knownTypesOnly: true)["GeneratedModels.swift"])
        XCTAssertTrue(known.contains("PrimitiveDb3Types(knownTypesOnly: true, types: [\n        PrimitiveDb3Types.DeclaredType(name: \"catalog6025\"),\n    ])"), known)
        XCTAssertFalse(known.contains("localOnly"), known)
    }
}
