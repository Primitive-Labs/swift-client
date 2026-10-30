import XCTest
@testable import JsBaoClient

/// #5021 behavior 12 — Swift `client.db3.listMine` answers what the three
/// `me/*-db3` listings answer, against the dev server.
///
/// One member holds a db3, has one shared with them by a direct grant and
/// reaches one through app access. Swift `listMine` lists exactly the
/// `(via, id)` pairs the three routes answer over HTTP for the same token, in
/// their order, with the shared row's `permission` and `grantedBy`.
final class Db3ListMineLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    private static let note = PrimitiveSchema(
        name: "Note", fields: ["id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string)]
    )

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-list-mine-5021")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// Every `(via, id)` pair the three listings answer over HTTP for `jwt`, in order.
    private func overHttp(_ jwt: String) async throws -> [(String, String, [String: Any])] {
        var pairs: [(String, String, [String: Any])] = []
        for (via, path) in [("held", "/me/db3"), ("shared", "/me/shared-db3"), ("app", "/me/app-db3")] {
            var cursor: String?
            repeat {
                let query = "?limit=100" + (cursor.map { "&cursor=\(URLEncoding.encodeComponent($0))" } ?? "")
                let page = try await ctx.appRequest(method: "GET", appId: live.app.appId, path: path + query, body: nil, jwt: jwt)
                for item in page["items"] as? [[String: Any]] ?? [] {
                    pairs.append((via, item["id"] as? String ?? "", item))
                }
                cursor = (page["hasMore"] as? Bool ?? false) ? page["nextCursor"] as? String : nil
            } while cursor != nil
        }
        return pairs
    }

    func testListMineAnswersTheThreeListingsAndAShareAppears() async throws {
        let owner = try await live.client("owner", models: [Self.note])
        let member = try await ctx.createTestUser(appId: live.app.appId)
        let memberClient = try await live.client("member", models: [Self.note], token: member.jwt)

        let held = try await memberClient.db3.create(title: "Mine")
        let shared = try await owner.db3.create(title: "Shared")
        _ = try await owner.db3.permissions(shared.id).set(.user(member.userId, permission: "reader"))
        let appWide = try await owner.db3.create(title: "Everyone")
        _ = try await owner.db3.setAppAccess(appWide.id, level: .readWrite)

        var rows: [Db3Info] = []
        var page = try await memberClient.db3.listMine(Db3ListMineOptions(limit: 100))
        rows += page.items
        while page.hasMore {
            page = try await memberClient.db3.listMine(Db3ListMineOptions(limit: 100, cursor: page.nextCursor))
            rows += page.items
        }

        let http = try await overHttp(member.jwt)
        XCTAssertEqual(rows.map { "\($0.via?.rawValue ?? "nil") \($0.id)" }, http.map { "\($0.0) \($0.1)" })
        XCTAssertTrue(rows.contains { $0.via == .held && $0.id == held.id })
        XCTAssertTrue(rows.contains { $0.via == .app && $0.id == appWide.id })
        let sharedRow = try XCTUnwrap(rows.first { $0.via == .shared && $0.id == shared.id }, "the shared db3 is on the Swift list")
        let sharedHttp = try XCTUnwrap(http.first { $0.0 == "shared" && $0.1 == shared.id }?.2)
        XCTAssertEqual(sharedRow.permission, .reader)
        XCTAssertEqual(sharedRow.grantedBy, sharedHttp["grantedBy"] as? String)
        XCTAssertEqual(sharedRow.grantedBy, live.app.ownerUserId)
        XCTAssertEqual(sharedRow.grantedAt, sharedHttp["grantedAt"] as? String)
    }
}
