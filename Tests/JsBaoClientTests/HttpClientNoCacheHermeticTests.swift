import XCTest
@testable import JsBaoClient

/// The client stores no HTTP response on disk (#3170).
///
/// Foundation's `URLCache` keys entries by URL alone — it ignores
/// `Authorization` — and `URLCache.shared`, which every `URLSessionConfiguration
/// .default` and `URLSession.shared` uses, is disk-backed on iOS. An
/// authenticated app API response landing there is readable by a request
/// carrying a different token or none, and survives app restarts unencrypted.
///
/// Both HTTP surfaces of the client are covered: `HttpClient`'s own session,
/// and the `NetworkSession` choke point every other call goes through (blob
/// reads, `exchangeOAuthCode`, the refresh proxy, oversized-update downloads).
///
/// The assertions are configuration, request and source inspections rather
/// than "stub a cacheable 200 and check the cache stayed empty": `URLCache`
/// writes are asynchronous with no completion signal, and a session with no
/// cache cannot store anything anyway.
final class HttpClientNoCacheHermeticTests: XCTestCase {

    // MARK: - Fixtures

    private func makeClient(
        sessionConfiguration: URLSessionConfiguration? = nil
    ) -> HttpClient {
        HttpClient(config: HttpClientConfig(
            apiUrl: "http://stub.local",
            appId: "test-app",
            getToken: { "test-token" },
            getConnectionId: { nil },
            getGlobalAdminAppId: { "global-admin-app" },
            logger: Logger(level: .error),
            refreshAccessToken: { .success },
            sessionConfiguration: sessionConfiguration
        ))
    }

    // MARK: - Behavior 5: the default session

    func testDefaultSessionHasNoUrlCacheAndIgnoresLocalCacheData() {
        let http = makeClient()

        XCTAssertNil(
            http.session.configuration.urlCache,
            "an HttpClient built with no session configuration must not carry a URLCache — the default one is URLCache.shared, disk-backed and keyed by URL alone"
        )
        XCTAssertEqual(
            http.session.configuration.requestCachePolicy,
            .reloadIgnoringLocalCacheData,
            "the session must never read or write a cached response"
        )
    }

    // MARK: - Behavior 6: an app-supplied configuration is overridden

    func testAppSuppliedConfigurationCarryingAUrlCacheIsOverridden() {
        let supplied = URLSessionConfiguration.default
        supplied.urlCache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 5_000_000)
        supplied.requestCachePolicy = .returnCacheDataElseLoad

        let http = makeClient(sessionConfiguration: supplied)

        XCTAssertNil(
            http.session.configuration.urlCache,
            "an app-supplied configuration must not be able to reintroduce a URLCache — the override is what protects apps running against workers that predate the server's no-store header"
        )
        XCTAssertEqual(
            http.session.configuration.requestCachePolicy,
            .reloadIgnoringLocalCacheData,
            "an app-supplied cache policy must not be able to serve a stored response"
        )
    }

    func testEveryBuiltRequestCarriesTheNoCachePolicy() throws {
        let http = makeClient()

        let get = try http.buildURLRequest(method: "GET", path: "/me", body: nil)
        XCTAssertEqual(
            get.cachePolicy,
            .reloadIgnoringLocalCacheData,
            "the no-cache contract must travel with the request, not only with the session"
        )

        let post = try http.buildURLRequest(
            method: "POST",
            path: "/documents",
            body: Data(#"{"title":"t"}"#.utf8)
        )
        XCTAssertEqual(post.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    // MARK: - Behavior 7: the NetworkSession choke point

    func testNetworkSessionDefaultSessionIsCacheDisabled() {
        XCTAssertNil(
            NetworkSession.uncached.configuration.urlCache,
            "blob reads, exchangeOAuthCode, the refresh proxy and update downloads all ride this session"
        )
        XCTAssertEqual(
            NetworkSession.uncached.configuration.requestCachePolicy,
            .reloadIgnoringLocalCacheData
        )
    }

    /// The refresh-proxy flow keeps its refresh cookie in `URLSession`'s shared
    /// cookie storage, so the replacement session must be built from
    /// `.default` — an `.ephemeral` one would carry its own isolated storage
    /// and silently break refresh.
    func testNetworkSessionDefaultSessionKeepsSharedCookieStorage() {
        XCTAssertTrue(
            NetworkSession.uncached.configuration.httpCookieStorage === HTTPCookieStorage.shared,
            "the refresh-proxy cookie flow depends on shared cookie storage"
        )
        XCTAssertTrue(
            NetworkSession.uncached.configuration.httpShouldSetCookies,
            "cookie handling is unchanged; only caching is disabled"
        )
    }

    /// `URLSessionConfiguration.default` hands back a fresh instance per
    /// access, so disabling the cache on one must not disturb any other
    /// session in the host app.
    func testDisablingTheCacheDoesNotLeakIntoTheHostApplicationsDefaults() {
        _ = makeClient()
        _ = NetworkSession.uncached

        XCTAssertNotNil(
            URLSessionConfiguration.default.urlCache,
            "the client must not mutate the process-wide default configuration"
        )
    }

    // MARK: - Behaviors 8 and the un-purged shared cache: the source scan

    /// The bypass class this closes: any call that reaches `URLSession.shared`
    /// (or defaults a parameter to it) is back on `URLCache.shared`. Same
    /// pattern as `TransportSpineTests`' converted-call-site sweep.
    func testNoSourceFileReachesTheSharedSessionOrSharedCache() throws {
        let forbidden = [
            "URLSession.shared",
            "URLSession = .shared",
            "URLCache.shared",
        ]

        var offenders: [String] = []
        for (relativePath, url) in try swiftSourceFiles() {
            let contents = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in contents.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                for spelling in forbidden where code.contains(spelling) {
                    offenders.append("\(relativePath):\(index + 1): \(spelling)")
                }
            }
        }

        XCTAssertEqual(
            offenders,
            [],
            """
            No client source may touch the shared session or the shared cache: \
            the shared session uses URLCache.shared, and the client neither \
            reads, writes nor purges entries there (they belong to the host \
            app). Route the call through NetworkSession's uncached session.
            """
        )
    }

    // MARK: - Behavior 10: the change is announced

    func testChangelogAnnouncesTheForcedCacheSettings() throws {
        let changelog = try String(
            contentsOf: packageDirectory.appendingPathComponent("CHANGELOG.md"),
            encoding: .utf8
        )

        XCTAssertTrue(
            changelog.contains("#3170"),
            "the caller-visible cache change must be announced in the CHANGELOG"
        )
        for phrase in ["urlCache", "sessionConfiguration", "no-store"] {
            XCTAssertTrue(
                changelog.contains(phrase),
                "the CHANGELOG entry must name '\(phrase)': an app that deliberately configured a URLCache no longer gets one, and blob responses are no longer storable by intermediary caches for revalidation reuse"
            )
        }
    }

    // MARK: - Source helpers (derived from this file's path)

    /// `swift-client`, derived from this file's path.
    private var packageDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // JsBaoClientTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // swift-client
    }

    /// Every `.swift` file under `Sources/JsBaoClient`, at any depth.
    private func swiftSourceFiles() throws -> [(relativePath: String, url: URL)] {
        let root = packageDirectory.appendingPathComponent("Sources/JsBaoClient")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var found: [(String, URL)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            found.append((url.path.replacingOccurrences(of: root.path + "/", with: ""), url))
        }
        XCTAssertFalse(found.isEmpty, "the source sweep found no files — check the path derivation")
        return found.sorted { $0.0 < $1.0 }
    }
}
