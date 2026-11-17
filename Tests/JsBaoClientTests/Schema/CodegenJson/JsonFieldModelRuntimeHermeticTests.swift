import XCTest
@testable import JsBaoClient

/// #5899 phase 3 — one tree, both tools: the committed models in this
/// directory, which swift-bao-codegen writes for `db3-types/shop.toml` (whose
/// fields ref the object defs in `schemas/`), and `Generated/`, which
/// `primitive functions codegen --lang swift` writes for the tree (its
/// `Primitive.generated.swift` committed as `JsonShared.generated.swift`),
/// compiled together and run against a real client with no server.
///
/// A JSON field is read and written as its def's Swift type and stored as
/// canonical JSON text. A save validates an assigned value against the def's
/// compiled schema and writes nothing when it does not match; a stored text
/// that does not decode reads `nil`, stays in `<field>Raw`, and survives a
/// save that did not assign the field. The model is `Equatable`, `Hashable`
/// and `Codable` though the defs' types are not `Hashable`.
final class JsonFieldModelRuntimeHermeticTests: XCTestCase {

    private static let db3Id = "01JD5899JSONFIELDSXXXXXXXX"
    private var directories: [String] = []
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        JsBaoClient.clearDefault()
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        try await super.tearDown()
    }

    /// A client over its own SQLite store with no server, holding the db3
    /// `db3Id`, with the fixture's models registered and configured as the
    /// default client.
    private func client() async throws -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "/json-field-model-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: "json-field-model-5899",
            token: makeTestJwt(userId: "user-a"),
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        client.registerModels([JsonOrderRecord.self, JsonReceiptRecord.self])
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        JsBaoClient.configureDefault(client)
        let answer = """
        {"id": "\(Self.db3Id)", "title": "Shop", "createdBy": "user-a", "createdAt": "2026-11-13T00:00:00.000Z",
         "modifiedAt": "2026-11-13T00:00:00.000Z", "custodian": "user:user-a", "sync": true, "type": null, "tags": []}
        """
        _ = try await Db3API(lifecycle: client._db3Lifecycle, transport: RecordingTransport(status: 201, json: answer), client: client)
            .create(title: "Shop", custodian: "user:user-a")
        XCTAssertTrue(try XCTUnwrap(client.recordLogBinding(Self.db3Id)).isResident)
        return client
    }

    /// Order `id`'s stored values, as the store holds them.
    private func stored(_ client: JsBaoClient, _ id: String) -> [String: JSONValue]? {
        client.codegen.find(JsonOrderRecord.primitiveSchema, id: id)
    }

    /// Store `values` for order `id` as another writer would: any string.
    private func storeOrder(_ client: JsBaoClient, id: String, _ values: [String: PrimitiveValue]) throws -> PrimitiveRecord {
        try client.codegen.save(JsonOrderRecord.primitiveSchema, id: id, values: values, in: Self.db3Id)
    }

    private func valueError(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) -> Db3JSONValueError? {
        do {
            try body()
            XCTFail("expected a Db3JSONValueError", file: file, line: line)
            return nil
        } catch let error as Db3JSONValueError {
            return error
        } catch {
            XCTFail("expected a Db3JSONValueError, got \(error)", file: file, line: line)
            return nil
        }
    }

    private static let lisbon = ShipAddress(city: "Lisbon", zip: "1000-001", floor: 3, size: .m)
    private static let lisbonText = #"{"city":"Lisbon","floor":3,"size":"m","zip":"1000-001"}"#

    // MARK: - Behavior 27: the field is the def's type, stored as canonical JSON

    func testASavedValueIsStoredAsCanonicalTextAndReadsBackEqual() async throws {
        let client = try await client()
        let parcel = ShipParcel(label: "box", box: .init(width: 2.5, count: 9_007_199_254_740_992), codes: [3, 1])
        let order = JsonOrderRecord(id: "o1", title: "First", shipping_address: Self.lisbon, parcel: parcel,
                                    meta: ["b": .bool(true), "a": .number(1)], invoice: ShipInvoice(number: 7, extra: ["note": .string("x")]))
        let saved = try order.save(in: Self.db3Id)
        let row = try XCTUnwrap(stored(client, "o1"))
        XCTAssertEqual(row["shipping_address"], .string(Self.lisbonText))
        XCTAssertEqual(row["parcel"], .string(#"{"box":{"count":9007199254740992,"width":2.5},"codes":[3,1],"label":"box"}"#))
        XCTAssertEqual(row["meta"], .string(#"{"a":1,"b":true}"#))
        XCTAssertEqual(row["invoice"], .string(#"{"note":"x","number":7}"#))
        XCTAssertNil(row["needs"] ?? nil)

        for (path, read) in [("save", saved), ("find", try XCTUnwrap(try JsonOrderRecord.find("o1"))),
                             ("row", try XCTUnwrap(JsonOrderRecord(row: row)))] {
            XCTAssertEqual(read.shipping_address, Self.lisbon, path)
            XCTAssertEqual(read.parcel, parcel, path)
            XCTAssertEqual(read.meta, ["a": .number(1), "b": .bool(true)], path)
            XCTAssertEqual(read.invoice, ShipInvoice(number: 7, extra: ["note": .string("x")]), path)
            XCTAssertEqual(read.shipping_addressRaw, Self.lisbonText, path)
            XCTAssertEqual(read._changedFields, [], path)
            XCTAssertEqual(read, order, path)
        }
    }

    func testAssigningNilClearsTheField() async throws {
        let client = try await client()
        var order = try JsonOrderRecord(id: "o2", shipping_address: Self.lisbon).save(in: Self.db3Id)
        order.shipping_address = nil
        XCTAssertNil(order.shipping_addressRaw)
        XCTAssertEqual(order._changedFields, ["shipping_address"])
        order = try order.save(in: Self.db3Id)
        XCTAssertNil(order.shipping_address)
        let cleared = stored(client, "o2")?["shipping_address"]
        XCTAssertTrue(cleared == nil || cleared == .null, "\(String(describing: cleared))")
    }

    // MARK: - Behaviors 24 and 30: a value the def refuses is never written

    func testAValueThatBreaksTheDefThrowsAndWritesNothing() async throws {
        let client = try await client()
        let cases: [(ShipAddress, String, String)] = [
            (ShipAddress(city: ""), "value.city", "value.city must be at least 1 characters"),
            (ShipAddress(city: "Faro", floor: 201), "value.floor", "value.floor must be <= 200"),
            (ShipAddress(city: "Faro", zip: "8000-1"), "value.zip", "value.zip must match the pattern ^[0-9]{4}(-[0-9]{3})?$"),
        ]
        for (index, (address, path, reason)) in cases.enumerated() {
            let id = "bad\(index)"
            let error = valueError { try JsonOrderRecord(id: id, title: "T", shipping_address: address).save(in: Self.db3Id) }
            XCTAssertEqual(error, Db3JSONValueError(model: "json_orders", field: "shipping_address", def: "schemas.common.ShipAddress",
                                                    path: path, reason: reason, kind: .schema), path)
            XCTAssertNil(stored(client, id), "nothing is written for \(path)")
        }

        // An enum the def declares, outside the value's Swift type.
        let priority = valueError { _ = try JsonOrderRecord(id: "bad-enum", invoice: ShipInvoice(number: 1, priority: .number(5))).save(in: Self.db3Id) }
        XCTAssertEqual(priority?.path, "value.priority")
        XCTAssertEqual(priority?.reason, "value.priority must be one of 1, 2, 3")
        XCTAssertNil(stored(client, "bad-enum"))

        // A held record keeps its value.
        var held = try JsonOrderRecord(id: "held", shipping_address: Self.lisbon).save(in: Self.db3Id)
        held.shipping_address = ShipAddress(city: String(repeating: "x", count: 41))
        XCTAssertEqual(valueError { _ = try held.save(in: Self.db3Id) }?.path, "value.city")
        XCTAssertEqual(stored(client, "held")?["shipping_address"], .string(Self.lisbonText))
    }

    func testAnIntegerAbove2To53IsRefusedAndNoRoundedValueIsWritten() async throws {
        let client = try await client()
        for count in [9_007_199_254_740_993, -9_007_199_254_740_993] {
            let order = JsonOrderRecord(id: "big", parcel: ShipParcel(label: "L", box: .init(width: 1, count: count)))
            let error = valueError { _ = try order.save(in: Self.db3Id) }
            XCTAssertEqual(error?.kind, .number)
            XCTAssertEqual(error?.path, "value.box.count")
            XCTAssertNil(stored(client, "big"))
        }
        var order = try JsonOrderRecord(id: "big", parcel: ShipParcel(label: "L", codes: [1])).save(in: Self.db3Id)
        order.parcel?.codes = [9_007_199_254_740_993]
        XCTAssertEqual(valueError { _ = try order.save(in: Self.db3Id) }?.path, "value.codes[0]")
        XCTAssertEqual(stored(client, "big")?["parcel"], .string(#"{"codes":[1],"label":"L"}"#), "no rounded value was written")
    }

    // MARK: - Behaviors 25 and 31: a stored value that does not decode

    func testAStoredValueThatDoesNotDecodeReadsNilKeepsItsTextAndSurvivesOtherSaves() async throws {
        let client = try await client()
        let record = try storeOrder(client, id: "o3", ["title": .string("Old"), "shipping_address": .string("[\"not an object\"]"),
                                                       "parcel": .string("{\"label\":7}")])
        for (path, order) in [("record", try XCTUnwrap(JsonOrderRecord(record: record))),
                              ("row", try XCTUnwrap(JsonOrderRecord(row: try XCTUnwrap(stored(client, "o3"))))),
                              ("query", try XCTUnwrap(try JsonOrderRecord.query(options: QueryOptions(db3: [Self.db3Id])).first { $0.id == "o3" }))] {
            XCTAssertNil(order.shipping_address, path)
            XCTAssertEqual(order.shipping_addressRaw, "[\"not an object\"]", path)
            XCTAssertNil(order.parcel, path)
            XCTAssertEqual(order.parcelRaw, "{\"label\":7}", path)
            XCTAssertEqual(order.title, "Old", path)
            XCTAssertEqual(order.primitiveValues()["shipping_address"], .string("[\"not an object\"]"), path)
        }
        XCTAssertTrue(Db3JSONMisreads.wasReported(model: "json_orders", field: "shipping_address"))
        XCTAssertTrue(Db3JSONMisreads.wasReported(model: "json_orders", field: "parcel"))

        // A save that assigned another field leaves the text as stored.
        var order = try XCTUnwrap(JsonOrderRecord(record: record))
        order.title = "New"
        let saved = try order.save(in: Self.db3Id)
        XCTAssertEqual(saved.title, "New")
        XCTAssertEqual(stored(client, "o3")?["shipping_address"], .string("[\"not an object\"]"))
        XCTAssertEqual(stored(client, "o3")?["parcel"], .string("{\"label\":7}"))

        // A full copy writes the stored text back, unvalidated.
        var copy = saved
        copy.markAllChanged()
        _ = try storeOrder(client, id: "o3", ["shipping_address": .string("{\"city\":\"Porto\"}")])
        _ = try copy.save(in: Self.db3Id)
        XCTAssertEqual(stored(client, "o3")?["shipping_address"], .string("[\"not an object\"]"))
    }

    // MARK: - Edge cases

    func testTwoOpenObjectDefsOfOneSwiftTypeEachValidateAgainstTheirOwnSchema() async throws {
        let client = try await client()
        let empty: [String: JSONValue] = [:]
        XCTAssertNoThrow(try JsonOrderRecord(id: "m1", meta: empty).save(in: Self.db3Id))
        XCTAssertEqual(stored(client, "m1")?["meta"], .string("{}"))
        let error = valueError { _ = try JsonOrderRecord(id: "m2", needs: empty).save(in: Self.db3Id) }
        XCTAssertEqual(error, Db3JSONValueError(model: "json_orders", field: "needs", def: "schemas.common.ShipNeedsKind",
                                                path: "value.kind", reason: "value.kind is required", kind: .schema))
        XCTAssertNil(stored(client, "m2"))
        XCTAssertNoThrow(try JsonOrderRecord(id: "m2", needs: ["kind": .string("x")]).save(in: Self.db3Id))
        XCTAssertTrue(ShipMeta.self == ShipNeedsKind.self, "both defs are one Swift type")
    }

    func testAnOpenObjectStoresAnExtraKeyAndAClosedStructDropsOne() async throws {
        let client = try await client()
        _ = try storeOrder(client, id: "x1", ["invoice": .string(#"{"number":1,"po":"A7"}"#), "shipping_address": .string(#"{"city":"Faro","country":"PT"}"#)])
        var order = try XCTUnwrap(try JsonOrderRecord.find("x1"))
        XCTAssertEqual(order.invoice, ShipInvoice(number: 1, extra: ["po": .string("A7")]))
        XCTAssertEqual(order.shipping_address, ShipAddress(city: "Faro"), "a closed def's struct reads the keys it declares")
        order.invoice?.number = 2
        order.shipping_address?.floor = 1
        _ = try order.save(in: Self.db3Id)
        XCTAssertEqual(stored(client, "x1")?["invoice"], .string(#"{"number":2,"po":"A7"}"#))
        XCTAssertEqual(stored(client, "x1")?["shipping_address"], .string(#"{"city":"Faro","floor":1}"#))
    }

    func testAnInPlaceChangeMarksTheFieldAndTheNextSaveWritesIt() async throws {
        let client = try await client()
        var order = try JsonOrderRecord(id: "o4", shipping_address: Self.lisbon).save(in: Self.db3Id)
        XCTAssertEqual(order._changedFields, [])
        order.shipping_address?.city = "Porto"
        XCTAssertEqual(order._changedFields, ["shipping_address"])
        XCTAssertNil(order.shipping_addressRaw)
        order = try order.save(in: Self.db3Id)
        XCTAssertEqual(stored(client, "o4")?["shipping_address"], .string(#"{"city":"Porto","floor":3,"size":"m","zip":"1000-001"}"#))
        XCTAssertEqual(order.shipping_address?.city, "Porto")
    }

    func testARequiredJSONFieldWithNoValueIsRefusedByTheRequiredCheck() async throws {
        let client = try await client()
        XCTAssertThrowsError(try JsonReceiptRecord(id: "r1").save(in: Self.db3Id)) { error in
            XCTAssertFalse(error is Db3JSONValueError, "\(error)")
        }
        XCTAssertNil(client.codegen.find(JsonReceiptRecord.primitiveSchema, id: "r1"))
        let saved = try JsonReceiptRecord(id: "r1", address: Self.lisbon).save(in: Self.db3Id)
        XCTAssertEqual(saved.address, Self.lisbon)
    }

    func testEqualityComparesTheValueAndHashingOnlyItsPresence() {
        let a = JsonOrderRecord(id: "e", title: "T", shipping_address: ShipAddress(city: "Lisbon"))
        let b = JsonOrderRecord(id: "e", title: "T", shipping_address: ShipAddress(city: "Porto"))
        let c = JsonOrderRecord(id: "e", title: "T", shipping_address: ShipAddress(city: "Lisbon"))
        let none = JsonOrderRecord(id: "e", title: "T")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue, "only whether the field holds a value is hashed")
        XCTAssertEqual(a, c)
        XCTAssertEqual(a.hashValue, c.hashValue)
        XCTAssertNotEqual(a, none)
        let set: Set<JsonOrderRecord> = [a, b, c, none]
        XCTAssertEqual(set.count, 3)
        let byOrder: [JsonOrderRecord: String] = [a: "lisbon", b: "porto"]
        XCTAssertEqual(byOrder[c], "lisbon")
        XCTAssertEqual(byOrder[b], "porto")
        XCTAssertNil(byOrder[none])
    }

    func testACodableRoundTripCarriesTheValueAndMarksItChanged() throws {
        let order = JsonOrderRecord(id: "c1", shipping_address: Self.lisbon, meta: ["k": .string("v")])
        let data = try JSONEncoder().encode(order)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["shipping_address"] as? [String: Any])?["city"] as? String, "Lisbon")
        XCTAssertNil(json["shipping_addressRaw"])
        let decoded = try JSONDecoder().decode(JsonOrderRecord.self, from: data)
        XCTAssertEqual(decoded, order)
        XCTAssertTrue(decoded._changedFields.contains("shipping_address"))
    }

    func testTheRawTextIsReadOnlyAndAStringCannotBeAssignedToTheField() {
        XCTAssertFalse(Self.writable(\JsonOrderRecord.shipping_addressRaw), "shipping_addressRaw has no setter outside its file")
        XCTAssertTrue(Self.writable(\JsonOrderRecord.shipping_address))
        let typed: WritableKeyPath<JsonOrderRecord, Db3JSON_common_ShipAddress?> = \JsonOrderRecord.shipping_address
        XCTAssertNotNil(typed)
        XCTAssertFalse((ShipAddress.self as Any.Type) is any ExpressibleByStringLiteral.Type, "a String literal is not a ShipAddress")
        XCTAssertEqual(Db3JSONDef_common_ShipAddress.id, "schemas.common.ShipAddress")
        XCTAssertTrue(Db3JSONDef_billing_v2_ShipInvoice.Value.self == ShipInvoice.self)
    }

    private static func writable<Root, Value>(_ path: KeyPath<Root, Value>) -> Bool { false }
    private static func writable<Root, Value>(_ path: WritableKeyPath<Root, Value>) -> Bool { true }
}
