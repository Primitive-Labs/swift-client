import XCTest
@testable import JsBaoClient

/// A Swift client with no generated models on a format-3 document, live
/// against the dev server, through `client.documents.records(documentId)`
/// and `client.documents.schema(documentId)` (#4624 behaviours 10, 11, 13,
/// 14, 15, 16, 17, 18, 21). The Swift twin of
/// `tests/client/js-bao-client-model-free-4623.test.ts`.
final class RecordLogModelFreeLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-model-free")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private static let ulid = try! NSRegularExpression(pattern: "^[0-9A-HJKMNP-TV-Z]{26}$")

    /// A client with no models and a new format-3 document open.
    private func modelFree(_ name: String, documentId: String? = nil) async throws -> (JsBaoClient, String) {
        let client = try await live.client(name, models: [])
        let id: String
        if let documentId { id = documentId } else { id = try await live.createDocument(client) }
        try await live.open(client, id)
        return (client, id)
    }

    /// Two clients with no models and a new format-3 document both have open,
    /// each built before either opens it (`RecordLogCriteriaLiveTests.pair`).
    private func pair() async throws -> (JsBaoClient, JsBaoClient, String) {
        let a = try await live.client("a", models: [])
        let documentId = try await live.createDocument(a)
        let b = try await live.client("b", models: [])
        try await live.open(a, documentId)
        try await live.open(b, documentId)
        return (a, b, documentId)
    }

    /// The room's row, without the `type` a server read adds, as JSON.
    private func roomRow(_ documentId: String, _ model: String, _ id: String) async throws -> JSONValue? {
        guard var row = try await live.roomRows(documentId, model)[id] else { return nil }
        row.removeValue(forKey: "type")
        return try JSONCoding.decodeData(JSONValue.self, from: JSONSerialization.data(withJSONObject: row))
    }

    private func refusals(_ client: JsBaoClient) -> (LockedBox<[DocumentWriteRefusedEvent]>, EventSubscription) {
        let heard = LockedBox<[DocumentWriteRefusedEvent]>([])
        let subscription = client.eventEmitter.subscribe(DocumentWriteRefusedEvent.self) { event in
            heard.withValue { $0.append(event) }
        }
        return (heard, subscription)
    }

    // MARK: - Behaviours 10 and 11

    func testPutMintsAnIdGetAnswersItAndTheRoomHoldsIt() async throws {
        let (a, documentId) = try await modelFree("a")
        let records = a.documents.records(documentId)
        let row = try records.put("Note", ["title": "a"])
        let id = try XCTUnwrap(row["id"]?.stringValue)
        XCTAssertEqual(Self.ulid.numberOfMatches(in: id, range: NSRange(id.startIndex..., in: id)), 1, id)
        XCTAssertEqual(row.raw, ["id": .string(id), "title": "a"])
        XCTAssertEqual(try records.get("Note", id: id), row)
        XCTAssertEqual(try records.put("Note", ["id": "n1", "title": "b"])["id"], "n1")
        try await live.settled(a, documentId)
        let room1 = try await roomRow(documentId, "Note", id)
        XCTAssertEqual(room1, .object(row.raw))
        let room2 = try await roomRow(documentId, "Note", "n1")
        XCTAssertEqual(room2, ["id": "n1", "title": "b"])
    }

    func testAPatchOfARecordTheCopyLacksIsSentAndADeleteRemovesTheRecord() async throws {
        let (a, documentId) = try await modelFree("a")
        let records = a.documents.records(documentId)
        XCTAssertNil(try records.patch("Note", id: "ghost", ["title": "x"]))
        XCTAssertEqual(try live.pending(a, documentId).map(\.m.kind), [.patch], "the patch is sent all the same")
        try await live.settled(a, documentId)

        try records.put("Note", ["id": "n2", "title": "keep"])
        try await live.settled(a, documentId)
        let room3 = try await roomRow(documentId, "Note", "n2")
        XCTAssertNotNil(room3)
        try records.delete("Note", id: "n2")
        XCTAssertNil(try records.get("Note", id: "n2"))
        try await live.settled(a, documentId)
        let room4 = try await roomRow(documentId, "Note", "n2")
        XCTAssertNil(room4)
    }

    // MARK: - Behaviour 13

    func testConfirmWaitsForTheRoomAndARefusedWriteThrowsAndIsReported() async throws {
        let (a, documentId) = try await modelFree("a")
        let records = a.documents.records(documentId)
        let (heard, subscription) = refusals(a)
        defer { subscription.cancel() }

        let kept = try await records.put("Lock", ["kind": "scalar"], confirm: true)
        let keptId = try XCTUnwrap(kept["id"]?.stringValue)
        let room5 = try await roomRow(documentId, "Lock", keptId)
        XCTAssertEqual(room5, ["id": .string(keptId), "kind": "scalar"])

        do {
            try await records.put("Lock", ["id": "lock2", "kind": ["a"]], confirm: true)
            XCTFail("the room refuses a set in a scalar field")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .documentEntryInvalid)
            XCTAssertTrue(error.message.contains("cannot become a string set"), error.message)
        }
        try await eventually(timeout: 20, description: "the refusal event") { heard.value.count == 1 }
        let event = try XCTUnwrap(heard.value.first)
        XCTAssertEqual(event.documentId, documentId)
        XCTAssertEqual(event.model, "Lock")
        XCTAssertEqual(event.recordId, "lock2")
        XCTAssertEqual(event.error.code, .documentEntryInvalid)
        XCTAssertEqual(event.writes?.first?.kind, .create)
        XCTAssertEqual(event.writes?.first?.stringSetDeltas, ["kind": ["a": true]])
        try await eventually(timeout: 20, description: "the refused guess to revert") {
            try records.get("Lock", id: "lock2") == nil
        }
    }

    /// Edge: a set change with nothing in it on a new field travels as an
    /// empty change, so the room holds the field as an empty set and locks it
    /// as one: a scalar written there next is refused.
    func testAnEmptySetChangeOnANewFieldLocksItAsASetInTheRoom() async throws {
        let (a, documentId) = try await modelFree("a")
        let records = a.documents.records(documentId)
        let put = try await records.put("Lock", ["id": "e1", "title": "x", "tags": .setChange()], confirm: true)
        XCTAssertEqual(put.raw, ["id": "e1", "title": "x", "tags": []])
        let room = try await roomRow(documentId, "Lock", "e1")
        XCTAssertEqual(room, ["id": "e1", "title": "x", "tags": []])

        do {
            try await records.patch("Lock", id: "e1", ["tags": "scalar"], confirm: true)
            XCTFail("the room refuses a scalar in a field it holds as a set")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .documentEntryInvalid)
            XCTAssertTrue(error.message.contains("field \"tags\" of Lock is a string set"), error.message)
        }
        let after = try await roomRow(documentId, "Lock", "e1")
        XCTAssertEqual(after, ["id": "e1", "title": "x", "tags": []])
    }

    /// A write naming both spellings of "é" plans two mutations of the
    /// record, and they travel as one entry (`m` plus `also`): when the room
    /// refuses the write for a scalar lock, none of it lands, `confirm` throws,
    /// and the refusal hands back both mutations (C4624-001).
    func testAWriteNamingBothSpellingsIsRefusedWhole() async throws {
        let (a, documentId) = try await modelFree("a")
        let records = a.documents.records(documentId)
        let (heard, subscription) = refusals(a)
        defer { subscription.cancel() }
        let before: RecordLogRow = ["id": "u1", "locked": 1, "tags": ["old"]]
        try await records.put("Lock", ["id": "u1", "locked": 1, "tags": ["old"]], confirm: true)

        do {
            try await records.patch(
                "Lock", id: "u1", ["locked": ["x"], "tags": ["e\u{301}", "\u{E9}"]], confirm: true
            )
            XCTFail("the room refuses a set in a scalar field")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .documentEntryInvalid)
            XCTAssertTrue(error.message.contains("cannot become a string set"), error.message)
        }
        try await eventually(timeout: 20, description: "the refusal event") { heard.value.count == 1 }
        XCTAssertEqual(heard.value.first?.writes?.map(\.kind), [.patch, .patch], "one entry, both mutations")
        try await live.settled(a, documentId)
        let room = try await roomRow(documentId, "Lock", "u1")
        XCTAssertEqual(room, .object(before), "nothing of the refused write landed")
        try await eventually(timeout: 20, description: "the refused guess to revert") {
            try records.get("Lock", id: "u1")?.raw == before
        }
    }

    // MARK: - Behaviours 14 and 15

    func testASecondClientQueriesCountsAndHearsWhatTheFirstWrites() async throws {
        let (a, b, documentId) = try await pair()
        let ra = a.documents.records(documentId)
        let rb = b.documents.records(documentId)
        let heard = LockedBox(0)
        let stop = try rb.subscribe("Memo") { heard.withValue { $0 += 1 } }
        defer { stop() }

        let one = try ra.put("Memo", ["s": "x", "n": 1.5, "b": true, "z": nil, "tags": ["a", "b"]])
        let two = try ra.put("Memo", ["s": "y", "n": 2, "b": false, "z": nil, "tags": []])
        try await live.settled(a, documentId)
        let seen = try await eventuallyValue(timeout: 30, description: "the second client to hold both records") {
            let page = try rb.query("Memo", ["n": ["$gte": 1]], options: QueryOptions(sort: ["n": 1]))
            return page.data.count == 2 ? page : nil
        }
        XCTAssertEqual(seen.data.map(\.raw), [
            ["id": one["id"]!, "s": "x", "n": 1.5, "b": true, "z": nil, "tags": ["a", "b"]],
            ["id": two["id"]!, "s": "y", "n": 2, "b": false, "z": nil, "tags": []],
        ])
        XCTAssertGreaterThan(heard.value, 0)
        XCTAssertEqual(try rb.count("Memo"), 2)
        XCTAssertEqual(try rb.count("Memo", ["b": true]), 1)
        XCTAssertEqual(try rb.count("Memo", ["tags": ["$contains": "a"]]), 1)
        XCTAssertEqual(try ra.get("Memo", id: one["id"]!.stringValue!)?.raw, seen.data[0].raw)
        let room6 = try await roomRow(documentId, "Memo", one["id"]!.stringValue!)
        XCTAssertEqual(room6, .object(seen.data[0].raw))
        let room7 = try await roomRow(documentId, "Memo", two["id"]!.stringValue!)
        XCTAssertEqual(room7, .object(seen.data[1].raw))
    }

    func testWritesMadeOfflineShowAtOnceAndReachTheRoomAndTheOtherClient() async throws {
        let (a, b, documentId) = try await pair()
        let ra = a.documents.records(documentId)
        let rb = b.documents.records(documentId)
        let heard = LockedBox(0)
        let stop = try rb.subscribe("Memo") { heard.withValue { $0 += 1 } }
        defer { stop() }

        a.setNetworkMode(.offline)
        let row = try ra.put("Memo", ["s": "offline", "n": 3])
        let id = try XCTUnwrap(row["id"]?.stringValue)
        XCTAssertEqual(try ra.get("Memo", id: id), row)
        try ra.patch("Memo", id: id, ["n": 4, "tags": ["o"]])
        let expected: [String: JSONValue] = ["id": .string(id), "s": "offline", "n": 4, "tags": ["o"]]
        XCTAssertEqual(try ra.get("Memo", id: id)?.raw, expected)
        XCTAssertEqual(try live.pending(a, documentId).count, 2)
        try await Task.sleep(nanoseconds: 500_000_000)
        let room8 = try await roomRow(documentId, "Memo", id)
        XCTAssertNil(room8)

        a.setNetworkMode(.online)
        try await live.settled(a, documentId)
        let room9 = try await roomRow(documentId, "Memo", id)
        XCTAssertEqual(room9, .object(expected))
        try await eventually(timeout: 30, description: "the second client to hold the offline writes") {
            try rb.get("Memo", id: id)?["n"] == 4
        }
        XCTAssertGreaterThan(heard.value, 0)
        XCTAssertEqual(try rb.query("Memo", ["s": "offline", "tags": ["$contains": "o"]]).data.compactMap { $0["id"]?.stringValue }, [id])
    }

    // MARK: - Behaviour 16

    func testArraysAreStringSetsReplaceKeepsAConcurrentMemberAndChangesEdit() async throws {
        let (a, b, documentId) = try await pair()
        let ra = a.documents.records(documentId)
        let rb = b.documents.records(documentId)
        let row = try ra.put("Shelf", ["tags": ["a", "b"]])
        let id = try XCTUnwrap(row["id"]?.stringValue)
        try await live.settled(a, documentId)

        // Another writer adds `h` while the client, offline, replaces the set
        // from its own copy, which does not hold `h`.
        a.setNetworkMode(.offline)
        _ = try await ctx.appRequest(
            method: "PATCH", appId: live.app.appId, path: "/documents/\(documentId)/records/Shelf/\(id)",
            body: ["data": ["tags": ["$add": ["h"]]]], jwt: live.app.ownerJWT
        )
        try ra.patch("Shelf", id: id, ["tags": ["a", "c"]])
        a.setNetworkMode(.online)
        try await live.settled(a, documentId)

        let steps: [(DocumentRecordValue, [String])] = [
            (.setChange(add: ["d"], remove: ["a"]), ["c", "d", "h"]),
            (nil, []),
            (.setChange(add: ["x", "y"]), ["x", "y"]),
            (.setChange(clear: true), []),
            // The two spellings of "é" are two members (D4624-002).
            (.stringSet(["\u{E9}", "e\u{301}"]), ["e\u{301}", "\u{E9}"]),
            (.setChange(remove: ["\u{E9}"]), ["e\u{301}"]),
            (.stringSet(["\u{E9}"]), ["\u{E9}"]),
        ]
        // Members compared as bytes: `JSONValue`'s `==` compares strings canonically.
        let bytes = { (value: JSONValue?) in value?.arrayValue?.map { Array(($0.stringValue ?? "").utf8) } ?? [] }
        func agree(_ members: [String], _ what: String) async throws {
            let want = members.map { Array($0.utf8) }
            let room10 = try await roomRow(documentId, "Shelf", id)
            XCTAssertEqual(bytes(room10?["tags"]), want, what)
            try await eventually(timeout: 30, description: "\(what): the writer to hold \(members)") {
                bytes(try ra.get("Shelf", id: id)?["tags"]) == want
            }
            try await eventually(timeout: 30, description: "\(what): the other client to hold \(members)") {
                bytes(try rb.get("Shelf", id: id)?["tags"]) == want
            }
        }
        try await agree(["a", "c", "h"], "the replace kept the concurrent member")
        for (value, members) in steps {
            try ra.patch("Shelf", id: id, ["tags": value])
            try await live.settled(a, documentId)
            try await agree(members, "\(value)")
        }
    }

    // MARK: - Behaviour 17

    func testPagesByIdAndByAFieldDescendingAndFindsSetMembers() async throws {
        let (a, documentId) = try await modelFree("a")
        let ra = a.documents.records(documentId)
        let pad = { (n: Int) in String(format: "%04d", n) }
        for i in 0..<250 {
            try ra.put("Page", ["id": .string("p\(pad(i))"), "rank": .number(Double(i % 10)), "tags": .stringSet(i % 3 == 0 ? ["three"] : [])])
        }
        try await live.settled(a, documentId, timeout: 120)
        let (b, _) = try await modelFree("b", documentId: documentId)
        let rb = b.documents.records(documentId)
        try await eventually(timeout: 60, description: "the second client to hold 250 records") { try rb.count("Page") == 250 }

        var byId: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try rb.query("Page", nil, options: QueryOptions(limit: 100, cursor: cursor))
            byId += page.data.compactMap { $0["id"]?.stringValue }
            cursor = page.hasMore ? page.nextCursor : nil
            pages += 1
        } while cursor != nil
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(byId, (0..<250).map { "p\(pad($0))" })

        var byRank: [PrimitiveRow] = []
        cursor = nil
        repeat {
            let page = try rb.query("Page", nil, options: QueryOptions(sortOrder: [("rank", -1)], limit: 60, cursor: cursor))
            byRank += page.data
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil
        XCTAssertEqual(byRank.count, 250)
        XCTAssertEqual(Set(byRank.compactMap { $0["id"]?.stringValue }).count, 250)
        for (before, after) in zip(byRank, byRank.dropFirst()) {
            let (r1, r2) = (before["rank"]!.numberValue!, after["rank"]!.numberValue!)
            let (i1, i2) = (before["id"]!.stringValue!, after["id"]!.stringValue!)
            XCTAssertTrue(r1 > r2 || (r1 == r2 && i1 < i2), "\(i1) then \(i2)")
        }

        let threes = try rb.query("Page", ["tags": ["$contains": "three"]], options: QueryOptions(limit: 500))
        XCTAssertEqual(threes.data.compactMap { $0["id"]?.stringValue }, (0..<84).map { "p\(pad($0 * 3))" })
        XCTAssertEqual(try rb.count("Page", ["tags": ["$contains": "three"]]), 84)
    }

    // MARK: - Behaviour 18

    /// Every call of the handle, `subscribe` included.
    private func everyCall(_ records: DocumentRecords) -> [(String, () throws -> Void)] {
        [
            ("put", { _ = try records.put("Note", ["title": "x"]) }),
            ("patch", { _ = try records.patch("Note", id: "r1", ["title": "x"]) }),
            ("delete", { try records.delete("Note", id: "r1") }),
            ("get", { _ = try records.get("Note", id: "r1") }),
            ("query", { _ = try records.query("Note") }),
            ("count", { _ = try records.count("Note") }),
            ("subscribe", { _ = try records.subscribe("Note") {} }),
        ]
    }

    func testAFormatOneDocumentAndADocumentThatIsNotOpenAreRefused() async throws {
        let a = try await live.client("a", models: [])
        let created = try await ctx.appRequest(
            method: "POST", appId: live.app.appId, path: "/documents", body: ["title": "Legacy"], jwt: live.app.ownerJWT
        )
        let legacy = try XCTUnwrap(created["documentId"] as? String)
        _ = try await a.openDocument(legacy, options: OpenDocumentOptions(waitForLoad: .network, enableNetworkSync: true))
        for (name, call) in everyCall(a.documents.records(legacy)) {
            XCTAssertThrowsError(try call(), name) { error in
                let error = error as? JsBaoError
                XCTAssertEqual(error?.code, .documentFormatMismatch, name)
                XCTAssertTrue(error?.message.contains("format 1") ?? false, error?.message ?? "")
                XCTAssertEqual(error?.details?["documentFormat"], 1)
            }
        }
        for (name, call) in everyCall(a.documents.records("01JD4624N0T0PENXXXXXXXXXXX")) {
            XCTAssertThrowsError(try call(), name) { error in
                let error = error as? JsBaoError
                XCTAssertEqual(error?.code, .notFound, name)
                XCTAssertTrue(error?.message.contains("openDocument") ?? false, error?.message ?? "")
            }
        }
    }

    /// A db3's close keeps its store bound (#4701), so a handle kept across the
    /// close keeps answering, and still does after a reopen.
    func testAHandleKeptAcrossACloseKeepsAnsweringAndAfterAReopen() async throws {
        let (a, documentId) = try await modelFree("a")
        let records = a.documents.records(documentId)
        try records.put("Note", ["id": "n1", "title": "a"])
        try await live.settled(a, documentId)
        _ = await a.closeDocument(documentId)
        XCTAssertEqual(try records.get("Note", id: "n1")?["title"], "a")
        let afterClose = try records.subscribe("Note") {}
        afterClose()
        try await live.open(a, documentId)
        XCTAssertEqual(try records.get("Note", id: "n1")?["title"], "a")
        let stop = try records.subscribe("Note") {}
        stop()
    }

    // MARK: - Behaviour 21

    func testSchemaAnswersWhatTheRouteAnswers() async throws {
        let (a, documentId) = try await modelFree("a")
        let records = a.documents.records(documentId)
        try records.put("Memo", ["s": "x", "n": 1, "tags": ["a"]])
        try records.put("Note", ["title": "t"])
        try await live.settled(a, documentId)
        let answer = try await a.documents.schema(documentId)
        let raw = try await ctx.appRequest(
            method: "GET", appId: live.app.appId, path: "/documents/\(documentId)/schema", body: nil, jwt: live.app.ownerJWT
        )
        let route = try JSONCoding.decodeData(JSONValue.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(.object(answer.schema.models), route["schema"]?["models"])
        XCTAssertEqual(answer.modelNames.map { JSONValue.string($0) }, route["modelNames"]?.arrayValue)
        XCTAssertEqual(Double(answer.modelCount), route["modelCount"]?.numberValue)
        XCTAssertEqual(answer.tableModels.map { JSONValue.string($0) }, route["tableModels"]?.arrayValue)
        XCTAssertEqual(Set(answer.schema.models.keys), ["Memo", "Note"])
        XCTAssertNotNil(answer.schema.models["Memo"]?["observed"]?["fields"]?["tags"])
    }
}
