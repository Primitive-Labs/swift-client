import XCTest
@testable import JsBaoClient

/// The Swift client's sign-in settings reads against the local dev server
/// (#5362): `auth.getAuthConfig()` and `auth.getAppConfig()` answer what the
/// public `GET /app/{appId}/api/settings/sign-in` answers, and an app the
/// server does not know — the same 404 an older server without the route
/// gives — surfaces as `HttpError` 404 `NOT_FOUND`, with no fallback.
final class SignInSettingsLiveTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-sign-in-settings-5362")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await client?.destroy()
        if let ctx: TestContext = ctx { await ctx.cleanup() }
    }

    /// A direct, unauthenticated read of the route.
    private func readRoute(appId: String) async throws -> (status: Int, json: [String: Any]) {
        let url = try XCTUnwrap(URL(string: "\(TestConfig.httpUrl)/app/\(appId)/api/settings/sign-in"))
        var request = URLRequest(url: url)
        request.setValue(TestConfig.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    func testTheConfigReadsAnswerWhatTheRouteAnswers() async throws {
        try await ctx.updateAppSettings(
            appId: testApp.appId,
            settings: ["emailSignInEnabled": true, "waitlistEnabled": true]
        )

        let (status, route) = try await readRoute(appId: testApp.appId)
        XCTAssertEqual(status, 200)

        let config = try await client.auth.getAuthConfig()
        XCTAssertEqual(config.appId, route["appId"] as? String)
        XCTAssertEqual(config.name, route["name"] as? String)
        XCTAssertEqual(config.mode, route["mode"] as? String)
        XCTAssertEqual(config.waitlistEnabled, route["waitlistEnabled"] as? Bool)
        XCTAssertEqual(config.googleOAuthEnabled, route["googleOAuthEnabled"] as? Bool)
        XCTAssertEqual(config.hasPasskey, route["hasPasskey"] as? Bool)
        XCTAssertEqual(config.hasApple, route["hasApple"] as? Bool)
        XCTAssertTrue(config.emailSignInEnabled)
        let routeClients = (route["googleClients"] as? [String: Any])?["clients"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(config.googleClients?.clients.keys ?? [:].keys), Set(routeClients.keys))
        for (type, entry) in config.googleClients?.clients ?? [:] {
            XCTAssertEqual(entry.clientId, (routeClients[type] as? [String: Any])?["clientId"] as? String, type)
        }

        let app = try await client.auth.getAppConfig()
        XCTAssertEqual(app.appId, testApp.appId)
        XCTAssertTrue(app.waitlistEnabled)
        XCTAssertTrue(app.emailSignInEnabled)
    }

    func testAnUnknownAppSurfaces404NotFound() async throws {
        let unknown = createTestClient(appId: "app-that-does-not-exist-5362", token: testApp.ownerJWT)
        do {
            let (status, route) = try await readRoute(appId: "app-that-does-not-exist-5362")
            XCTAssertEqual(status, 404)
            XCTAssertEqual(route["code"] as? String, "NOT_FOUND")

            for read in ["getAuthConfig", "getAppConfig"] {
                do {
                    if read == "getAuthConfig" {
                        _ = try await unknown.auth.getAuthConfig()
                    } else {
                        _ = try await unknown.auth.getAppConfig()
                    }
                    XCTFail("\(read): expected a 404")
                } catch let error as HttpError {
                    XCTAssertEqual(error.status, 404, read)
                    XCTAssertEqual(error.serverCode, "NOT_FOUND", read)
                }
            }

            let available = await unknown.checkOAuthAvailable()
            XCTAssertFalse(available)
        }
        await unknown.destroy()
    }
}
