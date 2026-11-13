import XCTest
@testable import JsBaoClient

/// #5890 behaviour 17 and the Swift edge cases — `client.db3.update(_:title:)`
/// against the dev server.
///
/// - 17: a rename by the owner shows in another member's `listMine` and
///   `get`; a reader's rename throws the route's 403 `DOC_ACCESS_DENIED` and
///   the title stays.
/// - The renaming client's stored copy takes the title; a refused rename
///   leaves the reader's stored title as it was.
/// - Offline, `update` on a db3 whose create is pending throws
///   `.pendingCreate`; online, it renames once the create commits.
final class Db3UpdateLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-update-5890")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    private func share(_ db3Id: String, with userId: String, _ permission: String) async throws {
        _ = try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/db3/\(db3Id)/permissions",
            body: ["userId": userId, "permission": permission], jwt: live.app.ownerJWT
        )
    }

    private func storedTitle(_ client: JsBaoClient, _ db3Id: String) async throws -> String? {
        try await client.db3.stored().first { $0.id == db3Id }?.title
    }

    // MARK: - Behaviour 17

    func testARenameShowsOnAnotherClientAndAReaderIsRefused() async throws {
        let bob = try await ctx.createTestUser(appId: live.app.appId)
        let carol = try await ctx.createTestUser(appId: live.app.appId)
        let owner = try await live.client("owner", models: [Self.note])
        let db3 = try await createdOnServer(owner, title: "Rivera household")
        try await share(db3.id, with: bob.userId, "read-write")
        try await share(db3.id, with: carol.userId, "reader")

        let renamed = try await owner.db3.update(db3.id, title: "Rivera-Kim household")
        XCTAssertEqual(renamed.id, db3.id)
        XCTAssertEqual(renamed.title, "Rivera-Kim household")
        XCTAssertEqual(renamed.permission, .owner)

        let other = try await live.client("bob", models: [Self.note], token: bob.jwt)
        let read = try await other.db3.get(db3.id)
        XCTAssertEqual(read.title, "Rivera-Kim household")
        let page = try await other.db3.listMine(Db3ListMineOptions(via: [.shared]))
        XCTAssertEqual(page.items.first { $0.id == db3.id }?.title, "Rivera-Kim household")

        let reader = try await live.client("carol", models: [Self.note], token: carol.jwt)
        do {
            _ = try await reader.db3.update(db3.id, title: "Taken")
            XCTFail("a reader's rename is refused")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.serverCode, "DOC_ACCESS_DENIED")
        }
        let after = try await owner.db3.get(db3.id)
        XCTAssertEqual(after.title, "Rivera-Kim household")
    }

    // MARK: - Edge cases

    func testTheStoredTitleFollowsARenameAndNotARefusal() async throws {
        let carol = try await ctx.createTestUser(appId: live.app.appId)
        let owner = try await live.client("owner", models: [Self.note])
        let db3 = try await createdOnServer(owner, title: "Before")
        try await share(db3.id, with: carol.userId, "reader")
        _ = try await owner.db3.refresh(db3.id)
        _ = try await owner.db3.update(db3.id, title: "Kept")
        let ownerTitle = try await storedTitle(owner, db3.id)
        XCTAssertEqual(ownerTitle, "Kept")

        let reader = try await live.client("carol", models: [Self.note], token: carol.jwt)
        _ = try await reader.db3.refresh(db3.id)
        let before = try await storedTitle(reader, db3.id)
        do {
            _ = try await reader.db3.update(db3.id, title: "Taken")
            XCTFail("a reader's rename is refused")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
        }
        let after = try await storedTitle(reader, db3.id)
        XCTAssertEqual(after, before)
        XCTAssertNotEqual(after, "Taken")
    }

    func testAPendingCreateThrowsPendingCreateOfflineAndRenamesOnceItCommits() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        await owner.goOffline()
        let db3 = try await owner.db3.create(title: "Offline")
        do {
            _ = try await owner.db3.update(db3.id, title: "Renamed offline")
            XCTFail("a pending create is not renamed offline")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .pendingCreate)
        }
        let offlineTitle = try await storedTitle(owner, db3.id)
        XCTAssertEqual(offlineTitle, "Offline")

        await owner.goOnline()
        try await waitForConnection(client: owner, timeout: 10)
        let renamed = try await owner.db3.update(db3.id, title: "Renamed online")
        XCTAssertEqual(renamed.title, "Renamed online")
        XCTAssertFalse(owner.isPendingCreate(db3.id))
        let onlineTitle = try await storedTitle(owner, db3.id)
        XCTAssertEqual(onlineTitle, "Renamed online")
    }
}
