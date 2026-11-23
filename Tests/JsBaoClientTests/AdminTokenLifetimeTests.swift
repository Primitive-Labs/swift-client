import Foundation
import XCTest

/// #5474 — a suite run longer than the admin token's lifetime keeps
/// authenticating.
///
/// The whole `swift-client-tests` run takes most of an hour, and the harness
/// admin token lasts an hour. `TestConfig.superAdminJwt()` resolves the
/// harness admin once per process but signs a token each time one is asked
/// for, so a `TestContext` set up late in the run still gets a valid token.
final class AdminTokenLifetimeTests: XCTestCase {

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

    private func meStatus(_ jwt: String) async throws -> Int {
        var request = URLRequest(url: URL(string: "\(TestConfig.httpUrl)/admin/api/me")!)
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue(TestConfig.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    func testEachRequestForTheAdminTokenSignsOneAtThatTime() async throws {
        if let fixed = ProcessInfo.processInfo.environment["TEST_SUPERADMIN_JWT"], !fixed.isEmpty {
            throw XCTSkip("TEST_SUPERADMIN_JWT is a fixed token; the suite cannot re-sign it")
        }
        let first = try await TestConfig.superAdminJwt()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let asked = Int(Date().timeIntervalSince1970)
        let second = try await TestConfig.superAdminJwt()

        let firstIssued = try XCTUnwrap(claims(first)["iat"] as? Int)
        let secondIssued = try XCTUnwrap(claims(second)["iat"] as? Int)
        let secondExpires = try XCTUnwrap(claims(second)["exp"] as? Int)
        XCTAssertGreaterThan(secondIssued, firstIssued, "the second token is the first one, cached")
        XCTAssertGreaterThanOrEqual(secondIssued, asked)
        XCTAssertGreaterThanOrEqual(secondExpires - asked, 3000)
        XCTAssertEqual(claims(second)["adminId"] as? String, claims(first)["adminId"] as? String)

        let status = try await meStatus(second)
        XCTAssertEqual(status, 200)
    }
}
