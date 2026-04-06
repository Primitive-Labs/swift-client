import XCTest
@testable import JsBaoClient
import YSwift

final class UserTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-users")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    // MARK: - Get Basic User

    func testGetBasicUser() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let userId = testApp.ownerUserId

        let result = try await client.users.getBasic(userId: userId)

        XCTAssertFalse(result.isEmpty, "Expected non-empty user info")

        // Should have at least userId
        let returnedUserId = result["userId"] as? String
            ?? result["user_id"] as? String
            ?? (result["user"] as? [String: Any])?["userId"] as? String

        XCTAssertNotNil(returnedUserId, "Expected userId in user info response: \(result.keys)")
    }
}
