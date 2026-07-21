import Foundation
import CryptoKit

/// Configuration for integration tests against a live dev server.
///
/// Environment variables:
///   - TEST_HTTP_URL: HTTP endpoint (default http://localhost:8787)
///   - TEST_WS_URL: WebSocket endpoint (default ws://localhost:8787)
///   - TEST_SUPERADMIN_JWT: Optional pre-minted super-admin JWT. If unset,
///     the suite mints its own short-lived token (see `superAdminJwt`).
///   - TEST_JWT_SECRET: HS256 secret the dev server validates against
///     (default `test-jwt-secret-only-for-agents`, matching `.dev.vars`
///     `JWT_SECRET`).
///   - TEST_GLOBAL_ADMIN_APP_ID: Global admin app ID (default global-admin-app)
struct TestConfig {
    static let httpUrl: String = {
        ProcessInfo.processInfo.environment["TEST_HTTP_URL"] ?? "http://localhost:8787"
    }()

    static let wsUrl: String = {
        ProcessInfo.processInfo.environment["TEST_WS_URL"] ?? "ws://localhost:8787"
    }()

    /// HS256 secret the dev server signs/validates admin JWTs with. Defaults
    /// to the value in the repo's `.dev.vars` (`JWT_SECRET`) so tests work
    /// out of the box against a local `node debug-server.js`.
    static let jwtSecret: String = {
        ProcessInfo.processInfo.environment["TEST_JWT_SECRET"] ?? "test-jwt-secret-only-for-agents"
    }()

    /// Effective super-admin JWT used to provision test apps/users.
    ///
    /// Prefers an explicit `TEST_SUPERADMIN_JWT` when set and non-empty;
    /// otherwise mints a fresh short-lived token signed with `jwtSecret`.
    /// Self-minting removes the dependency on a hand-pasted 24h token that
    /// silently expires. The dev server accepts a self-minted token because
    /// `AdminAuthService.validateToken` builds a virtual super-admin from a
    /// JWT payload carrying both `adminId` and `email` when no matching
    /// `AdminUser` record exists (admin-auth-service.ts).
    static let superAdminJwt: String? = {
        if let jwt = ProcessInfo.processInfo.environment["TEST_SUPERADMIN_JWT"], !jwt.isEmpty {
            return jwt
        }
        return mintSuperAdminJwt()
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

    // MARK: - Self-minted super-admin JWT

    /// Mint an HS256 super-admin JWT signed with `jwtSecret`. Mirrors the
    /// payload the JS tests use (`{adminId, email, name, role:"super-admin",
    /// isSuperAdmin:true, appCreationLimit:50, type:"admin",
    /// enableTestFeatures:true}`) plus standard `iat`/`exp` claims.
    ///
    /// The `adminId` / `email` default to a value UNIQUE per process run: the
    /// dev server bootstraps a real `AdminUser` from these on first app
    /// creation (admin-api.ts `createApp`), so a fixed identity would collide
    /// with a stale record left by an earlier run (surfacing as a spurious
    /// "Admin not found"). A fresh identity each run always bootstraps clean.
    static func mintSuperAdminJwt(
        adminId: String = "test-swift-admin-\(UUID().uuidString.prefix(8))",
        email: String = "swift-tests-\(UUID().uuidString.prefix(8))@example.com",
        name: String = "Swift Test Admin",
        ttlSeconds: Int = 3600
    ) -> String? {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let payload: [String: Any] = [
            "adminId": adminId,
            "email": email,
            "name": name,
            "role": "super-admin",
            "isSuperAdmin": true,
            "appCreationLimit": 50,
            "type": "admin",
            "enableTestFeatures": true,
            "iat": now,
            "exp": now + ttlSeconds,
        ]
        guard
            let headerData = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
            let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else {
            return nil
        }
        let signingInput = base64url(headerData) + "." + base64url(payloadData)
        let key = SymmetricKey(data: Data(jwtSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(signingInput.utf8), using: key
        )
        return signingInput + "." + base64url(Data(mac))
    }

    /// Base64URL encoding (no padding) as used in JWT segments.
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
