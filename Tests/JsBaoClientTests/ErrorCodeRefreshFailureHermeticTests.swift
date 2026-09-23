import XCTest
@testable import JsBaoClient

/// The server's `code` survives the terminal refresh failure (#3403).
///
/// `HttpClient` answers a refused refresh with `HttpError(status: 401,
/// message: "Invalid credentials")` — constructed from nothing, so the
/// original 401's body and `code` were thrown away. An app that localizes by
/// cause saw `serverCode == nil` for the single most common auth failure
/// there is, whatever the server sent.
///
/// The message text stays `"Invalid credentials"`: `HttpClientTransportTests`
/// and `BlobRefreshOutageTests` pin it, and a caller matching on it must keep
/// working. Only `body` and `serverCode` are added.
final class ErrorCodeRefreshFailureHermeticTests: XCTestCase {

    override func tearDown() {
        RefreshStubURLProtocol.reset()
        super.tearDown()
    }

    func testTerminalRefreshFailureCarriesTheOriginal401Code() async throws {
        RefreshStubURLProtocol.configure(refreshFailsAtTransport: false)
        RefreshStubURLProtocol.configure(unauthorizedBody: [
            "error": "Invalid token",
            "code": "INVALID_TOKEN",
            "status": "401",
            "timestamp": "2026-09-13T00:00:00.000Z",
        ])

        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1-stale"))

        do {
            _ = try await http.request(method: "GET", path: "/me")
            XCTFail("a refused refresh must surface the 401 to the caller")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 401)
            XCTAssertEqual(
                error.message, "Invalid credentials",
                "the message existing callers match on is unchanged"
            )
            XCTAssertEqual(
                error.serverCode, "INVALID_TOKEN",
                "the original 401's machine-readable cause must reach the app"
            )
            XCTAssertNotNil(error.body, "the original 401 body is attached, not discarded")
            XCTAssertEqual(error.serverMessage, "Invalid token")
        }
    }

    func testTerminalRefreshFailureLeavesCodeNilForAnUncodedBody() async throws {
        // An older server, or a non-platform intermediary: no code to carry.
        RefreshStubURLProtocol.configure(refreshFailsAtTransport: false)
        RefreshStubURLProtocol.configure(unauthorizedBody: ["error": "unauthorized"])

        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1-stale"))

        do {
            _ = try await http.request(method: "GET", path: "/me")
            XCTFail("a refused refresh must surface the 401 to the caller")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 401)
            XCTAssertEqual(error.message, "Invalid credentials")
            XCTAssertNil(error.serverCode)
        }
    }
}
