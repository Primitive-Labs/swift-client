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

        // Should have at least userId
        XCTAssertFalse(result.userId.isEmpty, "Expected userId in user info response: \(result)")
        XCTAssertEqual(result.userId, userId, "Returned userId should match the requested one")
    }
}
