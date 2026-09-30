import XCTest
@testable import JsBaoClient

/// #3857 — the Swift client has no direct LLM / Gemini surface.
///
/// All LLM access goes through prompts (`client.prompts`), so the `.llm` /
/// `.gemini` sub-APIs, their types, the `.geminiError` code, and the analytics
/// plumbing that existed only to let those two sub-APIs log — the
/// `llmAnalyticsContext` / `geminiAnalyticsContext` accessors and the private
/// `makeAnalyticsContext()` / `prepareAnalyticsEvent` helpers behind them —
/// are gone. The public `AnalyticsContext` type stays: it is constructed
/// directly, and its own suite covers it.
///
/// Server-free (`*HermeticTests`): a source inventory, read comment-stripped
/// so a phrase in a doc comment cannot decide it.
final class DirectLlmRemoved3857HermeticTests: XCTestCase {

    private var clientRoot: URL {
        ClientSourceText.packageRoot.appendingPathComponent("Sources/JsBaoClient")
    }

    func testTheSubApiAndTypeFilesAreGone() {
        for file in [
            "API/LlmAPI.swift",
            "API/GeminiAPI.swift",
            "Types/LlmTypes.swift",
            "Types/GeminiTypes.swift",
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: clientRoot.appendingPathComponent(file).path),
                "\(file) must not exist"
            )
        }
    }

    func testTheClientDeclaresNoAccessorOrAnalyticsPlumbingForThem() throws {
        let source = try ClientSourceText.code("JsBaoClient.swift")
        for marker in [
            "var llm",
            "var gemini",
            "_llm",
            "_gemini",
            "llmAnalyticsContext",
            "geminiAnalyticsContext",
            "makeAnalyticsContext",
            "prepareAnalyticsEvent",
        ] {
            XCTAssertFalse(source.contains(marker), "JsBaoClient.swift still carries `\(marker)`")
        }
    }

    func testTheErrorCodeIsGone() throws {
        let source = try ClientSourceText.code("Types/Errors.swift")
        XCTAssertFalse(source.contains("geminiError"))
        XCTAssertFalse(source.contains("GEMINI_ERROR"))
    }

    func testTheAnalyticsContextTypeStays() {
        // The type the removed accessors handed out is still public and still
        // constructible — the analytics surface keeps using it.
        let context = AnalyticsContext(logEvent: { _ in })
        XCTAssertTrue(context.isEnabled())
    }
}
