import Foundation
import XCTest
@testable import swift_bao_codegen

/// #5899 behavior 27 — the model `swift-bao-codegen` writes for a db3 JSON
/// field.
///
/// The field is an Optional property typed `Db3JSON_<file>_<Name>`, the alias
/// `primitive functions codegen --lang swift` declares in
/// `Primitive.generated.swift`, required or not (`required` is checked at
/// save). A record and a row decode it through the def's binding enum, its
/// stored text stays in `<field>Raw`, and every write door saves
/// `_validatedPrimitiveValues()`, which encodes an assigned value and
/// validates it against the def. `==` compares the field's value; `hash(into:)`
/// combines only whether it holds one, so the def's type need not be
/// `Hashable`. The committed models beside `CodegenJson/db3-types/shop.toml`,
/// which the client's test target compiles with
/// `Generated/JsonShared.generated.swift` and runs
/// (`JsonFieldModelRuntimeHermeticTests`), are what the tool writes for it.
final class JsonFieldCodegenHermeticTests: XCTestCase {

    private static let tree: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<2 { root.deleteLastPathComponent() }
        return root.appending(path: "JsBaoClientTests/Schema/CodegenJson")
    }()

    /// What the tool writes for the tree's type file, by file name.
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

    func testTheCommittedModelsAreWhatTheToolWrites() throws {
        let files = try rendered()
        XCTAssertEqual(files.keys.sorted(), ["GeneratedModels.swift", "JsonOrderRecord.swift", "JsonReceiptRecord.swift"])
        for name in ["JsonOrderRecord.swift", "JsonReceiptRecord.swift"] {
            let committed = try String(contentsOf: Self.tree.appending(path: name), encoding: .utf8)
            XCTAssertEqual(files[name], committed, "\(name) is stale; regenerate it from CodegenJson/db3-types/shop.toml")
        }
    }

    func testAJSONFieldIsAnOptionalAliasedPropertyWithItsRawText() throws {
        let order = try XCTUnwrap(try rendered()["JsonOrderRecord.swift"])
        XCTAssertTrue(order.contains(#""shipping_address": FieldDescriptor(type: .string),"#), order)
        XCTAssertTrue(order.contains("    public var shipping_address: Db3JSON_common_ShipAddress? {\n"
            + "        didSet {\n"
            + "            _changedFields.insert(\"shipping_address\")\n"
            + "            shipping_addressRaw = nil\n"
            + "        }\n"
            + "    }\n"), order)
        XCTAssertTrue(order.contains("    public private(set) var shipping_addressRaw: String?\n"), order)
        XCTAssertTrue(order.contains("    public var invoice: Db3JSON_billing_v2_ShipInvoice? {\n"), order)
        XCTAssertTrue(order.contains("    public var meta: Db3JSON_common_ShipMeta? {\n"), order)
        XCTAssertTrue(order.contains("        shipping_address: Db3JSON_common_ShipAddress? = nil,\n"), order)
    }

    func testARecordAndARowDecodeThroughTheBinding() throws {
        let order = try XCTUnwrap(try rendered()["JsonOrderRecord.swift"])
        XCTAssertTrue(order.contains("        self.shipping_addressRaw = record[\"shipping_address\"]?.asString\n"
            + "        self.shipping_address = Db3JSONDef_common_ShipAddress.value(fromStored: record[\"shipping_address\"]?.asString, "
            + "model: Self.modelName, field: \"shipping_address\")\n"), order)
        XCTAssertTrue(order.contains("        self.shipping_addressRaw = row[\"shipping_address\"]?.stringValue\n"
            + "        self.shipping_address = Db3JSONDef_common_ShipAddress.value(fromStored: row[\"shipping_address\"]?.stringValue, "
            + "model: Self.modelName, field: \"shipping_address\")\n"), order)
        XCTAssertTrue(order.contains("        self.shipping_address = try container.decodeIfPresent(Db3JSON_common_ShipAddress.self, forKey: .shipping_address)\n"), order)
    }

    func testEveryWriteDoorSavesTheValidatedValues() throws {
        let order = try XCTUnwrap(try rendered()["JsonOrderRecord.swift"])
        XCTAssertTrue(order.contains("        if let shipping_addressRaw { values[\"shipping_address\"] = .string(shipping_addressRaw) } "
            + "else if let shipping_address, let text = Db3JSONDef_common_ShipAddress.canonicalText(shipping_address) { values[\"shipping_address\"] = .string(text) }\n"), order)
        XCTAssertTrue(order.contains("    public func _validatedPrimitiveValues() throws -> [String: PrimitiveValue] {\n"), order)
        XCTAssertTrue(order.contains("        if shipping_addressRaw == nil, let shipping_address {\n"
            + "            values[\"shipping_address\"] = .string(try Db3JSONDef_common_ShipAddress.storedText(for: shipping_address, model: Self.modelName, field: \"shipping_address\"))\n"
            + "        }\n"), order)
        XCTAssertFalse(order.contains("values: primitiveValues()"), order)
        XCTAssertEqual(order.components(separatedBy: "values: try _validatedPrimitiveValues()").count - 1, 5, order)
    }

    func testEqualityComparesTheValueAndHashingOnlyItsPresence() throws {
        let order = try XCTUnwrap(try rendered()["JsonOrderRecord.swift"])
        XCTAssertTrue(order.contains("        lhs.shipping_address == rhs.shipping_address &&\n"), order)
        XCTAssertTrue(order.contains("        hasher.combine(shipping_address != nil)\n"), order)
        XCTAssertFalse(order.contains("hasher.combine(shipping_address)\n"), order)
        XCTAssertFalse(order.contains("hasher.combine(shipping_addressRaw"), order)
        XCTAssertTrue(order.contains("        case id, title, shipping_address, parcel, meta, needs, invoice\n"), order)
    }

    func testARequiredJSONFieldIsOptionalAndCheckedAtSave() throws {
        let receipt = try XCTUnwrap(try rendered()["JsonReceiptRecord.swift"])
        XCTAssertTrue(receipt.contains(#""address": FieldDescriptor(type: .string, required: true),"#), receipt)
        XCTAssertTrue(receipt.contains("    public var address: Db3JSON_common_ShipAddress? {\n"), receipt)
        XCTAssertTrue(receipt.contains("        address: Db3JSON_common_ShipAddress? = nil\n"), receipt)
        XCTAssertFalse(receipt.contains("let address = record"), receipt)
        XCTAssertFalse(receipt.contains("let address = row"), receipt)
    }

    func testAFieldNamedLikeAJSONFieldsRawTextIsRefused() {
        let shared = SharedEnums(files: [("common", "[defs.Address]\ntype = \"object\"\n")], dir: "schemas/", objects: true)
        let toml = "[type]\nname = \"shop\"\n\n[models.orders.fields.ship]\nref = \"Address\"\n\n[models.orders.fields.shipRaw]\ntype = \"string\"\n"
        XCTAssertThrowsError(try CodegenRun.render(
            documents: [(sourceName: "shop.toml", source: toml)], sharedEnums: [shared], emptyLabel: "",
            accessLevel: "public", moduleImport: "JsBaoClient", swiftNameSuffix: "Record", strict: true
        )) { error in
            XCTAssertEqual((error as? CodegenError)?.description,
                           "Model `orders` field `ship` refs the object def `Address`, so its stored text is the generated property `shipRaw`, "
                           + "and field `shipRaw` takes that name. Rename one of the two fields.")
        }
    }
}
