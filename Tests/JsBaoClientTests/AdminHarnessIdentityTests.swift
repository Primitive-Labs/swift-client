import Foundation
import XCTest

/// #3885 behavior 27 — the Swift suites authenticate as a REAL admin row.
///
/// The dev server no longer trusts an admin token whose `adminId` names no
/// row (the "virtual admin" these suites used to self-mint). `TestConfig`
/// resolves the suite's super-admin in order:
///
///   1. `TEST_SUPERADMIN_JWT`, when set;
///   2. `TEST_SUPERADMIN_EMAIL`, when set: an email-only token for that admin;
///   3. otherwise the local-only `POST /__test__/admin/ensure-super-admin`
///      route, which finds or creates the fixed harness admin, and a token for
///      that row.
///
/// The third branch is what the trusted `swift-client-tests` command and the
/// nightly exercise, with no variable set.
final class AdminHarnessIdentityTests: XCTestCase {

    private func meStatus(_ jwt: String) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "\(TestConfig.httpUrl)/admin/api/me")!)
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue(TestConfig.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (status, body)
    }

    private func claims(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private func uniqueEmail(_ label: String) -> String {
        "swift-\(label)-\(UUID().uuidString.prefix(8).lowercased())@js-bao-wss.test"
    }

    func testProvisioningIsIdempotentAndItsRowAuthenticates() async throws {
        let email = uniqueEmail("provision")
        let first = try await TestConfig.provisionSuperAdmin(
            email: email, testAdminToken: TestConfig.testAdminToken
        )
        let second = try await TestConfig.provisionSuperAdmin(
            email: email, testAdminToken: TestConfig.testAdminToken
        )
        XCTAssertEqual(first.adminId, second.adminId)

        let jwt = try XCTUnwrap(
            TestConfig.mintSuperAdminJwt(adminId: first.adminId, email: first.email)
        )
        let (status, body) = try await meStatus(jwt)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["adminId"] as? String, first.adminId)
    }

    func testNoVariableProvisionsTheHarnessAdmin() async throws {
        let jwt = try await TestConfig.resolveSuperAdminJwt(environment: [:])
        XCTAssertNotNil(claims(jwt)["adminId"] as? String)
        let (status, body) = try await meStatus(jwt)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["email"] as? String, TestConfig.harnessAdminEmail)
    }

    func testEmailVariableSignsAnEmailOnlyTokenForThatAdmin() async throws {
        let row = try await TestConfig.provisionSuperAdmin(
            email: uniqueEmail("email"), testAdminToken: TestConfig.testAdminToken
        )
        let jwt = try await TestConfig.resolveSuperAdminJwt(
            environment: ["TEST_SUPERADMIN_EMAIL": row.email]
        )
        XCTAssertNil(claims(jwt)["adminId"])
        XCTAssertEqual(claims(jwt)["email"] as? String, row.email)
        let (status, body) = try await meStatus(jwt)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["adminId"] as? String, row.adminId)
    }

    func testJwtVariableWinsOverEverythingElse() async throws {
        let jwt = try await TestConfig.resolveSuperAdminJwt(
            environment: [
                "TEST_SUPERADMIN_JWT": "a.b.c",
                "TEST_SUPERADMIN_EMAIL": "ignored@js-bao-wss.test",
            ]
        )
        XCTAssertEqual(jwt, "a.b.c")
    }

    func testRefusedProvisioningFailsSetupNamingTheRouteAndBothVariables() async {
        do {
            _ = try await TestConfig.resolveSuperAdminJwt(
                environment: [:], testAdminToken: "not-the-test-admin-token"
            )
            XCTFail("provisioning with a wrong X-Test-Auth must fail setup")
        } catch {
            let message = "\(error)"
            XCTAssertTrue(message.contains("/__test__/admin/ensure-super-admin"), message)
            XCTAssertTrue(message.contains("TEST_SUPERADMIN_JWT"), message)
            XCTAssertTrue(message.contains("TEST_SUPERADMIN_EMAIL"), message)
            XCTAssertTrue(message.contains("401"), message)
        }
    }
}
