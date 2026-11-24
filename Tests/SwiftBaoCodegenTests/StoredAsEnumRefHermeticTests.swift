import Foundation
import XCTest
@testable import swift_bao_codegen

/// `swift-bao-codegen` over a renamed field that refs a shared enum (#6026
/// behavior 12; project `db3-type-lifecycle` phase 8, the E3 case moved
/// there by the intent's 2026-11-17 decision).
///
/// The fixture `Fixtures/stored-as-enum-ref-6026/db3-types/workspace.toml`
/// declares `state` with `ref = "Status"`, `enforce_enum = true` and
/// `storedAs = "status"`; it is the type file the TypeScript codegen test
/// (`codegen-stored-as-enum-ref-6026`) generates from. The emitted model keeps
/// the enum accessor under the current name, stores its raw string under the
/// stored name in `CodingKeys` and wherever generated code names the field to
/// the runtime, and carries the current-to-stored map.
///
/// The shared enum is passed in memory, as `LocalOnlyCodegenHermeticTests`
/// does, so no `schemas/` file joins the repository-wide schema pins.
///
/// Hermetic: `CodegenRun` over the fixture file, read from disk by `#filePath`.
final class StoredAsEnumRefHermeticTests: XCTestCase {

    private static let sharedEnums = "[defs.Status]\ntype = \"string\"\nenum = [\"open\", \"doing\", \"done\"]\n"

    private static var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/stored-as-enum-ref-6026/db3-types/workspace.toml")
    }

    private func model() throws -> String {
        let source = try String(contentsOf: Self.fixture, encoding: .utf8)
        let inputs = [CodegenInput(path: "/fixture/db3-types/workspace.toml", sourceName: "workspace.toml", source: source)]
        let shared = SharedEnums(
            files: [("common", Self.sharedEnums)], dir: "/fixture/schemas/", db3: CodegenInputs.typeNames(inputs), objects: true
        )
        let files = try CodegenRun.render(
            documents: [(sourceName: "workspace.toml", source: source)],
            sharedEnums: [shared],
            emptyLabel: "db3-types/",
            accessLevel: "public",
            moduleImport: "JsBaoClient",
            swiftNameSuffix: "Record",
            strict: true
        )
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.fileName, $0.source) })
        return try XCTUnwrap(byName["Task6026.swift"], "files: \(byName.keys.sorted())")
    }

    func testCodingKeysNameTheStoredFieldAndTheEnumAccessorKeepsTheCurrentName() throws {
        let swift = try model()
        // The enum accessor is under the current name; its raw string is coded under the stored name.
        XCTAssertTrue(swift.contains("public var state: Status? {"), swift)
        XCTAssertTrue(swift.contains("stateRaw = \"status\""), swift)
        XCTAssertFalse(swift.contains("var status:"), swift)
        // The runtime sees only the stored name.
        XCTAssertTrue(swift.contains("\"status\": FieldDescriptor("), swift)
        XCTAssertFalse(swift.contains("\"state\": FieldDescriptor("), swift)
        XCTAssertTrue(swift.contains("_changedFields.insert(\"status\")"), swift)
        XCTAssertFalse(swift.contains("record[\"state\"]"), swift)
        XCTAssertFalse(swift.contains("row[\"state\"]"), swift)
        // The current-to-stored map and the type it comes from.
        XCTAssertTrue(swift.contains("fieldNames: [\"state\": \"status\"]"), swift)
        XCTAssertTrue(swift.contains("fieldNameTypes: [\"workspace6026\"]"), swift)
    }
}
