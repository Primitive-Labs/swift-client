import XCTest
@testable import JsBaoClient

/// Regression tests for path-parameter percent-encoding in the real URL
/// builder (`HttpClient.buildURLRequest`).
///
/// The sub-API wire-parity tests (e.g. `NotificationsAPITests`) use a stub
/// `makeRequest` recorder that captures the path string but never runs
/// `buildURLRequest`, so they cannot see how the final on-the-wire URL is
/// assembled. That gap hid a double-encoding bug: a sub-API pre-escapes a
/// path segment with `.addingPercentEncoding(withAllowedCharacters:
/// .urlPathAllowed)`, and the old `URLComponents.path` setter re-encoded the
/// resulting `%`, turning an FCM token's `:` (`%3A`) into `%253A` on the wire.
/// The server decoded that once back to the literal `%3A` (never `:`), so the
/// stale token stayed registered after logout (issue #1601 codex review).
///
/// These tests drive `buildURLRequest` directly and assert the segment is
/// single-encoded (`%3A`, not `%253A`).
final class HttpClientPathEncodingTests: XCTestCase {

    private func makeClient(appId: String = "app123") -> HttpClient {
        HttpClient(config: HttpClientConfig(
            apiUrl: "https://api.example.com",
            appId: appId,
            getToken: { nil },
            getConnectionId: { nil },
            getGlobalAdminAppId: { "global-admin" },
            logger: Logger(level: .none, scope: "test"),
            refreshAccessToken: { .success }
        ))
    }

    /// The same escaping `NotificationsAPI.unregisterDevice` applies before
    /// handing the path to `makeRequest` → `buildURLRequest`.
    private func pathEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    /// An FCM-style token containing `:` must reach the wire single-encoded.
    func test_pathParam_withColon_isSingleEncoded() throws {
        let client = makeClient()
        // Mirror the sub-API: pre-escape the token, then interpolate.
        let escaped = pathEscape("abc:def")
        let request = try client.buildURLRequest(
            method: "DELETE",
            path: "/me/push-tokens/\(escaped)"
        )
        let url = try XCTUnwrap(request.url?.absoluteString)

        XCTAssertTrue(
            url.contains("/me/push-tokens/abc%3Adef"),
            "token `:` must be single-encoded as %3A, got: \(url)"
        )
        XCTAssertFalse(
            url.contains("%253A"),
            "token must not be double-encoded (%253A), got: \(url)"
        )
    }

    /// A space in a path segment is likewise single-encoded (`%20`, not
    /// `%2520`).
    func test_pathParam_withSpace_isSingleEncoded() throws {
        let client = makeClient()
        let escaped = pathEscape("tok with space")
        let request = try client.buildURLRequest(
            method: "DELETE",
            path: "/me/push-tokens/\(escaped)"
        )
        let url = try XCTUnwrap(request.url?.absoluteString)

        XCTAssertTrue(url.contains("/me/push-tokens/tok%20with%20space"), url)
        XCTAssertFalse(url.contains("%2520"), url)
    }

    /// A plain ULID path parameter (e.g. `markRead`'s notification id) is
    /// unaffected — no reserved characters, so it appears verbatim.
    func test_pathParam_ulid_isVerbatim() throws {
        let client = makeClient()
        let id = "01HZY8Q9ABC"
        let request = try client.buildURLRequest(
            method: "PATCH",
            path: "/notifications/\(pathEscape(id))/read"
        )
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.contains("/notifications/01HZY8Q9ABC/read"), url)
        XCTAssertFalse(url.contains("%"), "plain ULID must not be percent-encoded: \(url)")
    }

    /// The query string keeps its existing single-encoding contract
    /// (`.percentEncodedQuery`) — a guard that the path change did not disturb
    /// the query side.
    func test_query_isSingleEncoded() throws {
        let client = makeClient()
        let escaped = "abc%20def" // caller pre-encoded, as sub-APIs do
        let request = try client.buildURLRequest(
            method: "GET",
            path: "/notifications?cursor=\(escaped)"
        )
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.contains("cursor=abc%20def"), url)
        XCTAssertFalse(url.contains("%2520"), url)
    }
}
