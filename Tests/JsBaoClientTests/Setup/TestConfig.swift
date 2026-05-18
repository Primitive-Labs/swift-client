import Foundation

/// Configuration for integration tests against a live dev server.
///
/// Environment variables:
///   - TEST_HTTP_URL: HTTP endpoint (default http://localhost:8787)
///   - TEST_WS_URL: WebSocket endpoint (default ws://localhost:8787)
///   - TEST_SUPERADMIN_JWT: Required super-admin JWT for provisioning test apps/users
///   - TEST_GLOBAL_ADMIN_APP_ID: Global admin app ID (default global-admin-app)
struct TestConfig {
    static let httpUrl: String = {
        ProcessInfo.processInfo.environment["TEST_HTTP_URL"] ?? "http://localhost:8787"
    }()

    static let wsUrl: String = {
        ProcessInfo.processInfo.environment["TEST_WS_URL"] ?? "ws://localhost:8787"
    }()

    static let superAdminJwt: String? = {
        ProcessInfo.processInfo.environment["TEST_SUPERADMIN_JWT"]
    }()

    /// Shared secret used by the local dev server to sign JWTs. Only needed
    /// by tests that forge their own refresh tokens (see RefreshTests cold
    /// start). Defaults to the dev-server's documented test secret so
    /// running `./run-tests.sh` works without extra env setup; prod servers
    /// use a distinct secret and this default would not verify against them.
    static let jwtSecret: String = {
        ProcessInfo.processInfo.environment["TEST_JWT_SECRET"]
            ?? "test-jwt-secret-only-for-tests"
    }()

    static let globalAdminAppId: String = {
        ProcessInfo.processInfo.environment["TEST_GLOBAL_ADMIN_APP_ID"] ?? "global-admin-app"
    }()

    static let timeouts = (
        websocketConnect: TimeInterval(5),
        websocketSync: TimeInterval(10),
        httpRequest: TimeInterval(30),
        testDefault: TimeInterval(30)
    )
}
