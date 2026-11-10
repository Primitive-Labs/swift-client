import XCTest
@testable import JsBaoClient

/// #5361 behavior 13 and edge case E6 (Swift) — `client.db3.aliases` on the
/// wire, mirroring `client.documents.aliases` over the db3 alias routes.
///
/// `set` sends `PUT /db3-aliases/user/<encoded key>` with exactly the keys it
/// was given; `resolve` sends `GET` (with `?userId=` when one is named) and
/// decodes the db3's row with its alias; `delete` sends `DELETE` with the same
/// query. A 404 makes `resolve` answer `nil` and `delete` return quietly;
/// every other refusal is thrown. `set` naming a db3 that lives only on this
/// device throws `.db3LocalOnly` before any request, and one naming a db3
/// whose create has not committed throws `.pendingCreate` offline.
final class Db3AliasesHermeticTests: XCTestCase {

    private static let db3Id = "01JD5361DB3ALIASESXXXXXXXX"
    private let world = Db3LocalOnlyWorld()

    override func tearDown() async throws {
        await world.tearDown()
        try await super.tearDown()
    }

    /// A `Db3API` with no client, whose transport answers `json` with `status`.
    private func api(_ json: String, status: Int = 200) -> (Db3API, RecordingTransport) {
        let transport = RecordingTransport(status: status, json: json)
        return (Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport), transport)
    }

    private static let aliasAnswer = """
    {"aliasKey": "in box", "scope": "user", "documentId": "\(db3Id)", "userId": "user-7",
     "createdAt": "2026-11-09T00:00:00.000Z", "updatedAt": "2026-11-09T00:00:01.000Z"}
    """

    private static let resolutionAnswer = """
    {"id": "\(db3Id)", "title": "Inbox", "createdBy": "user-7", "createdAt": "c", "modifiedAt": "m",
     "custodian": "user:user-7", "sync": false, "type": null,
     "alias": {"aliasKey": "inbox", "scope": "user", "documentId": "\(db3Id)", "userId": "user-7",
               "createdAt": "ac", "updatedAt": "au"}}
    """

    func testSetPutsTheAliasWithOnlyTheKeysGiven() async throws {
        let (db3, transport) = api(Self.aliasAnswer)
        let bound = try await db3.aliases.set(SetAliasParams(scope: .user, aliasKey: "In Box", documentId: Self.db3Id))
        let call = try XCTUnwrap(transport.lastCall)
        XCTAssertEqual(call.method, .put)
        XCTAssertEqual(call.path, "/db3-aliases/user/In%20Box")
        XCTAssertEqual(call.jsonBody, .object(["documentId": .string(Self.db3Id)]))
        XCTAssertEqual(bound.aliasKey, "in box")
        XCTAssertEqual(bound.documentId, Self.db3Id)
        XCTAssertEqual(bound.userId, "user-7")

        _ = try await db3.aliases.set(SetAliasParams(scope: .user, aliasKey: "inbox", documentId: Self.db3Id, userId: "user-7", mustNotExist: true))
        XCTAssertEqual(transport.lastCall?.jsonBody, .object([
            "documentId": .string(Self.db3Id), "userId": .string("user-7"), "mustNotExist": .bool(true),
        ]))
        _ = try await db3.aliases.set(SetAliasParams(scope: .user, aliasKey: "inbox", documentId: Self.db3Id, mustNotExist: false))
        XCTAssertEqual(transport.lastCall?.jsonBody, .object(["documentId": .string(Self.db3Id)]), "mustNotExist: false is not sent")
    }

    func testResolveGetsWithTheUserQueryAndDecodesTheResolution() async throws {
        let (db3, transport) = api(Self.resolutionAnswer)
        let mine = try await db3.aliases.resolve(AliasRef(scope: .user, aliasKey: "inbox"))
        XCTAssertEqual(transport.lastCall?.method, .get)
        XCTAssertEqual(transport.lastCall?.path, "/db3-aliases/user/inbox")
        XCTAssertNil(transport.lastCall?.body)

        let theirs = try await db3.aliases.resolve(AliasRef(scope: .user, aliasKey: "inbox", userId: "user-7"))
        XCTAssertEqual(transport.lastCall?.path, "/db3-aliases/user/inbox?userId=user-7")
        for resolved in [mine, theirs] {
            let row = try XCTUnwrap(resolved)
            XCTAssertEqual(row.id, Self.db3Id)
            XCTAssertEqual(row.title, "Inbox")
            XCTAssertEqual(row.createdBy, "user-7")
            XCTAssertEqual(row.createdAt, "c")
            XCTAssertEqual(row.modifiedAt, "m")
            XCTAssertEqual(row.custodian, "user:user-7")
            XCTAssertFalse(row.sync)
            XCTAssertNil(row.type)
            XCTAssertEqual(row.alias.aliasKey, "inbox")
            XCTAssertEqual(row.alias.documentId, Self.db3Id)
            XCTAssertEqual(row.alias.userId, "user-7")
        }
    }

    func testDeleteSendsDeleteWithTheUserQuery() async throws {
        let (db3, transport) = api(#"{"success": true}"#)
        try await db3.aliases.delete(AliasRef(scope: .user, aliasKey: "in box"))
        XCTAssertEqual(transport.lastCall?.method, .delete)
        XCTAssertEqual(transport.lastCall?.path, "/db3-aliases/user/in%20box")
        XCTAssertNil(transport.lastCall?.body)
        try await db3.aliases.delete(AliasRef(scope: .user, aliasKey: "inbox", userId: "user-7"))
        XCTAssertEqual(transport.lastCall?.path, "/db3-aliases/user/inbox?userId=user-7")
    }

    func testA404IsNilForResolveAndQuietForDelete() async throws {
        let (db3, transport) = api(#"{"error": "Alias not found", "code": "alias_not_found"}"#, status: 404)
        let resolved = try await db3.aliases.resolve(AliasRef(scope: .user, aliasKey: "nothing"))
        XCTAssertNil(resolved)
        try await db3.aliases.delete(AliasRef(scope: .user, aliasKey: "nothing"))
        XCTAssertEqual(transport.calls.map(\.method), [.get, .delete])
    }

    func testEveryOtherRefusalIsThrown() async throws {
        let (db3, _) = api(#"{"error": "Document d is not a db3 (format 1)", "code": "NOT_A_DB3"}"#, status: 409)
        let calls: [(String, () async throws -> Void)] = [
            ("set", { _ = try await db3.aliases.set(SetAliasParams(scope: .user, aliasKey: "plain", documentId: "d")) }),
            ("resolve", { _ = try await db3.aliases.resolve(AliasRef(scope: .user, aliasKey: "plain")) }),
            ("delete", { try await db3.aliases.delete(AliasRef(scope: .user, aliasKey: "plain")) }),
        ]
        for (name, call) in calls {
            do {
                try await call()
                XCTFail("\(name) throws the server's refusal")
            } catch let error as HttpError {
                XCTAssertEqual(error.status, 409, name)
                XCTAssertEqual(error.serverCode, "NOT_A_DB3", name)
            }
        }
    }

    func testSetOnALocalOnlyDb3IsRefusedBeforeAnyRequest() async throws {
        let client = try await world.client(directory: world.directory())
        let transport = RecordingTransport(status: 200, json: Self.aliasAnswer)
        let id = try await world.createLocalOnly(client, transport: transport).id
        let db3 = Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
        let error = await db3LocalOnlyThrown {
            _ = try await db3.aliases.set(SetAliasParams(scope: .user, aliasKey: "local", documentId: id))
        }
        XCTAssertEqual(error?.code, .db3LocalOnly)
        XCTAssertEqual(error?.details?["db3Id"], .string(id))
        XCTAssertEqual(transport.calls.map(\.path).filter { $0.hasPrefix("/db3-aliases") }, [])
    }

    func testSetOnAPendingCreateWaitsForItAndThrowsPendingCreateOffline() async throws {
        let client = try await world.client(directory: world.directory())
        let transport = RecordingTransport(status: 200, json: Self.aliasAnswer)
        let db3 = Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
        let id = try await db3.create(title: "Offline").id
        XCTAssertTrue(client.isPendingCreate(id))
        let error = await db3LocalOnlyThrown {
            _ = try await db3.aliases.set(SetAliasParams(scope: .user, aliasKey: "fresh", documentId: id))
        }
        XCTAssertEqual(error?.code, .pendingCreate)
        XCTAssertEqual(transport.calls.map(\.path).filter { $0.hasPrefix("/db3-aliases") }, [])
    }
}
