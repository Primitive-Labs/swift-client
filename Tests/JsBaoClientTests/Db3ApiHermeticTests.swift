import XCTest
@testable import JsBaoClient

/// #4806 behavior 11, edge cases 036 and the `Db3Info` half of behavior 19 —
/// the `client.db3` lifecycle calls on the wire.
///
/// Each call sends its route's method, path and body (a create sends exactly
/// the keys it was given) and decodes its route's answer field for field.
/// `Db3Info` decodes the three shapes the server answers a db3 in: the create
/// and `GET db3/:id` answer, a `me/db3` row (no `tags`, a `permission`), and
/// the bare row `db3.transfer` answers (no `tags`, no `permission`).
final class Db3ApiHermeticTests: XCTestCase {

    private static let id = "01JD4806API000000000000AAA"

    /// A `Db3API` whose transport answers `json` with `status`, and the transport.
    private func api(_ json: String, status: Int = 200) -> (Db3API, RecordingTransport) {
        let transport = RecordingTransport(status: status, json: json)
        return (Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport), transport)
    }

    private func body(_ call: RecordedRequest?) -> [String: JSONValue]? {
        if case .object(let object)? = call?.jsonBody { return object }
        return nil
    }

    private static let answer = """
    {"id": "\(id)", "title": null, "createdBy": "u-1", "createdAt": "2026-10-26T00:00:00.000Z",
     "modifiedAt": "2026-10-26T01:00:00.000Z", "custodian": null, "sync": true, "type": null, "tags": ["x", "y"],
     "metadata": {"color": "red"}}
    """

    // MARK: - create

    func testCreatePostsExactlyTheGivenKeysAndDecodesTheAnswer() async throws {
        let (db3, transport) = api(Self.answer, status: 201)
        let info = try await db3.create(title: "Orders", type: "orders", sync: false, custodian: "app", tags: ["x"], metadata: .object(["color": "red"]))
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/db3")
        XCTAssertEqual(body(transport.lastCall), [
            "title": "Orders", "type": "orders", "sync": false, "custodian": "app", "tags": ["x"], "metadata": .object(["color": "red"]),
        ])
        XCTAssertEqual(info, Db3Info(
            id: Self.id, title: "", createdBy: "u-1", createdAt: "2026-10-26T00:00:00.000Z", modifiedAt: "2026-10-26T01:00:00.000Z",
            custodian: nil, sync: true, type: nil, tags: ["x", "y"], metadata: .object(["color": "red"]),
            permission: nil, accessSource: nil, grantedAt: nil
        ))

        // #4921: a create of your own synced db3 sends the id the client minted, and no sync.
        let (bare, bareTransport) = api(Self.answer, status: 201)
        _ = try await bare.create(title: "Plain")
        var plain = try XCTUnwrap(body(bareTransport.lastCall))
        let mintedId = try XCTUnwrap(plain.removeValue(forKey: "id")?.stringValue)
        XCTAssertNotNil(mintedId.range(of: "^[0-7][0-9A-HJKMNP-TV-Z]{25}$", options: .regularExpression), mintedId)
        XCTAssertEqual(plain, ["title": "Plain"])
        _ = try await bare.create(title: "On", sync: true)
        var on = try XCTUnwrap(body(bareTransport.lastCall))
        XCTAssertNotNil(on.removeValue(forKey: "id"))
        XCTAssertEqual(on, ["title": "On"])
    }

    func testCreateThrowsTheRoutesRefusal() async throws {
        let (db3, _) = api(#"{"error": "No db3 type named nope", "code": "DB3_TYPE_NOT_FOUND"}"#, status: 404)
        do {
            _ = try await db3.create(title: "Typed", type: "nope")
            XCTFail("create should throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 404)
            XCTAssertEqual(error.serverCode, "DB3_TYPE_NOT_FOUND")
        }
    }

    // MARK: - get, delete, listMine

    func testGetDecodesTheGrantFields() async throws {
        let (db3, transport) = api("""
        {"id": "\(Self.id)", "title": "Orders", "createdBy": "u-1", "createdAt": "c", "modifiedAt": "m", "custodian": "user:u-1",
         "sync": false, "type": "orders", "tags": [], "permission": "owner", "accessSource": "owner", "grantedAt": "g"}
        """)
        let info = try await db3.get(Self.id)
        XCTAssertEqual(transport.lastCall?.method, .get)
        XCTAssertEqual(transport.lastCall?.path, "/db3/\(Self.id)")
        XCTAssertNil(transport.lastCall?.body)
        XCTAssertEqual(info, Db3Info(
            id: Self.id, title: "Orders", createdBy: "u-1", createdAt: "c", modifiedAt: "m", custodian: "user:u-1", sync: false,
            type: "orders", tags: [], metadata: nil, permission: .owner, accessSource: .owner, grantedAt: "g"
        ))
    }

    func testDb3InfoDecodesAppAndAnUnknownAccessSource() throws {
        let row = { (source: String) in
            #"{"id": "d", "title": "t", "createdBy": "u", "createdAt": "c", "modifiedAt": "m", "custodian": "app", "sync": true, "type": null, "tags": ["a"], "permission": "read-write", "accessSource": "\#(source)"}"#
        }
        let app = try JSONCoding.decodeData(Db3Info.self, from: Data(row("app").utf8))
        XCTAssertEqual(app.accessSource, .app)
        let later = try JSONCoding.decodeData(Db3Info.self, from: Data(row("something-later").utf8))
        XCTAssertNil(later.accessSource)
        XCTAssertEqual(later, Db3Info(
            id: "d", title: "t", createdBy: "u", createdAt: "c", modifiedAt: "m", custodian: "app", sync: true, type: nil,
            tags: ["a"], metadata: nil, permission: .readWrite, accessSource: nil, grantedAt: nil
        ))
    }

    func testDeleteSendsDeleteAndAnswersSuccess() async throws {
        let (db3, transport) = api(#"{"success": true}"#)
        let result = try await db3.delete(Self.id)
        XCTAssertTrue(result.success)
        XCTAssertEqual(transport.lastCall?.method, .delete)
        XCTAssertEqual(transport.lastCall?.path, "/db3/\(Self.id)")
    }

    /// Edge case 036: a `me/db3` row carries no `tags`, no `metadata` and no `accessSource`.
    func testListMinePagesMeDb3AndDecodesItsRows() async throws {
        let (db3, transport) = api("""
        {"items": [
          {"id": "a", "title": "A", "createdAt": "c", "modifiedAt": "m", "createdBy": "u-1", "custodian": "user:u-1", "sync": true, "type": null, "permission": "owner"},
          {"id": "b", "title": null, "createdAt": "c", "modifiedAt": "m", "createdBy": "u-1", "custodian": "user:u-1", "sync": false, "type": "t", "permission": null}
        ], "hasMore": true, "nextCursor": "next"}
        """)
        let page = try await db3.listMine(options: PaginationOptions(limit: 2, cursor: "here"))
        XCTAssertEqual(transport.lastCall?.method, .get)
        XCTAssertEqual(transport.lastCall?.path, "/me/db3?limit=2&cursor=here")
        XCTAssertEqual(page.items, [
            Db3Info(id: "a", title: "A", createdBy: "u-1", createdAt: "c", modifiedAt: "m", custodian: "user:u-1", sync: true, type: nil,
                    tags: [], metadata: nil, permission: .owner, accessSource: nil, grantedAt: nil),
            Db3Info(id: "b", title: "", createdBy: "u-1", createdAt: "c", modifiedAt: "m", custodian: "user:u-1", sync: false, type: "t",
                    tags: [], metadata: nil, permission: nil, accessSource: nil, grantedAt: nil),
        ])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextCursor, "next")
        _ = try await db3.listMine()
        XCTAssertEqual(transport.lastCall?.path, "/me/db3")
    }

    // MARK: - getOrCreateWithAlias

    func testGetOrCreateWithAliasCreatesAndAnswersTheReference() async throws {
        let created = """
        {"id": "\(Self.id)", "title": "Mine", "createdBy": "u-1", "createdAt": "c", "modifiedAt": "m", "custodian": "user:u-1",
         "sync": true, "type": "orders", "tags": [], "created": true,
         "alias": {"aliasKey": "home", "scope": "user", "documentId": "\(Self.id)", "userId": "u-1"}}
        """
        let (db3, transport) = api(created, status: 201)
        let options = Db3GetOrCreateWithAliasOptions(alias: AliasRef(scope: .user, aliasKey: "home", userId: "u-1"), title: "Mine", type: "orders")
        let result = try await db3.getOrCreateWithAlias(options)
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/db3/get-or-create-with-alias")
        XCTAssertEqual(body(transport.lastCall), [
            "alias": .object(["scope": "user", "aliasKey": "home", "userId": "u-1"]), "title": "Mine", "type": "orders",
        ])
        XCTAssertEqual(result.id, Self.id)
        XCTAssertTrue(result.created)
        XCTAssertEqual(result.alias?.aliasKey, "home")
        XCTAssertEqual(result.db3?.type, "orders")
        XCTAssertEqual(result.db3?.custodian, "user:u-1")

        let (again, _) = api("""
        {"id": "\(Self.id)", "created": false, "alias": {"aliasKey": "home", "scope": "user", "documentId": "\(Self.id)", "userId": "u-1"}}
        """)
        let reference = try await again.getOrCreateWithAlias(options)
        XCTAssertEqual(reference.id, Self.id)
        XCTAssertFalse(reference.created)
        XCTAssertNil(reference.db3)
        XCTAssertEqual(reference.alias?.documentId, Self.id)
    }

    // MARK: - sync, type, app access, custody

    func testSyncCallsSendTheirBodiesAndDecode() async throws {
        let (reader, readTransport) = api(#"{"id": "d", "sync": true}"#)
        let answered1 = try await reader.getSync("d")
        XCTAssertEqual(answered1, Db3SyncState(id: "d", sync: true))
        XCTAssertEqual(readTransport.lastCall?.method, .get)
        XCTAssertEqual(readTransport.lastCall?.path, "/db3/d/sync")

        let (writer, writeTransport) = api(#"{"id": "d", "sync": false, "changed": true}"#)
        let flipped = try await writer.setSync("d", sync: false)
        XCTAssertEqual(flipped, Db3SyncChange(id: "d", sync: false, changed: true))
        XCTAssertEqual(writeTransport.lastCall?.method, .put)
        XCTAssertEqual(writeTransport.lastCall?.path, "/db3/d/sync")
        XCTAssertEqual(body(writeTransport.lastCall), ["sync": false])
    }

    func testTypeCallsSendTheirBodiesAndDecode() async throws {
        let (reader, readTransport) = api("""
        {"id": "d", "type": "orders", "revision": {"generation": 1761436800123, "hash": "abc"},
         "installed": {"name": "orders", "revision": {"generation": 1761436800123, "hash": "abc"}, "installedAt": 1761436800999}}
        """)
        let state = try await reader.getType("d")
        XCTAssertEqual(readTransport.lastCall?.path, "/db3/d/type")
        XCTAssertEqual(state, Db3TypeState(
            id: "d", type: "orders", revision: Db3TypeRevision(generation: 1_761_436_800_123, hash: "abc"),
            installed: Db3InstalledType(name: "orders", revision: Db3TypeRevision(generation: 1_761_436_800_123, hash: "abc"), installedAt: 1_761_436_800_999)
        ))
        let (untyped, _) = api(#"{"id": "d", "type": null, "revision": null, "installed": null}"#)
        let answered2 = try await untyped.getType("d")
        XCTAssertEqual(answered2, Db3TypeState(id: "d", type: nil, revision: nil, installed: nil))

        let (writer, writeTransport) = api(#"{"id": "d", "type": "orders", "revision": {"generation": 5, "hash": "h"}, "outcome": "committed"}"#)
        let change = try await writer.setType("d", type: "orders")
        XCTAssertEqual(writeTransport.lastCall?.method, .put)
        XCTAssertEqual(writeTransport.lastCall?.path, "/db3/d/type")
        XCTAssertEqual(body(writeTransport.lastCall), ["type": "orders"])
        XCTAssertEqual(change, Db3TypeChange(id: "d", type: "orders", revision: Db3TypeRevision(generation: 5, hash: "h"), outcome: "committed"))
    }

    func testAppAccessCallsSendTheLevelOrNullAndDecode() async throws {
        let (reader, readTransport) = api(#"{"id": "d", "level": "read-write"}"#)
        let answered3 = try await reader.getAppAccess("d")
        XCTAssertEqual(answered3, Db3AppAccess(id: "d", level: .readWrite))
        XCTAssertEqual(readTransport.lastCall?.path, "/db3/d/app-access")
        let (off, _) = api(#"{"id": "d", "level": null}"#)
        let answered4 = try await off.getAppAccess("d")
        XCTAssertEqual(answered4, Db3AppAccess(id: "d", level: nil))

        let (writer, writeTransport) = api(#"{"id": "d", "level": "reader", "changed": true}"#)
        let granted = try await writer.setAppAccess("d", level: .reader)
        XCTAssertEqual(granted, Db3AppAccessChange(id: "d", level: .reader, changed: true))
        XCTAssertEqual(writeTransport.lastCall?.method, .put)
        XCTAssertEqual(writeTransport.lastCall?.path, "/db3/d/app-access")
        XCTAssertEqual(body(writeTransport.lastCall), ["level": "reader"])
        _ = try? await writer.setAppAccess("d", level: nil)
        XCTAssertEqual(body(writeTransport.lastCall), ["level": .null])
        XCTAssertEqual(Db3AppAccessLevel.readWrite.rawValue, "read-write")
    }

    /// The bare row `db3.transfer` answers: no `tags`, no `permission`.
    func testTransferPostsToAndDecodesTheBareRow() async throws {
        let (db3, transport) = api(#"{"id": "d", "title": "T", "createdAt": "c", "modifiedAt": "m", "createdBy": "u-1", "custodian": "app", "sync": true, "type": null}"#)
        let info = try await db3.transfer("d", to: "app")
        XCTAssertEqual(transport.lastCall?.method, .post)
        XCTAssertEqual(transport.lastCall?.path, "/db3/d/transfer")
        XCTAssertEqual(body(transport.lastCall), ["to": "app"])
        XCTAssertEqual(info, Db3Info(
            id: "d", title: "T", createdBy: "u-1", createdAt: "c", modifiedAt: "m", custodian: "app", sync: true, type: nil,
            tags: [], metadata: nil, permission: nil, accessSource: nil, grantedAt: nil
        ))
    }

    func testSetOwnerRowSendsPresentAndDecodes() async throws {
        let (db3, transport) = api(#"{"id": "d", "custodian": "user:u-1", "ownerRow": false, "changed": true}"#)
        let change = try await db3.setOwnerRow("d", present: false)
        XCTAssertEqual(transport.lastCall?.method, .put)
        XCTAssertEqual(transport.lastCall?.path, "/db3/d/owner-row")
        XCTAssertEqual(body(transport.lastCall), ["present": false])
        XCTAssertEqual(change, Db3OwnerRowChange(id: "d", custodian: "user:u-1", ownerRow: false, changed: true))
    }

    func testAnIdIsPathEncoded() async throws {
        let (db3, transport) = api(#"{"id": "a/b", "sync": true}"#)
        _ = try await db3.getSync("a/b")
        XCTAssertEqual(transport.lastCall?.path, "/db3/a%2Fb/sync")
    }
}
