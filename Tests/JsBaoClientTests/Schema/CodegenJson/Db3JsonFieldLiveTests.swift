import XCTest
@testable import JsBaoClient

/// #5899 behaviors 29 to 31 — a generated model's db3 JSON field, live
/// against the local server.
///
/// - A save of an assigned JSON field stores the value's canonical text in the
///   room (read back through the records API), and a fresh read on another
///   client decodes an equal struct; a record whose field was written as that
///   text through the records API decodes too.
/// - A save whose value breaks a bound, a pattern or an enum of the def, or
///   holds an `Int` above 2^53 in magnitude, throws `Db3JSONValueError`, and
///   nothing is queued or stored: the room's row shows no rounded value.
/// - Text stored through the records API that does not decode reads `nil`,
///   stays in `<field>Raw`, and is unchanged by a save of another field.
@available(*, deprecated)
final class Db3JsonFieldLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-json-fields")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        JsBaoClient.clearDefault()
        await live?.destroy()
        await ctx?.cleanup()
    }

    private static let model = JsonOrderRecord.modelName
    private static let lisbon = ShipAddress(city: "Lisbon", zip: "1000-001", floor: 3, size: .m)
    private static let lisbonText = #"{"city":"Lisbon","floor":3,"size":"m","zip":"1000-001"}"#

    /// One client on a fresh db3, configured as the default client.
    private func single() async throws -> (String, JsBaoClient) {
        let x = try await live.client("x", models: [JsonOrderRecord.primitiveSchema])
        let documentId = try await live.createDocument(x)
        try await live.open(x, documentId)
        JsBaoClient.configureDefault(x)
        return (documentId, x)
    }

    private func roomRow(_ documentId: String, _ id: String) async throws -> [String: Any]? {
        try await live.roomRows(documentId, Self.model)[id]
    }

    /// Write `data` for record `id` through the records API, as another writer would.
    private func putRecord(_ documentId: String, _ id: String, _ data: [String: Any]) async throws {
        _ = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/documents/\(documentId)/records/\(Self.model)",
            body: ["id": id, "data": data], jwt: live.app.ownerJWT
        )
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

    // MARK: - Behavior 29

    func testASavedValueIsTheCanonicalTextInTheRoomAndDecodesOnAnotherClient() async throws {
        let (documentId, x) = try await single()
        let parcel = ShipParcel(label: "box", box: .init(width: 2.5, count: 9_007_199_254_740_992), codes: [3, 1])
        try JsonOrderRecord(id: "o1", title: "First", shipping_address: Self.lisbon, parcel: parcel).save(in: documentId)
        try await live.settled(x, documentId)

        let row = try await roomRow(documentId, "o1")
        XCTAssertEqual(row?["shipping_address"] as? String, Self.lisbonText)
        XCTAssertEqual(row?["parcel"] as? String, #"{"box":{"count":9007199254740992,"width":2.5},"codes":[3,1],"label":"box"}"#)

        let y = try await live.client("y", models: [JsonOrderRecord.primitiveSchema])
        try await live.open(y, documentId)
        let members = try live.member(y, documentId, Self.model)
        try await eventually(timeout: 20, description: "y to hold o1") { members.find(id: "o1") != nil }
        let read = try XCTUnwrap(JsonOrderRecord(record: try XCTUnwrap(members.find(id: "o1"))))
        XCTAssertEqual(read.shipping_address, Self.lisbon)
        XCTAssertEqual(read.parcel, parcel)
        XCTAssertEqual(read.shipping_addressRaw, Self.lisbonText)

        // A record whose field another writer stored as the canonical text decodes too.
        try await putRecord(documentId, "o2", ["title": "From the API", "shipping_address": Self.lisbonText])
        try await eventually(timeout: 20, description: "x to hold o2") { (try? JsonOrderRecord.find("o2")) != nil }
        let fromAPI = try XCTUnwrap(try JsonOrderRecord.find("o2"))
        XCTAssertEqual(fromAPI.shipping_address, Self.lisbon)
        XCTAssertEqual(fromAPI.title, "From the API")
    }

    // MARK: - Behavior 30

    func testAValueTheDefRefusesThrowsAndNothingIsQueuedOrStored() async throws {
        let (documentId, x) = try await single()
        let refused: [(String, JsonOrderRecord, String, Db3JSONRefusalKind)] = [
            ("bound", JsonOrderRecord(id: "b1", shipping_address: ShipAddress(city: "Faro", floor: 201)), "value.floor", .schema),
            ("pattern", JsonOrderRecord(id: "b2", shipping_address: ShipAddress(city: "Faro", zip: "8000-1")), "value.zip", .schema),
            ("enum", JsonOrderRecord(id: "b3", invoice: ShipInvoice(number: 1, priority: .number(5))), "value.priority", .schema),
            ("2^53 + 1", JsonOrderRecord(id: "b4", parcel: ShipParcel(label: "L", box: .init(width: 1, count: 9_007_199_254_740_993))), "value.box.count", .number),
            ("-(2^53 + 1)", JsonOrderRecord(id: "b5", parcel: ShipParcel(label: "L", codes: [-9_007_199_254_740_993])), "value.codes[0]", .number),
        ]
        for (name, order, path, kind) in refused {
            let error = valueError { _ = try order.save(in: documentId) }
            XCTAssertEqual(error?.path, path, name)
            XCTAssertEqual(error?.kind, kind, name)
            XCTAssertTrue(try live.pending(x, documentId).isEmpty, "\(name): nothing is queued")
        }
        // One accepted write, so the room has answered for this db3.
        try JsonOrderRecord(id: "ok", parcel: ShipParcel(label: "L", codes: [1])).save(in: documentId)
        try await live.settled(x, documentId)
        let rows = try await live.roomRows(documentId, Self.model)
        XCTAssertEqual(Set(rows.keys), ["ok"], "no refused record reached the room")

        // A held record that is then given a number past 2^53 keeps the text it had.
        var held = try XCTUnwrap(try JsonOrderRecord.find("ok"))
        held.parcel?.codes = [9_007_199_254_740_993]
        XCTAssertEqual(valueError { _ = try held.save(in: documentId) }?.kind, .number)
        try await live.settled(x, documentId)
        let row = try await roomRow(documentId, "ok")
        XCTAssertEqual(row?["parcel"] as? String, #"{"codes":[1],"label":"L"}"#, "no rounded value was written")
    }

    // MARK: - Behavior 31

    func testStoredTextThatDoesNotDecodeReadsNilAndSurvivesASaveOfAnotherField() async throws {
        let (documentId, x) = try await single()
        try await putRecord(documentId, "o3", ["title": "Old", "shipping_address": "Rua A, Lisbon", "parcel": #"{"label":7}"#])
        try await eventually(timeout: 20, description: "x to hold o3") { (try? JsonOrderRecord.find("o3")) != nil }
        var order = try XCTUnwrap(try JsonOrderRecord.find("o3"))
        XCTAssertNil(order.shipping_address)
        XCTAssertEqual(order.shipping_addressRaw, "Rua A, Lisbon")
        XCTAssertNil(order.parcel)
        XCTAssertEqual(order.parcelRaw, #"{"label":7}"#)
        XCTAssertEqual(order.title, "Old")

        order.title = "New"
        let saved = try order.save(in: documentId)
        try await live.settled(x, documentId)
        XCTAssertEqual(saved.shipping_addressRaw, "Rua A, Lisbon")
        let row = try await roomRow(documentId, "o3")
        XCTAssertEqual(row?["title"] as? String, "New")
        XCTAssertEqual(row?["shipping_address"] as? String, "Rua A, Lisbon")
        XCTAssertEqual(row?["parcel"] as? String, #"{"label":7}"#)
    }
}
