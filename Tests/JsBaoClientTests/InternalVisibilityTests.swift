import XCTest
@testable import JsBaoClient

/// The WebSocket plumbing must not be part of the client's public API (#2363).
///
/// `WebSocketManagerDelegate` was declared `public`, so `JsBaoClient`'s
/// conformance put all 13 `webSocketManagerOn*` / `webSocketManagerBuild*`
/// methods on the client's public autocomplete (the issue says 14; the
/// protocol has 13 requirements). App code could call
/// `webSocketManagerBuildConnectionRequest(connectionId:)` — which returns a
/// URL carrying the bearer token in `?token=` — or call
/// `webSocketManagerOnClose(code:reason:)` to inject connection-lifecycle
/// events that the app's own observers receive as real. `WebSocketManager`
/// and `Logger` were public for the same reason: nothing outside the module
/// implements or calls them, they just never had their access level narrowed.
///
/// Access control is a compile-time property, so nothing at runtime can
/// observe it — a test that *calls* these methods compiles either way,
/// because the test target uses `@testable import`. So the check is
/// source-structural, in the style of the other invariant tests in this
/// target (`SwiftSixLanguageModeTests`, `UncappedPowConversionGuardTests`).
/// It reads the committed sources and asserts no `public`/`open` declaration
/// has come back.
///
/// **Known blind spots.** This is a text scan, not a type checker:
/// - It recognises an explicit `public`/`open` keyword at the start of a
///   declaration line. A member made public by a `public extension` header is
///   caught only by the dedicated extension check below.
/// - Line continuations are not understood: a declaration whose `public`
///   keyword is not the first token on its line is invisible.
/// - `@_spi(...) public` counts as public here, on purpose — SPI narrows who
///   can see a symbol but it stays in the module's public interface.
final class InternalVisibilityTests: XCTestCase {

    // MARK: - The scan

    /// Declaration lines in `source` that start with `public` or `open`,
    /// as `(line number, trimmed text)`.
    private static func publicDeclarations(in source: String) -> [(line: Int, text: String)] {
        ClientSourceText.stripComments(source)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("public ") || trimmed.hasPrefix("open ")
                    || trimmed.hasPrefix("@_spi") && trimmed.contains(" public ")
                else { return nil }
                return (line: index + 1, text: trimmed)
            }
    }

    private static func assertNoPublicDeclarations(
        in relativePath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let source = try ClientSourceText.clientSource(relativePath)
        let offenders = publicDeclarations(in: source)
        XCTAssertTrue(
            offenders.isEmpty,
            """
            \(relativePath) is module-internal plumbing — it must declare nothing \
            `public` (#2363). Found:
            \(offenders.map { "  \(relativePath):\($0.line) — \($0.text)" }.joined(separator: "\n"))
            """,
            file: file,
            line: line
        )
    }

    // MARK: - Behavior 1 — the delegate protocol is internal

    func testWebSocketManagerDelegateProtocolIsNotPublic() throws {
        let source = ClientSourceText.stripComments(
            try ClientSourceText.clientSource("Internal/WebSocketManager.swift")
        )
        // Re-anchored by #2171: the actor conversion refines the protocol to
        // `AnyObject, Sendable`, so the old literal `AnyObject {` anchor no
        // longer matches. Anchored on the inheritance-clause prefix instead, so
        // a further refinement does not silently turn this check into a no-op.
        XCTAssertTrue(
            source.contains("protocol WebSocketManagerDelegate: AnyObject"),
            "the delegate protocol declaration moved — re-anchor this test"
        )
        XCTAssertTrue(
            source.contains("protocol WebSocketManagerDelegate: AnyObject, Sendable {"),
            "the delegate protocol must keep its Sendable refinement (#2171 Fork 4): "
                + "the manager is an actor and calls the delegate from nonisolated context"
        )
        XCTAssertFalse(
            source.contains("public protocol WebSocketManagerDelegate"),
            "WebSocketManagerDelegate must be internal (#2363): a public protocol puts "
                + "every conformance method on JsBaoClient's public API"
        )
    }

    // MARK: - Behavior 2 — the 14 conformance methods are internal

    func testDelegateConformanceMethodsAreNotPublic() throws {
        let source = ClientSourceText.stripComments(
            try ClientSourceText.clientSource("JsBaoClient.swift")
        )

        let declarations = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("func webSocketManager") }

        XCTAssertEqual(
            declarations.count, 13,
            "expected the 13 WebSocketManagerDelegate conformance methods in "
                + "JsBaoClient.swift — found \(declarations.count); re-anchor this test"
        )

        let publicOnes = declarations.filter { $0.hasPrefix("public ") || $0.hasPrefix("open ") }
        XCTAssertTrue(
            publicOnes.isEmpty,
            """
            the WebSocketManagerDelegate conformance methods must not be public (#2363) — \
            one of them returns the `?token=`-bearing connection URL and the rest let app \
            code inject connection-lifecycle events. Found:
            \(publicOnes.map { "  \($0)" }.joined(separator: "\n"))
            """
        )
    }

    /// A `public extension` header would make every member public without any
    /// member-level `public` keyword, which the scan above cannot see.
    func testDelegateConformanceExtensionIsNotPublic() throws {
        let source = ClientSourceText.stripComments(
            try ClientSourceText.clientSource("JsBaoClient.swift")
        )
        XCTAssertTrue(
            source.contains("extension JsBaoClient: WebSocketManagerDelegate {"),
            "the conformance extension moved — re-anchor this test"
        )
        XCTAssertFalse(
            source.contains("public extension JsBaoClient: WebSocketManagerDelegate"),
            "a public extension header would re-expose all 14 conformance methods (#2363)"
        )
    }

    // MARK: - Behavior 3 — the Internal/ plumbing files declare nothing public

    func testWebSocketManagerFileDeclaresNothingPublic() throws {
        try Self.assertNoPublicDeclarations(in: "Internal/WebSocketManager.swift")
    }

    func testLoggerFileDeclaresNothingPublic() throws {
        try Self.assertNoPublicDeclarations(in: "Internal/Logger.swift")
    }

    // MARK: - Behavior 4 — the genuinely public types stayed public, outside Internal/

    /// `LogLevel` is part of the public surface (`JsBaoClientOptions.logLevel`,
    /// `client.setLogLevel(_:)`) and `WebSocketError` is thrown out of the
    /// connect path for apps to catch. Narrowing either would be a real API
    /// break, so they moved to `Types/` rather than going internal — and this
    /// test fails if a later sweep of `Internal/` takes them down with it.
    func testPublicLogAndErrorTypesStayPublicOutsideInternal() throws {
        let logLevel = try ClientSourceText.clientSource("Types/LogLevel.swift")
        XCTAssertTrue(
            ClientSourceText.stripComments(logLevel).contains("public enum LogLevel"),
            "LogLevel is public API (JsBaoClientOptions.logLevel, setLogLevel(_:))"
        )

        let errors = try ClientSourceText.clientSource("Types/Errors.swift")
        XCTAssertTrue(
            ClientSourceText.stripComments(errors).contains("public enum WebSocketError"),
            "WebSocketError is public API — apps catch it from the connect path"
        )
    }
}
