import Foundation
import CryptoKit

/// Configuration for integration tests against a live dev server.
///
/// Environment variables:
///   - TEST_HTTP_URL: HTTP endpoint (default http://localhost:8787)
///   - TEST_WS_URL: WebSocket endpoint (default ws://localhost:8787)
///   - TEST_SUPERADMIN_JWT: Optional pre-minted super-admin JWT.
///   - TEST_SUPERADMIN_EMAIL: Optional email of an existing admin; the suite
///     signs an email-only token for it.
///   - TEST_JWT_SECRET: HS256 secret the dev server validates against
///     (default `test-jwt-secret-only-for-agents`, matching `.dev.vars`
///     `JWT_SECRET`).
///   - TEST_GLOBAL_ADMIN_APP_ID: Global admin app ID (default global-admin-app)
///   - TEST_ADMIN_TOKEN: the local test routes' `X-Test-Auth` secret
///     (default `local-test-secret`).
///
/// With neither super-admin variable set, the suite provisions its own admin
/// through the local server's test-only route (see `superAdminJwt()`).
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

    /// The route a local dev server provisions a harness admin through (#3885).
    static let ensureSuperAdminRoute = "/__test__/admin/ensure-super-admin"

    /// The admin this package's suites provision when no variable names one.
    static let harnessAdminEmail = "swift-client-tests@js-bao-wss.test"

    /// Effective super-admin JWT used to provision test apps/users, resolved
    /// once per test process (see `resolveSuperAdminJwt(environment:)`).
    static func superAdminJwt() async throws -> String {
        try await superAdminJwtTask.value
    }

    private static let superAdminJwtTask = Task<String, Error> {
        try await resolveSuperAdminJwt(environment: ProcessInfo.processInfo.environment)
    }

    /// The suite's super-admin token, in order:
    ///
    ///   1. `TEST_SUPERADMIN_JWT`, when set and non-empty;
    ///   2. `TEST_SUPERADMIN_EMAIL`, when set: an email-only token, which the
    ///      server resolves to that admin's row by email;
    ///   3. otherwise the local server's test-only `ensureSuperAdminRoute`
    ///      finds or creates the `harnessAdminEmail` super-admin, and the token
    ///      names that row.
    ///
    /// The server refuses a token whose `adminId` has no row (#3885), so the
    /// suite can no longer self-mint an identity out of thin air. A failure of
    /// the third branch fails setup, naming the route and both variables.
    static func resolveSuperAdminJwt(
        environment: [String: String],
        testAdminToken: String? = nil
    ) async throws -> String {
        if let jwt = environment["TEST_SUPERADMIN_JWT"], !jwt.isEmpty {
            return jwt
        }
        if let email = environment["TEST_SUPERADMIN_EMAIL"], !email.isEmpty {
            guard let jwt = mintSuperAdminJwt(adminId: nil, email: email) else {
                throw TestSetupError("Could not sign an email-only token for TEST_SUPERADMIN_EMAIL=\(email)")
            }
            return jwt
        }
        let admin: ProvisionedAdmin
        do {
            admin = try await provisionSuperAdmin(
                email: harnessAdminEmail,
                testAdminToken: testAdminToken ?? self.testAdminToken
            )
        } catch {
            throw TestSetupError(
                "No super-admin for the Swift suites: POST \(ensureSuperAdminRoute) on \(httpUrl) "
                + "failed (\(error)). Run against a local dev server (USE_TEST_ROUTES=true, "
                + "ENVIRONMENT local or test) with TEST_ADMIN_TOKEN matching its test token, "
                + "or set TEST_SUPERADMIN_JWT to a super-admin token, or TEST_SUPERADMIN_EMAIL "
                + "to an existing admin's email."
            )
        }
        guard let jwt = mintSuperAdminJwt(adminId: admin.adminId, email: admin.email) else {
            throw TestSetupError("Could not sign a token for provisioned admin \(admin.adminId)")
        }
        return jwt
    }

    struct ProvisionedAdmin: Sendable {
        let adminId: String
        let email: String
    }

    /// Find or create a super-admin row for `email` on the local server
    /// (`POST ensureSuperAdminRoute`, `X-Test-Auth`).
    static func provisionSuperAdmin(
        email: String,
        testAdminToken: String
    ) async throws -> ProvisionedAdmin {
        guard let url = URL(string: "\(httpUrl)\(ensureSuperAdminRoute)") else {
            throw TestSetupError("bad TEST_HTTP_URL \(httpUrl)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(testAdminToken, forHTTPHeaderField: "X-Test-Auth")
        request.setValue(globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["email": email, "name": "Swift Test Admin"]
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw TestSetupError(
                "HTTP \(status): \(String(data: data, encoding: .utf8) ?? "")"
            )
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let adminId = json["adminId"] as? String,
            let adminEmail = json["email"] as? String
        else {
            throw TestSetupError(
                "\(ensureSuperAdminRoute) returned no adminId: \(String(data: data, encoding: .utf8) ?? "")"
            )
        }
        return ProvisionedAdmin(adminId: adminId, email: adminEmail)
    }

    static let globalAdminAppId: String = {
        ProcessInfo.processInfo.environment["TEST_GLOBAL_ADMIN_APP_ID"] ?? "global-admin-app"
    }()

    /// The shared secret the dev server's local-only `/__test__/…` routes
    /// take in `X-Test-Auth` (#3436, phase B).
    ///
    /// Those routes are how a suite makes a real room do in seconds what it
    /// would otherwise take a real workload minutes to provoke: seal an epoch,
    /// run the builder's alarm, read the snapshot ledger. They exist only on a
    /// local server, and the token never leaves the test target.
    static let testAdminToken: String = {
        ProcessInfo.processInfo.environment["TEST_ADMIN_TOKEN"] ?? "local-test-secret"
    }()

    static let timeouts = (
        websocketConnect: TimeInterval(5),
        websocketSync: TimeInterval(10),
        httpRequest: TimeInterval(30),
        testDefault: TimeInterval(30)
    )

    // MARK: - Super-admin JWT

    /// Sign an HS256 super-admin JWT with `jwtSecret`. Mirrors the payload the
    /// JS tests use (`{adminId, email, name, role:"super-admin",
    /// isSuperAdmin:true, appCreationLimit:50, type:"admin",
    /// enableTestFeatures:true}`) plus standard `iat`/`exp` claims.
    ///
    /// `adminId` must name an existing admin row (the server refuses any
    /// other, #3885). With `adminId` nil the token is email-only, and the
    /// server resolves the admin by `email`.
    static func mintSuperAdminJwt(
        adminId: String?,
        email: String,
        name: String = "Swift Test Admin",
        ttlSeconds: Int = 3600
    ) -> String? {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        var payload: [String: Any] = [
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
        if let adminId { payload["adminId"] = adminId }
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
