import XCTest
@testable import JsBaoClient

/// Port of tests/client/js-bao-client-llm.test.ts
/// Tests the LLM API bindings.
final class LlmTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-llm")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    func testModelsReturnsModelsOrClearError() async throws {
        do {
            let res = try await client.llm.models()
            XCTAssertGreaterThan(res.models.count, 0)
            XCTAssertFalse(res.defaultModel.isEmpty, "Expected a non-empty default model")
        } catch {
            // If upstream key is not configured, we get an error
            let msg = String(describing: error)
            XCTAssertTrue(
                msg.contains("OPENROUTER_API_KEY") || msg.contains("500") || msg.contains("error"),
                "Expected clear error about missing API key, got: \(msg)"
            )
        }
    }

    func testChatValidatesInput() async throws {
        do {
            _ = try await client.llm.chat(options: LlmChatOptions(messages: []))
            XCTFail("Should have thrown for empty messages")
        } catch {
            let msg = String(describing: error)
            XCTAssertTrue(
                msg.contains("messages") || msg.contains("400") || msg.contains("required"),
                "Expected validation error, got: \(msg)"
            )
        }
    }

    /// Ported from JS: "llm.chat() returns assistant message when upstream key present (or clear error otherwise)"
    func testChatReturnsAssistantMessageOrClearError() async throws {
        do {
            let result = try await client.llm.chat(options: LlmChatOptions(
                messages: [
                    ChatMessage(role: "system", text: "Reply concisely."),
                    ChatMessage(role: "user", text: "Write a haiku about primitive food."),
                ],
                temperature: 0.3
            ))

            XCTAssertEqual(result.role, "assistant")
            XCTAssertNotNil(result.content, "Expected content in response")
        } catch {
            // If upstream key is not configured or upstream returns an error
            let msg = String(describing: error)
            let isExpectedError = msg.contains("OPENROUTER_API_KEY")
                || msg.contains("Upstream")
                || msg.contains("HTTP 4")
                || msg.contains("HTTP 5")
                || msg.contains("500")
            XCTAssertTrue(isExpectedError, "Expected clear upstream error, got: \(msg)")
        }
    }

    func testChatReturnsErrorForInvalidModel() async throws {
        do {
            _ = try await client.llm.chat(options: LlmChatOptions(
                model: "not/a-real-model",
                messages: [ChatMessage(role: "user", text: "Hello")]
            ))
            XCTFail("Should have thrown for invalid model")
        } catch {
            // Either missing API key or invalid model error
            let msg = String(describing: error)
            XCTAssertTrue(msg.count > 0, "Expected non-empty error message")
        }
    }
}
