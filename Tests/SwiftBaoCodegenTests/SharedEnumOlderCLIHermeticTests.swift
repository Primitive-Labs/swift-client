import Foundation
import XCTest
@testable import swift_bao_codegen

/// #5896 edge case — the models this swift-bao-codegen writes compile against
/// a `Primitive.generated.swift` that an older CLI wrote.
///
/// A model field that refs a shared enum is typed by the enum's short name,
/// which the CLI declares in `Primitive.generated.swift`. The CLI and
/// swift-bao-codegen are pinned separately, so an app can upgrade the package
/// before it reruns `primitive functions codegen --lang swift`. The CLI
/// already declared `enum <Name>` for every `schemas/` def before this change,
/// so the new models compile against that file as it stands.
///
/// `tests/fixtures/swift-shared-enums-older-cli-5896/Primitive.generated.swift`
/// is what `primitive functions codegen --lang swift` wrote for the tree below
/// before this change, kept byte for byte. The test renders the tree's models
/// in process and runs `swiftc -typecheck` over them twice, against the
/// `JsBaoClient` module this test run built: alone, where they must fail on
/// the shared names (so the check is about those names), and with the older
/// file, where they must compile.
final class SharedEnumOlderCLIHermeticTests: XCTestCase {

    private static let packageRoot: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }()

    private static let olderSharedFile = packageRoot
        .deletingLastPathComponent()
        .appendingPathComponent("tests/fixtures/swift-shared-enums-older-cli-5896/Primitive.generated.swift")

    private static let common = """
        [defs.Phase]
        type = "string"
        enum = ["open", "closed"]

        [defs.Lane]
        type = "string"
        enum = ["on hold", "done"]
        """

    private static let board = """
        [type]
        name = "board"

        [models.cards]
        class_name = "CardRecord"

        [models.cards.fields.title]
        type = "string"

        [models.cards.fields.phase]
        ref = "Phase"
        default = "open"

        [models.cards.fields.lane]
        ref = "Lane"
        required = true

        [models.tickets]
        class_name = "TicketRecord"

        [models.tickets.fields.lane]
        ref = "Lane"

        [models.tickets.fields.priority]
        type = "string"
        enum = ["low", "high"]
        """

    func testTheModelsCompileAgainstAPrimitiveGeneratedSwiftAnOlderCLIWrote() throws {
        let older = try String(contentsOf: Self.olderSharedFile, encoding: .utf8)
        XCTAssertTrue(older.contains("public enum Phase: String, Codable, CaseIterable, Sendable {"), older)
        XCTAssertTrue(older.contains("public enum Lane: String, Codable, CaseIterable, Sendable {"), older)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-enum-older-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = try renderModels(into: directory)
        XCTAssertEqual(models.map(\.lastPathComponent).sorted(), ["CardRecord.swift", "TicketRecord.swift"])

        let alone = try typecheck(models)
        XCTAssertNotEqual(alone.status, 0, "the models must use the shared enums Primitive.generated.swift declares")
        XCTAssertTrue(alone.output.contains("cannot find type 'Phase' in scope"), alone.output)
        XCTAssertTrue(alone.output.contains("cannot find type 'Lane' in scope"), alone.output)

        let withOlder = try typecheck(models + [Self.olderSharedFile])
        XCTAssertEqual(withOlder.status, 0, withOlder.output)
    }

    // MARK: - Helpers

    /// The tree's models as this swift-bao-codegen writes them, one file each.
    private func renderModels(into directory: URL) throws -> [URL] {
        let files = try CodegenRun.render(
            documents: [(sourceName: "board.toml", source: Self.board)],
            sharedEnums: [SharedEnums(files: [("common", Self.common)], dir: "schemas/")],
            emptyLabel: "",
            accessLevel: "public",
            moduleImport: "JsBaoClient",
            swiftNameSuffix: "Record",
            strict: true
        )
        return try files.filter { $0.fileName != SwiftEmitter.barrelFileName }.map { file in
            let url = directory.appendingPathComponent(file.fileName)
            try file.source.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    /// `swiftc -typecheck` over `files`, importing the `JsBaoClient` module
    /// from the products directory this test bundle was built into.
    private func typecheck(_ files: [URL]) throws -> (status: Int32, output: String) {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let modules = [products, products.appendingPathComponent("Modules")]
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("JsBaoClient.swiftmodule").path) }
        guard let moduleDirectory = modules.first else {
            XCTFail("no JsBaoClient.swiftmodule in \(products.path); run the package's tests, which build it")
            return (-1, "")
        }
        var arguments = ["-typecheck", "-swift-version", "6", "-parse-as-library", "-I", moduleDirectory.path]
        let include = products.appendingPathComponent("include")
        if FileManager.default.fileExists(atPath: include.path) { arguments += ["-I", include.path] }
        for map in moduleMaps(products) { arguments += ["-Xcc", "-fmodule-map-file=\(map.path)"] }
        let (executable, prefix) = swiftc()
        return try run(executable, prefix + arguments + files.map(\.path))
    }

    /// The C module maps the package's modules were built with: the build
    /// system's generated maps beside the products (`swift build` on macOS),
    /// or each target's own under the products directory (the native build).
    private func moduleMaps(_ products: URL) -> [URL] {
        let fm = FileManager.default
        let generated = products
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Intermediates.noindex/GeneratedModuleMaps")
        var maps: [URL] = []
        if let names = try? fm.contentsOfDirectory(atPath: generated.path) {
            maps += names.filter { $0.hasSuffix(".modulemap") }.sorted().map { generated.appendingPathComponent($0) }
        }
        if let names = try? fm.contentsOfDirectory(atPath: products.path) {
            for name in names.sorted() where name.hasSuffix(".build") {
                let map = products.appendingPathComponent(name).appendingPathComponent("module.modulemap")
                if fm.fileExists(atPath: map.path) { maps.append(map) }
            }
        }
        return maps
    }

    /// The `swiftc` of the toolchain running this test: through `xcrun` on
    /// macOS, so the compiler is handed an SDK, and off `PATH` elsewhere.
    private func swiftc() -> (URL, [String]) {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        if FileManager.default.isExecutableFile(atPath: xcrun.path) { return (xcrun, ["swiftc"]) }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["swiftc"])
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain before waiting: a full pipe buffer would deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
