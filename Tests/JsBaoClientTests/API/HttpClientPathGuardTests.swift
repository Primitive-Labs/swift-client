import XCTest
@testable import JsBaoClient

/// Guard tests for the *builder's contract*: `HttpClient.buildURLRequest`
/// must report an un-pre-encoded (or malformed) path by throwing `HttpError`,
/// the way every other failure in that method does.
///
/// Since #1601 the builder assigns the assembled path to
/// `URLComponents.percentEncodedPath`, which passes its input through verbatim
/// and traps (`Fatal error: Attempting to set percentEncodedPath with invalid
/// characters`) on anything that isn't already a legal percent-encoded path.
/// A `fatalError` cannot be caught, so one raw path value killed the calling
/// app's process. These tests pin the throwing behavior so the builder stays
/// safe even if a future call site bypasses the sub-APIs' escaping. The query
/// half is covered too: `.percentEncodedQuery` traps the same way, so it gets
/// the same guard — against the query character set rather than the path one.
///
/// `HttpClientPathEncodingTests` covers the complementary half — that a
/// *correctly* pre-encoded segment reaches the wire single-encoded.
final class HttpClientPathGuardTests: XCTestCase {

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

    /// Assert `buildURLRequest` throws an `HttpError` whose message names the
    /// offending path, and return that error for further inspection.
    @discardableResult
    private func expectHttpError(
        _ client: HttpClient,
        method: String = "GET",
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> HttpError {
        do {
            _ = try client.buildURLRequest(method: method, path: path)
            XCTFail("expected buildURLRequest to throw for path: \(path)", file: file, line: line)
            throw XCTSkip("unreachable")
        } catch let error as HttpError {
            return error
        }
    }

    /// The reported repro: `GroupsAPI` interpolating a group type raw. A space
    /// is not legal in a percent-encoded path, so this used to trap.
    func test_rawSegment_withSpace_throwsInsteadOfTrapping() throws {
        let client = makeClient()
        let error = try expectHttpError(
            client,
            path: "/groups/my team/01ARZ3NDEKTSV4RRFFQ69G5FAV"
        )
        XCTAssertEqual(error.status, 0)
        XCTAssertTrue(
            error.message.contains("/groups/my team/01ARZ3NDEKTSV4RRFFQ69G5FAV"),
            "error must name the offending path, got: \(error.message)"
        )
    }

    /// Non-ASCII raw input is the other common shape of an un-escaped value.
    func test_rawSegment_withNonASCII_throws() throws {
        let client = makeClient()
        let error = try expectHttpError(client, path: "/groups/café/01ARZ3ND")
        XCTAssertTrue(error.message.contains("café"), error.message)
    }

    /// A `%` that doesn't introduce a valid escape triplet is malformed even
    /// though `%` itself is legal in a percent-encoded path — e.g. a caller
    /// that interpolated a literal `100%` without escaping it.
    func test_malformedPercentEscape_throws() throws {
        let client = makeClient()
        try expectHttpError(client, path: "/groups/100%zz/01ARZ3ND")
    }

    /// A trailing `%` has no room for the two hex digits.
    func test_trailingPercent_throws() throws {
        let client = makeClient()
        try expectHttpError(client, path: "/groups/discount%")
    }

    /// The guard covers the whole assembled path, including the app id the
    /// builder interpolates ahead of the caller's path.
    func test_invalidAppId_throws() throws {
        let client = makeClient(appId: "app 123")
        try expectHttpError(client, path: "/groups/team")
    }

    /// The guard must not reject legal URLs: characters that are reserved but
    /// allowed in a path pass through unchanged.
    func test_pathWithLegalReservedCharacters_isAccepted() throws {
        let client = makeClient()
        let request = try client.buildURLRequest(
            method: "GET",
            path: "/things/a:b@c+d,e;f=g~h!i/sub"
        )
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.hasSuffix("/things/a:b@c+d,e;f=g~h!i/sub"), url)
    }

    /// A correctly pre-encoded segment still passes through verbatim — the
    /// guard accepts valid escape triplets rather than treating `%` as raw.
    func test_preEncodedSegment_isStillAccepted() throws {
        let client = makeClient()
        let escaped = "my%20team"
        let request = try client.buildURLRequest(
            method: "GET",
            path: "/groups/\(escaped)/01ARZ3ND"
        )
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.contains("/groups/my%20team/01ARZ3ND"), url)
        XCTAssertFalse(url.contains("%2520"), url)
    }

    /// The query half is guarded too — `.percentEncodedQuery` traps for the
    /// same reason `.percentEncodedPath` does — but against the *query*
    /// character set, not the path one. `?` is the discriminating case: it is
    /// legal in `.urlQueryAllowed` and illegal in `.urlPathAllowed`, so a
    /// query containing one only survives if the query set is the one applied.
    func test_queryIsValidatedAgainstQuerySet() throws {
        let client = makeClient()
        let request = try client.buildURLRequest(
            method: "GET",
            path: "/users/lookup?email=a%2Bb@example.com&filter=a?b"
        )
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.contains("email=a%2Bb@example.com"), url)
        XCTAssertTrue(url.contains("filter=a?b"), url)
    }

    /// A raw (un-pre-encoded) value in the query used to trap in
    /// `.percentEncodedQuery` exactly as it did in `.percentEncodedPath`; it
    /// must throw instead. Without the query-half guard this test crashes the
    /// suite rather than failing.
    func test_rawQueryValue_withSpace_throwsInsteadOfTrapping() throws {
        let client = makeClient()
        let error = try expectHttpError(client, path: "/users/lookup?email=a b@example.com")
        XCTAssertEqual(error.status, 0)
        XCTAssertTrue(
            error.message.contains("/users/lookup?email=a b@example.com"),
            "error must name the offending path, got: \(error.message)"
        )
    }

    /// A malformed escape in the query is rejected the same way as in the path.
    func test_malformedPercentEscapeInQuery_throws() throws {
        let client = makeClient()
        let error = try expectHttpError(client, path: "/users/lookup?cursor=%zz")
        XCTAssertEqual(error.status, 0)
    }
}
