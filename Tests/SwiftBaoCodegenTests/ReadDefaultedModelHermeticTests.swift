import Foundation
import XCTest
@testable import swift_bao_codegen

/// #6304 phase 2 — the committed models under
/// `JsBaoClientTests/Schema/CodegenReadDefaults/`, which the client's test
/// target compiles and reads records through
/// (`ReadDefaultedModelReadHermeticTests`), are what the tool writes for that
/// directory's `db3-types/marks.toml`.
final class ReadDefaultedModelHermeticTests: XCTestCase {

    private static let fixture: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("Tests/JsBaoClientTests/Schema/CodegenReadDefaults")
    }()

    func testTheCommittedModelsAreWhatTheToolWritesForTheFixture() throws {
        let inputs = try CodegenInputs.read(try CodegenInputs.expand([Self.fixture.appendingPathComponent("db3-types").path]))
        let files = try CodegenRun.render(
            documents: inputs.map { (sourceName: $0.sourceName, source: $0.source) },
            sharedEnums: CodegenInputs.sharedEnumFiles(for: inputs),
            emptyLabel: "",
            accessLevel: "public",
            moduleImport: "JsBaoClient",
            swiftNameSuffix: "Record",
            strict: true
        )
        let models = files.filter { $0.fileName != SwiftEmitter.barrelFileName }
        XCTAssertEqual(models.map(\.fileName).sorted(), ["MarkBareRecord.swift", "MarkKeyRecord.swift", "MarkRecord.swift"])
        for (fileName, source) in models {
            let committed = try String(contentsOf: Self.fixture.appendingPathComponent(fileName), encoding: .utf8)
            XCTAssertEqual(source, committed, "\(fileName) is stale; regenerate it with swift-bao-codegen --input \(Self.fixture.path)/db3-types")
        }
    }
}
