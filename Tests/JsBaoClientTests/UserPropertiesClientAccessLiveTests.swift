import XCTest
@testable import JsBaoClient

/// User properties from Swift, against the dev server (#5387, project
/// `user-index-properties` phase 2).
///
/// `me.get()` decodes the caller's own `properties`; `me.update(params:)`
/// writes the client-writable ones (`self-write`, `self-write-members`) and
/// answers them; a field a client may not write throws `HttpError` with
/// status 403 and `serverCode` `USER_PROPERTY_NOT_CLIENT_WRITABLE`.
/// `users.getBasic`, `getProfiles` and `lookup` carry the member view of
/// another user.
final class UserPropertiesClientAccessLiveTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var writer: TestUser!
    var other: TestUser!
    var client: JsBaoClient!

    private static let schema = """
    [fields.hidden]
    type = "string"
    client = "none"

    [fields.mine]
    type = "string"
    client = "self"

    [fields.theme]
    type = "string"
    client = "self-write"
    default = "light"

    [fields.shared]
    type = "string"
    client = "members"

    [fields.pronouns]
    type = "string"
    client = "self-write-members"
    """

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-user-properties")
        try await ctx.pushUserProperties(appId: testApp.appId, toml: Self.schema)
        writer = try await ctx.createTestUser(appId: testApp.appId)
        // `users.lookup` matches the lowercased address, so the looked-up user's is lowercase.
        other = try await ctx.createTestUser(appId: testApp.appId, email: "swift-props-\(UUID().uuidString.prefix(8).lowercased())@test.local")
        try await ctx.writeUserProperties(appId: testApp.appId, userId: writer.userId, patch: ["hidden": "wh", "mine": "wm"])
        try await ctx.writeUserProperties(
            appId: testApp.appId, userId: other.userId,
            patch: ["hidden": "oh", "mine": "om", "theme": "dark", "shared": "os", "pronouns": "op"]
        )
        client = createTestClient(appId: testApp.appId, token: writer.jwt)
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    func testMeGetAnswersTheSelfView() async throws {
        let me = try await client.me.get(options: FetchCachedOptions(waitForLoad: .network))
        XCTAssertEqual(me?.properties, ["mine": .string("wm"), "theme": .string("light")])
    }

    func testMeUpdateWritesClientWritablePropertiesAndTheNextGetShowsThem() async throws {
        let updated = try await client.me.update(params: UpdateMeParams(properties: ["theme": .string("dark"), "pronouns": .string("they")]))
        let expected: [String: JSONValue] = ["mine": .string("wm"), "theme": .string("dark"), "pronouns": .string("they")]
        XCTAssertEqual(updated.properties, expected)
        let me = try await client.me.get(options: FetchCachedOptions(waitForLoad: .network))
        XCTAssertEqual(me?.properties, expected)

        let cleared = try await client.me.update(params: UpdateMeParams(properties: ["theme": .null]))
        XCTAssertEqual(cleared.properties["theme"], .string("light"))
    }

    func testMeUpdateOfAMembersFieldThrowsNotClientWritable() async throws {
        do {
            _ = try await client.me.update(params: UpdateMeParams(properties: ["shared": .string("nope")]))
            XCTFail("expected the write to be refused")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.serverCode, "USER_PROPERTY_NOT_CLIENT_WRITABLE")
        }
    }

    func testUsersCarryTheMemberViewOfAnotherUser() async throws {
        let memberView: [String: JSONValue] = ["shared": .string("os"), "pronouns": .string("op")]
        let basic = try await client.users.getBasic(userId: other.userId, options: GetUserOptions(waitForLoad: .network))
        XCTAssertEqual(basic.properties, memberView)
        let profiles = try await client.users.getProfiles(userIds: [other.userId, writer.userId])
        let byId = Dictionary(uniqueKeysWithValues: profiles.map { ($0.userId, $0) })
        XCTAssertEqual(byId[other.userId]?.properties, memberView)
        XCTAssertEqual(byId[writer.userId]?.properties, ["mine": .string("wm"), "theme": .string("light")])
        let found = try await client.users.lookup(email: other.email)
        XCTAssertTrue(found.exists)
        XCTAssertEqual(found.user?.properties, memberView)
    }
}
