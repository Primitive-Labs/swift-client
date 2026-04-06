import XCTest
@testable import JsBaoClient
import YSwift

final class SessionTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-session")
    }

    override func tearDown() async throws {
        await ctx.cleanup()
    }

    // MARK: - Get Session

    func testGetSession() async throws {
        let client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await client.destroy() } }

        let result = try await client.session.get()

        // Session should return some info about the current session
        XCTAssertFalse(result.isEmpty, "Expected non-empty session response")

        // Should contain userId or user info
        let hasUserInfo = result["userId"] != nil
            || result["user"] != nil
            || result["appId"] != nil
            || result["session"] != nil

        XCTAssertTrue(hasUserInfo, "Session should contain user or app info: \(result.keys)")
    }
}
