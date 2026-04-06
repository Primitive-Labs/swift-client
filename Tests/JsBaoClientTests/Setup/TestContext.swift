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
final class TestContext {
    private var createdApps: [String] = []
    private let session: URLSession
    private var superuserJWT: String = ""
    private var superuserEmail: String = ""

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

        createdApps.append(appId)

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

    // MARK: - Cleanup

    func cleanup() async {
        for appId in createdApps {
            _ = try? await adminRequest(method: "DELETE", path: "/admin/api/apps/\(appId)", body: nil)
        }
        createdApps.removeAll()
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

    @discardableResult
    private func adminGet(_ path: String) async throws -> [String: Any] {
        try await adminRequest(method: "GET", path: path, body: nil)
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

    @discardableResult
    private func appRequest(method: String, appId: String, path: String, body: [String: Any]?, jwt: String) async throws -> [String: Any] {
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
