import Foundation
import XCTest
@testable import swift_bao_codegen

/// #6304 behavior 60 — the committed `ParityRecord.swift` under
/// `JsBaoClientTests/Schema/CodegenReadDefaultParity/`, which the client's
/// test target compiles and reads the parity fixture's stored values through
/// (`ReadDefaultParityHermeticTests`), and which
/// `cli/tests/unit/read-default-parity-6304.test.ts` reads as the Swift
/// emitter's answer, is what the tool writes for that directory's
/// `db3-types/parity.toml`.
final class ReadDefaultParityCodegenHermeticTests: XCTestCase {

    private static let fixture: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("Tests/JsBaoClientTests/Schema/CodegenReadDefaultParity")
    }()

    func testTheCommittedModelIsWhatTheToolWritesForTheFixture() throws {
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
        XCTAssertEqual(models.map(\.fileName), ["ParityRecord.swift"])
        for (fileName, source) in models {
            let committed = try String(contentsOf: Self.fixture.appendingPathComponent(fileName), encoding: .utf8)
            XCTAssertEqual(source, committed, "\(fileName) is stale; regenerate it with swift-bao-codegen --input \(Self.fixture.path)/db3-types")
        }
    }
}
