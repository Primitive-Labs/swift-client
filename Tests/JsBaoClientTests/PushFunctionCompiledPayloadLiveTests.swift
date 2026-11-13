import Foundation
import XCTest
@testable import JsBaoClient

/// `TestContext.pushFunction` pushes a function the way the current CLI does
/// (#5775): the configs push carries the compiled payload for the TOML's
/// schemas, and the TOML declares the schemas the header was created with.
///
/// Every live suite that pushes a function goes through this helper, so a
/// push the server refuses fails all of them in setup. These cases pin the
/// helper itself against a live server: a bare handler lands, a header's
/// schemas survive the push, schema text that needs TOML escaping round-trips,
/// and a schema the helper cannot compile is refused by the helper with a
/// message that says so.
final class PushFunctionCompiledPayloadLiveTests: XCTestCase {
    private var ctx: TestContext!
    private var testApp: TestApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-push-payload")
    }

    override func tearDown() async throws {
        await ctx?.cleanup()
    }

    private var counter = 0
    private func key(_ label: String) -> String {
        counter += 1
        return "swift-5775-\(label)-\(Int(Date().timeIntervalSince1970))-\(counter)"
    }

    /// The header's stored schema field as a value: stored as JSON text.
    private func storedSchema(_ value: Any?) -> NSDictionary? {
        if let text = value as? String,
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? NSDictionary {
            return object
        }
        return value as? NSDictionary
    }

    private func header(_ pushed: TestContext.PushedFunction) async throws -> [String: Any] {
        try await ctx.adminGet("/admin/api/apps/\(testApp.appId)/functions/\(pushed.functionId)")
    }

    /// A bare handler with no schemas lands, and the version it pushed runs.
    func testBareHandlerPushLandsAndRuns() async throws {
        let functionKey = key("bare")
        let pushed = try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: functionKey,
            bundle: "export default async function (input) { return { echoed: input }; }"
        )
        XCTAssertNotNil(pushed.configId)

        let response = try await ctx.appRequest(
            method: "POST",
            appId: testApp.appId,
            path: "/functions/\(functionKey)",
            body: ["rootInput": ["a": 1], "timeoutMs": 20_000],
            jwt: testApp.ownerJWT
        )
        XCTAssertEqual(response["status"] as? String, "completed", "\(response)")
    }

    /// The schemas the header is created with are the ones it holds after the
    /// push: the push does not clear them, and the invoke validates against
    /// them.
    func testHeaderSchemasSurviveThePushAndBindTheInvoke() async throws {
        let functionKey = key("schemas")
        let inputSchema: [String: Any] = [
            "type": "object",
            "properties": ["topic": ["type": "string"]],
            "required": ["topic"],
        ]
        let outputSchema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": ["topic": ["type": "string"]],
        ]
        let pushed = try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: functionKey,
            bundle: "export default async (input) => ({ topic: input.topic });",
            inputSchema: inputSchema,
            outputSchema: outputSchema
        )

        let stored = try await header(pushed)
        XCTAssertEqual(storedSchema(stored["inputSchema"]), inputSchema as NSDictionary, "\(stored)")
        XCTAssertEqual(storedSchema(stored["outputSchema"]), outputSchema as NSDictionary, "\(stored)")

        let completed = try await ctx.appRequest(
            method: "POST",
            appId: testApp.appId,
            path: "/functions/\(functionKey)",
            body: ["rootInput": ["topic": "tides"], "timeoutMs": 20_000],
            jwt: testApp.ownerJWT
        )
        XCTAssertEqual(completed["status"] as? String, "completed", "\(completed)")

        do {
            let refused = try await ctx.appRequest(
                method: "POST",
                appId: testApp.appId,
                path: "/functions/\(functionKey)",
                body: ["rootInput": ["subject": "tides"], "timeoutMs": 20_000],
                jwt: testApp.ownerJWT
            )
            XCTFail("an input without the required topic was not refused: \(refused)")
        } catch let error as TestSetupError {
            XCTAssertTrue(error.message.contains("HTTP 400"), error.message)
        }
    }

    /// A schema whose text holds quotes, backslashes, a newline and non-ASCII
    /// characters is written into the TOML so it reads back as the same
    /// schema.
    func testSchemaTextThatNeedsTomlEscapingRoundTrips() async throws {
        let inputSchema: [String: Any] = [
            "type": "object",
            "title": "Café \"notes\" — ünïcode",
            "description": "a backslash \\ and a\nnewline\tand a tab",
            "properties": ["path": ["type": "string", "description": "C:\\temp\\\"x\""]],
        ]
        let pushed = try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: key("escaping"),
            bundle: "export default async (input) => input;",
            inputSchema: inputSchema
        )

        let stored = try await header(pushed)
        XCTAssertEqual(storedSchema(stored["inputSchema"]), inputSchema as NSDictionary, "\(stored)")
    }

    /// The helper sends a schema as its own compile, which only a ref-free
    /// schema is. One that holds a `$ref` or `$defs` is refused by the helper,
    /// naming the keyword, before anything is created.
    func testSchemaTheHelperCannotCompileIsRefusedByTheHelper() async throws {
        let functionKey = key("ref")
        do {
            try await ctx.pushFunction(
                appId: testApp.appId,
                functionKey: functionKey,
                bundle: "export default async (input) => input;",
                inputSchema: [
                    "type": "object",
                    "$defs": ["Topic": ["type": "string"]],
                    "properties": ["topic": ["$ref": "#/$defs/Topic"]],
                ]
            )
            XCTFail("a schema with $ref was pushed")
        } catch let error as TestSetupError {
            XCTAssertTrue(error.message.contains("$ref"), error.message)
            XCTAssertTrue(error.message.contains("ref-free"), error.message)
        }

        let listed = try await ctx.adminGet("/admin/api/apps/\(testApp.appId)/functions")
        let keys = ((listed["functions"] ?? listed["items"]) as? [[String: Any]] ?? [])
            .compactMap { $0["functionKey"] as? String }
        XCTAssertFalse(keys.contains(functionKey), "the helper created \(functionKey): \(listed)")
    }
}
