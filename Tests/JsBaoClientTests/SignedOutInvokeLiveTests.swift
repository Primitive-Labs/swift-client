import XCTest
@testable import JsBaoClient

/// A Swift client with no token invokes a `public` function (project
/// `public-access`, criterion 3: a signed-out Swift client invokes a function
/// that declares `public`).
///
/// The Swift client sets `Authorization` only when it has a token, so a client
/// built without one is a signed-out caller. In an app with `signedOutAccess`
/// on, it invokes a function that declares `public = true` and runs
/// `authorize`, which sees the caller as `anonymous`; a function that does
/// not declare `public` answers the credential-less 401 as `HttpError`.
final class SignedOutInvokeLiveTests: XCTestCase {
    private var ctx: TestContext!
    private var testApp: TestApp!
    private var client: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-signed-out")
        // No `token`: the client sends no Authorization header.
        client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: TestConfig.wsUrl,
            appId: testApp.appId,
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            wsHeaders: ["X-Global-Admin-App-Id": TestConfig.globalAdminAppId],
            logLevel: .warn,
            storageConfig: .memory,
            autoNetwork: false
        ))
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx?.cleanup()
    }

    private static let whoBundle = #"""
    import { allow, defineFunction } from "primitive-functions";
    export default defineFunction({
      authorize: async (input, auth) => allow({ role: auth.user ? auth.user.role : null }),
      handler: async (input, ctx) => ({ role: ctx.auth ? ctx.auth.role : null, signedIn: ctx.user !== null }),
    });
    """#

    func testSignedOutClientInvokesAPublicFunctionAndIsRefusedAClosedOne() async throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let publicKey = "swift-so-pub-\(stamp)"
        let closedKey = "swift-so-closed-\(stamp)"
        _ = try await ctx.pushFunction(
            appId: testApp.appId, functionKey: publicKey, bundle: Self.whoBundle, tomlExtra: "public = true\n"
        )
        _ = try await ctx.pushFunction(appId: testApp.appId, functionKey: closedKey, bundle: Self.whoBundle)
        try await ctx.updateAppSettings(appId: testApp.appId, body: ["signedOutAccess": true])

        let result: FunctionResult<JSONValue> = try await client.functions.invoke(
            publicKey, input: [String: String](), timeout: 20
        )
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.output?["role"]?.stringValue, "anonymous")
        XCTAssertEqual(result.output?["signedIn"], .bool(false))

        do {
            let _: FunctionResult<JSONValue> = try await client.functions.invoke(
                closedKey, input: [String: String](), timeout: 20
            )
            XCTFail("a function that is not public must be refused")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 401)
            XCTAssertEqual(error.serverCode, "UNAUTHENTICATED")
        }
    }
}
