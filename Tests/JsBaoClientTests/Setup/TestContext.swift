import Foundation
@testable import JsBaoClient

struct TestApp {
    let appId: String
    let name: String
    let ownerUserId: String
    let ownerJWT: String
}

struct TestUser {
    let userId: String
    let email: String
    let name: String
    let role: String
    let jwt: String
}

/// Manages test lifecycle: creates apps, users, documents via the server's admin API.
///
/// Requires TEST_SUPERADMIN_JWT environment variable to be set with a valid super-admin
/// JWT. Get one by running the JS tests first (which set up the superuser in DynamoDB),
/// then mint a JWT via the admin API.
///
/// `@unchecked Sendable`: the harness is shared by concurrent tasks in several
/// tests (a `TaskGroup` creating documents in parallel, for instance). Its three
/// mutable slots are the only shared state and each one lives in a `LockedBox`,
/// so every read and write of them is serialised. `URLSession` is `Sendable`
/// already.
final class TestContext: @unchecked Sendable {
    private let createdAppsBox = LockedBox([String]())
    private let session: URLSession
    private let superuserJWTBox = LockedBox("")
    private let superuserEmailBox = LockedBox("")

    private var createdApps: [String] {
        get { createdAppsBox.value }
        set { createdAppsBox.value = newValue }
    }
    private var superuserJWT: String {
        get { superuserJWTBox.value }
        set { superuserJWTBox.value = newValue }
    }
    private var superuserEmail: String {
        get { superuserEmailBox.value }
        set { superuserEmailBox.value = newValue }
    }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = TestConfig.timeouts.httpRequest
        self.session = URLSession(configuration: config)
    }

    // MARK: - Initialization

    func initialize() async throws {
        // Get super-admin JWT from environment
        guard let jwt = TestConfig.superAdminJwt, !jwt.isEmpty else {
            throw TestSetupError(
                "TEST_SUPERADMIN_JWT environment variable is required. "
                + "Set it to a valid super-admin JWT for the dev server."
            )
        }
        self.superuserJWT = jwt

        // Extract the admin email from the JWT payload so we can use it as initialAdminEmail
        self.superuserEmail = Self.extractEmailFromJWT(jwt) ?? ""

        // Preflight: verify server is reachable and JWT is valid
        do {
            let meResult = try await adminGet("/admin/api/me")
            // If we didn't get the email from the JWT, try from /me response
            if superuserEmail.isEmpty {
                superuserEmail = meResult["email"] as? String
                    ?? (meResult["admin"] as? [String: Any])?["email"] as? String
                    ?? ""
            }
        } catch {
            // Try root to check if server is up at all
            let rootUrl = URL(string: TestConfig.httpUrl)!
            do {
                let (_, response) = try await session.data(for: URLRequest(url: rootUrl))
                if let http = response as? HTTPURLResponse, http.statusCode > 0 {
                    // Server is up but admin auth failed
                    throw TestSetupError(
                        "Server is reachable but admin auth failed. "
                        + "Check your TEST_SUPERADMIN_JWT. Original error: \(error)"
                    )
                }
            } catch let rootError where !(rootError is TestSetupError) {
                throw TestSetupError(
                    "Dev server is not reachable at \(TestConfig.httpUrl). "
                    + "Start it with: node debug-server.js"
                )
            }
        }

        guard !superuserEmail.isEmpty else {
            throw TestSetupError(
                "Could not determine super-admin email from JWT or /admin/api/me. "
                + "Ensure your TEST_SUPERADMIN_JWT is valid."
            )
        }
    }

    /// Decode the payload of a JWT (without verifying the signature) and extract the "email" claim.
    private static func extractEmailFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
        // Pad to multiple of 4 for base64 decoding
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String else {
            return nil
        }
        return email
    }

    // MARK: - App Management

    func createTestApp(name: String) async throws -> TestApp {
        let uniqueName = "\(name)-\(UUID().uuidString.prefix(8))"

        // Create app via admin API.
        // Use the super-admin's own email as initialAdminEmail — the admin API
        // requires this to reference an existing admin user. The super-admin
        // becomes the app owner automatically.
        let appResult = try await adminPost("/admin/api/apps", body: [
            "name": uniqueName,
            "mode": "public",
            "initialAdminEmail": superuserEmail,
            "description": "Swift integration test app",
        ])

        guard let appId = appResult["appId"] as? String else {
            throw TestSetupError("Failed to create app: missing appId in response \(appResult)")
        }

        createdAppsBox.withValue { $0.append(appId) }

        // The create-app response includes "createdBy" which is the userId of
        // the owner that was auto-created for the initialAdminEmail.
        guard let ownerUserId = appResult["createdBy"] as? String else {
            throw TestSetupError("Failed to create app: missing createdBy in response \(appResult)")
        }

        // Mint a test JWT for the owner
        let ownerJWT = try await mintTestJwt(appId: appId, userId: ownerUserId, role: "owner")

        return TestApp(
            appId: appId,
            name: uniqueName,
            ownerUserId: ownerUserId,
            ownerJWT: ownerJWT
        )
    }

    func createTestUser(appId: String, role: String = "member", email: String? = nil, name: String? = nil) async throws -> TestUser {
        let userEmail = email ?? "swift-user-\(UUID().uuidString.prefix(8))@test.local"
        let userName = name ?? "Swift Test User"

        // Add user to app via admin API
        let addResult = try await adminPost(
            "/admin/api/apps/\(appId)/users/add-by-email",
            body: ["email": userEmail, "role": role]
        )

        guard let userId = addResult["userId"] as? String
                ?? (addResult["user"] as? [String: Any])?["userId"] as? String else {
            throw TestSetupError("Failed to add user: missing userId in response \(addResult)")
        }

        // Mint test JWT
        let jwt = try await mintTestJwt(appId: appId, userId: userId, role: role)

        return TestUser(userId: userId, email: userEmail, name: userName, role: role, jwt: jwt)
    }

    /// Update app settings via `PUT /app/{appId}/api/settings` (owner JWT).
    /// Used by the passkey tests to flip `passkeyEnabled` / RP config the
    /// same way the JS suite does (tests/api/http/app-passkeys.test.ts).
    func updateAppSettings(appId: String, updates: [String: Any], jwt: String) async throws {
        _ = try await appRequest(method: "PUT", appId: appId, path: "/settings", body: updates, jwt: jwt)
    }

    // MARK: - Document Operations

    func createDocument(appId: String, jwt: String, title: String? = nil) async throws -> String {
        let body: [String: Any] = ["title": title ?? "Swift Test Doc \(UUID().uuidString.prefix(8))"]

        let result = try await appPost(appId: appId, path: "/documents", body: body, jwt: jwt)

        guard let documentId = result["documentId"] as? String
                ?? (result["data"] as? [String: Any])?["documentId"] as? String else {
            throw TestSetupError("Failed to create document: missing documentId in response \(result)")
        }
        return documentId
    }

    func grantPermission(appId: String, documentId: String, userId: String, permission: String, jwt: String) async throws {
        _ = try await appRequest(
            method: "PUT",
            appId: appId,
            path: "/documents/\(documentId)/permissions",
            body: ["userId": userId, "permission": permission],
            jwt: jwt
        )
    }

    // MARK: - Workflow Operations
    //
    // Thin helpers over the admin workflow CRUD used by the workflow
    // integration tests (start / runSync / the apply flow). Mirrors the JS
    // test helpers in sample-app/src/pages/Tests.tsx.

    /// Create a workflow (the create writes the active configuration from
    /// `steps` under the workflow-config model) and activate it.
    /// Returns the workflowId. `requiresClientApply` defaults to true so
    /// the run parks in `apply_pending` until a client claims and applies.
    /// `syncCallable` opts the workflow into `runSync` (mirrors the JS
    /// `createSyncWorkflow` helper in
    /// tests/client/js-bao-client-workflow-runSync.test.ts — which, like
    /// this helper, does not go near the legacy publish endpoint: it was
    /// retired in #2768, and activation is the workflow's active
    /// configuration).
    @discardableResult
    func setupWorkflow(
        appId: String,
        workflowKey: String,
        steps: [[String: Any]],
        requiresClientApply: Bool = true,
        syncCallable: Bool = false
    ) async throws -> String {
        let createRes = try await adminPost(
            "/admin/api/apps/\(appId)/workflows",
            body: [
                "workflowKey": workflowKey,
                "name": workflowKey,
                "description": "Swift test workflow",
                // #2652: caller workflows must state who may start them.
                "accessRule": "true",
                "steps": steps,
                "syncCallable": syncCallable,
            ]
        )
        guard let workflow = createRes["workflow"] as? [String: Any],
              let workflowId = workflow["workflowId"] as? String else {
            throw TestSetupError("Failed to create workflow: \(createRes)")
        }

        // No status here: it is server-owned (#2803) and creation already
        // yields an active workflow — the endpoint rejects a status key.
        _ = try await adminRequest(
            method: "PATCH",
            path: "/admin/api/apps/\(appId)/workflows/\(workflowId)",
            body: [
                "requiresClientApply": requiresClientApply,
            ]
        )

        return workflowId
    }

    // MARK: - App settings

    /// PATCH-style update of app-level settings via the admin API
    /// (`PUT /admin/api/apps/{appId}` — e.g. `otpEnabled`,
    /// `magicLinkEnabled`). Mirrors the JS tests' `adminHttpClient().put`.
    func updateAppSettings(appId: String, settings: [String: Any]) async throws {
        _ = try await adminRequest(
            method: "PUT",
            path: "/admin/api/apps/\(appId)",
            body: settings
        )
    }

    // MARK: - Cleanup

    func cleanup() async {
        for appId in createdApps {
            _ = try? await adminRequest(method: "DELETE", path: "/admin/api/apps/\(appId)", body: nil)
        }
        createdAppsBox.withValue { $0.removeAll() }
    }

    // MARK: - Private HTTP Helpers

    private func mintTestJwt(appId: String, userId: String, role: String) async throws -> String {
        let result = try await adminPost(
            "/admin/api/apps/\(appId)/users/\(userId)/mint-test-jwt",
            body: ["role": role]
        )
        guard let token = result["token"] as? String else {
            throw TestSetupError("Failed to mint JWT: missing token in response \(result)")
        }
        return token
    }

    /// Mint a server-signed refresh token for an existing app user via the
    /// dev-server's `mint-test-jwt` endpoint (test-features-gated, prod-blocked).
    ///
    /// The server signs the refresh token with its own `JWT_SECRET` and records
    /// a `Session`, exactly as a real login does — so the cold-start
    /// refresh-cookie test no longer forges a token against a guessed secret
    /// (`TestConfig.jwtSecret`). That forge approach broke whenever the test's
    /// secret didn't match the server's (the /auth/refresh call then 401s), which
    /// is exactly what the nightly hit. See `docs/feedback/swift-client.md`
    /// entry 2026-04-21 for the original ask.
    func mintRefreshToken(appId: String, userId: String) async throws -> String {
        let result = try await adminPost(
            "/admin/api/apps/\(appId)/users/\(userId)/mint-test-jwt",
            body: ["includeRefreshToken": true]
        )
        guard let refreshToken = result["refreshToken"] as? String else {
            throw TestSetupError(
                "Failed to mint refresh token: missing refreshToken in response \(result)"
            )
        }
        return refreshToken
    }

    @discardableResult
    private func adminGet(_ path: String) async throws -> [String: Any] {
        try await adminRequest(method: "GET", path: path, body: nil)
    }

    /// Update writable app fields via `PUT /admin/api/apps/{appId}` (e.g.
    /// `googleClients` — the per-platform client map — for the OAuth flow
    /// tests, or `emailRedirectUris` for magic link). Returns the canonical
    /// admin-API app shape. The retired scalars (`googleClientId`,
    /// `googleClientSecret`, `redirectUris`) are rejected by the server (#2891).
    @discardableResult
    func updateTestApp(appId: String, fields: [String: Any]) async throws -> [String: Any] {
        try await adminRequest(method: "PUT", path: "/admin/api/apps/\(appId)", body: fields)
    }

    @discardableResult
    private func adminPost(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        try await adminRequest(method: "POST", path: path, body: body)
    }

    @discardableResult
    private func adminRequest(method: String, path: String, body: [String: Any]?) async throws -> [String: Any] {
        let url = URL(string: "\(TestConfig.httpUrl)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(superuserJWT)", forHTTPHeaderField: "Authorization")
        request.setValue(TestConfig.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")

        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TestSetupError("Non-HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw TestSetupError("HTTP \(httpResponse.statusCode) \(method) \(path): \(text)")
        }

        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @discardableResult
    private func appPost(appId: String, path: String, body: [String: Any], jwt: String) async throws -> [String: Any] {
        try await appRequest(method: "POST", appId: appId, path: path, body: body, jwt: jwt)
    }

    /// Raw app-API request as a given user. Internal (not private) so tests can
    /// exercise endpoints the Swift client does not expose yet — e.g. the
    /// metadata-category configs and metadata read/write routes (#1451).
    @discardableResult
    func appRequest(method: String, appId: String, path: String, body: [String: Any]?, jwt: String) async throws -> [String: Any] {
        let url = URL(string: "\(TestConfig.httpUrl)/app/\(appId)/api\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue(TestConfig.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")

        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TestSetupError("Non-HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw TestSetupError("HTTP \(httpResponse.statusCode) \(method) /app/\(appId)/api\(path): \(text)")
        }

        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

// MARK: - Error Type

struct TestSetupError: LocalizedError, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
    var description: String { message }
}
