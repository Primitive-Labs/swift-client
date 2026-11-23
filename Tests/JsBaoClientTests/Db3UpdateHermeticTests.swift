import XCTest
@testable import JsBaoClient

/// #5890 behaviours 16 and 18 — `client.db3.update(_:title:)`, with no server.
///
/// - 16: it sends `PUT /db3/<id>` with `{"title": …}` and decodes the
///   answer as `Db3Info`; a refusal throws it.
/// - 18: on a db3 that lives only on this device nothing is sent; it answers
///   the db3 with the new title (trimmed), `stored()` shows it, and a new
///   client over the same store still shows it. A blank title, or one over
///   255 characters, throws `.invalidArgument` and changes nothing.
/// - `stored()` reports the title the device holds: the created one.
/// - C5890-004: the title limit counts UTF-16 code units, as the server does.
/// - C5890-001: with its row gone and its store not bound, two renames both
///   stay on the device: the first puts the whole local-only row back.
final class Db3UpdateHermeticTests: XCTestCase {

    private static let id = "01JD5890UPD000000000000AAA"

    private static let answer = """
    {"id": "\(id)", "title": "Rivera household", "createdBy": "u-1", "createdAt": "2026-11-01T00:00:00.000Z",
     "modifiedAt": "2026-11-12T00:00:00.000Z", "custodian": "user:u-1", "sync": true, "type": null, "tags": ["home"],
     "permission": "owner", "accessSource": "owner", "grantedAt": "2026-11-01T00:00:00.000Z"}
    """

    private let world = Db3LocalOnlyWorld()

    override func tearDown() async throws {
        await world.tearDown()
        try await super.tearDown()
    }

    private func body(_ call: RecordedRequest?) -> [String: JSONValue]? {
        if case .object(let object)? = call?.jsonBody { return object }
        return nil
    }

    // MARK: - Behaviour 16

    func testUpdatePutsTheTitleAndDecodesTheAnswer() async throws {
        let transport = RecordingTransport(status: 200, json: Self.answer)
        let db3 = Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport)
        let info = try await db3.update(Self.id, title: "Rivera household")
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertEqual(transport.lastCall?.method, .put)
        XCTAssertEqual(transport.lastCall?.path, "/db3/\(Self.id)")
        XCTAssertEqual(body(transport.lastCall), ["title": "Rivera household"])
        XCTAssertEqual(info, Db3Info(
            id: Self.id, title: "Rivera household", createdBy: "u-1", createdAt: "2026-11-01T00:00:00.000Z",
            modifiedAt: "2026-11-12T00:00:00.000Z", custodian: "user:u-1", sync: true, type: nil, tags: ["home"],
            metadata: nil, permission: .owner, accessSource: .owner, grantedAt: "2026-11-01T00:00:00.000Z"
        ))
    }

    func testUpdateThrowsTheRoutesRefusal() async throws {
        let transport = RecordingTransport(status: 403, json: #"{"error": "Access denied", "code": "DOC_ACCESS_DENIED"}"#)
        let db3 = Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport)
        do {
            _ = try await db3.update(Self.id, title: "Taken")
            XCTFail("a refusal throws")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.serverCode, "DOC_ACCESS_DENIED")
        }
    }

    // MARK: - Behaviour 18

    func testALocalOnlyDb3IsRenamedOnTheDeviceAndKeepsItAcrossARestart() async throws {
        let directory = world.directory()
        let client = try await world.client(directory: directory)
        let transport = RecordingTransport(status: 500, json: "{}")
        let created = try await world.createLocalOnly(client, transport: transport, title: "Mine")
        let db3 = Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
        let createdTitle = try await client.db3.stored().first?.title
        XCTAssertEqual(createdTitle, "Mine", "stored() reports the created title")

        let renamed = try await db3.update(created.id, title: "  Ours \t")
        XCTAssertEqual(transport.calls.map(\.path), [], "nothing is sent")
        XCTAssertEqual(renamed.id, created.id)
        XCTAssertEqual(renamed.title, "Ours")
        XCTAssertEqual(renamed.localOnly, true)
        XCTAssertEqual(renamed.sync, false)
        XCTAssertNil(renamed.type)
        XCTAssertEqual(renamed.tags, ["t"])
        XCTAssertEqual(renamed.createdAt, created.createdAt)
        XCTAssertEqual(renamed.custodian, created.custodian)
        let storedTitle = try await client.db3.stored().first { $0.id == created.id }?.title
        XCTAssertEqual(storedTitle, "Ours")
        XCTAssertEqual(client.documentManager.getLocalMetadata(created.id)?.title, "Ours")
        let state = try await client.db3.state(created.id)
        XCTAssertTrue(state.localOnly)
        XCTAssertEqual(state.pendingWrites, 0)
        await world.destroy(client)

        let again = try await world.client(directory: directory)
        try await db3LocalOnlyEventually("the copy listed after the restart") {
            try await again.db3.stored().contains { $0.id == created.id }
        }
        let restartedTitle = try await again.db3.stored().first { $0.id == created.id }?.title
        XCTAssertEqual(restartedTitle, "Ours")
        XCTAssertEqual(world.remoteCreates, 0)
    }

    func testABlankOrLongTitleThrowsInvalidArgumentAndChangesNothing() async throws {
        let client = try await world.client(directory: world.directory())
        let transport = RecordingTransport(status: 500, json: "{}")
        let created = try await world.createLocalOnly(client, transport: transport, title: "Mine")
        let db3 = Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
        for title in ["", "   ", String(repeating: "x", count: 256)] {
            let error = await db3LocalOnlyThrown { _ = try await db3.update(created.id, title: title) }
            XCTAssertEqual(error?.code, .invalidArgument, "\(title.count) characters")
            let kept = try await client.db3.stored().first { $0.id == created.id }?.title
            XCTAssertEqual(kept, "Mine")
        }
        let atLimit = try await db3.update(created.id, title: String(repeating: "y", count: 255))
        XCTAssertEqual(atLimit.title.count, 255)
        XCTAssertEqual(transport.calls.map(\.path), [], "nothing is sent")
    }

    /// C5890-004: the length is the server's and the JS client's, in UTF-16
    /// code units: 128 emoji are 128 characters but 256 units, and refused.
    func testTheTitleLimitCountsUtf16UnitsAsTheServerDoes() async throws {
        let client = try await world.client(directory: world.directory())
        let transport = RecordingTransport(status: 500, json: "{}")
        let created = try await world.createLocalOnly(client, transport: transport, title: "Mine")
        let db3 = Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)
        let over = String(repeating: "\u{1F600}", count: 128)
        XCTAssertEqual(over.count, 128)
        XCTAssertEqual(over.utf16.count, 256)
        let error = await db3LocalOnlyThrown { _ = try await db3.update(created.id, title: over) }
        XCTAssertEqual(error?.code, .invalidArgument)
        let kept = try await client.db3.stored().first { $0.id == created.id }?.title
        XCTAssertEqual(kept, "Mine")
        XCTAssertEqual(client.documentManager.getLocalMetadata(created.id)?.title, "Mine")

        let atLimit = String(repeating: "\u{1F600}", count: 127) + "a"
        XCTAssertEqual(atLimit.utf16.count, 255)
        let renamed = try await db3.update(created.id, title: atLimit)
        XCTAssertEqual(renamed.title, atLimit)
        XCTAssertEqual(transport.calls.map(\.path), [], "nothing is sent")
    }

    /// C5890-001: a local-only db3 whose metadata row is gone and whose store
    /// is not bound is known from its store's mark; a rename puts its whole
    /// local-only row back, so a second rename stays on the device too.
    func testALocalOnlyDb3WithItsRowGoneAndItsStoreUnboundIsRenamedTwiceOnTheDevice() async throws {
        let client = try await world.client(directory: world.directory())
        let transport = RecordingTransport(status: 500, json: "{}")
        let created = try await world.createLocalOnly(client, transport: transport, title: "Mine")
        let db3 = Db3API(lifecycle: client._db3Lifecycle, transport: transport, client: client)

        await client.documentManager.cancelPendingCreate(created.id)
        await client.unbindRecordLogDocument(created.id)
        XCTAssertNil(client.documentManager.getLocalMetadata(created.id), "its row is gone")
        XCTAssertFalse(client.isLocalOnlyDb3Known(created.id), "nothing bound or in a row says so")
        let fromMark = await client.isLocalOnlyDb3(created.id)
        XCTAssertTrue(fromMark, "its store's mark still says so")

        let first = try await db3.update(created.id, title: "Renamed once")
        XCTAssertEqual(first.title, "Renamed once")
        XCTAssertEqual(first.localOnly, true)
        let row = client.documentManager.getLocalMetadata(created.id)
        XCTAssertEqual(row?.localOnly, true)
        XCTAssertEqual(row?.documentFormat, RecordLogTransport.documentFormat)
        XCTAssertEqual(row?.title, "Renamed once")
        XCTAssertTrue(client.isLocalOnlyDb3Known(created.id), "the row says so again")

        let second = try await db3.update(created.id, title: "Renamed twice")
        XCTAssertEqual(second.title, "Renamed twice")
        XCTAssertEqual(second.localOnly, true)
        XCTAssertEqual(transport.calls.map(\.path), [], "nothing is sent")
        XCTAssertEqual(client.documentManager.getLocalMetadata(created.id)?.title, "Renamed twice")
        XCTAssertEqual(world.remoteCreates, 0)
    }
}
