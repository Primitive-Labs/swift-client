import Foundation
import XCTest
@testable import swift_bao_codegen

/// #6307 behavior 16 — the model `swift-bao-codegen` writes for a db3 JSON
/// field whose def is a list: an Optional property typed by the alias
/// `primitive functions codegen --lang swift` declares, decoded through the
/// def's binding, with its raw text, as for an object def's field. The
/// committed `CodegenJson/JsonOrderRecord.swift` carries two (`tags`, `stops`)
/// and is what the tool writes.
final class JsonListFieldCodegenHermeticTests: XCTestCase {

    private static let tree: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<2 { root.deleteLastPathComponent() }
        return root.appending(path: "JsBaoClientTests/Schema/CodegenJson")
    }()

    private func rendered() throws -> [String: String] {
        let inputs = try CodegenInputs.read(try CodegenInputs.expand([Self.tree.appending(path: "db3-types").path]))
        let files = try CodegenRun.render(
            documents: inputs.map { (sourceName: $0.sourceName, source: $0.source) },
            sharedEnums: CodegenInputs.sharedEnumFiles(for: inputs),
            emptyLabel: "",
            accessLevel: "public",
            moduleImport: "JsBaoClient",
            swiftNameSuffix: "Record",
            strict: true
        )
        return Dictionary(uniqueKeysWithValues: files.map { ($0.fileName, $0.source) })
    }

    func testAListFieldIsAnOptionalAliasedPropertyDecodedThroughItsBinding() throws {
        let order = try XCTUnwrap(try rendered()["JsonOrderRecord.swift"])
        XCTAssertTrue(order.contains(#""tags":             FieldDescriptor(type: .string),"#), order)
        XCTAssertTrue(order.contains("    public var tags: Db3JSON_common_ShipTags? {\n"), order)
        XCTAssertTrue(order.contains("    public var stops: Db3JSON_common_ShipStops? {\n"), order)
        XCTAssertTrue(order.contains("    public private(set) var tagsRaw: String?\n"), order)
        XCTAssertTrue(order.contains(#"self.tags = Db3JSONDef_common_ShipTags.value(fromStored: record["tags"]?.asString, model: Self.modelName, field: "tags")"#), order)
        let committed = try String(contentsOf: Self.tree.appending(path: "JsonOrderRecord.swift"), encoding: .utf8)
        XCTAssertEqual(order, committed, "JsonOrderRecord.swift is stale; regenerate it from CodegenJson/db3-types/shop.toml")
    }
}
