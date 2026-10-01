import XCTest
@testable import JsBaoClient

/// Server-free parity pins for the JS client's `makeRequest` gate: an HTTP
/// call made while networking is not allowed throws `JsBaoError` code
/// `OFFLINE` before any fetch (`offlineRequestError`), whether the app pinned
/// `.offline` or the network is unreachable in `.auto` (#4025).
///
/// The client points at port 1, where nothing listens: a request that is
/// actually attempted fails in transit as `JsBaoNetworkError`. So `.offline`
/// coming back means the gate answered before the request went out, and
/// `JsBaoNetworkError` means it was attempted.
final class OfflineRequestGateHermeticTests: XCTestCase {

    private func makeClient(monitor: FakeConnectivityMonitor? = nil) -> JsBaoClient {
        JsBaoClient(
            options: JsBaoClientOptions(
                apiUrl: "http://127.0.0.1:1",
                wsUrl: "ws://127.0.0.1:1",
                appId: "test-app",
                token: nil,
                logLevel: .error,
                storageConfig: .memory,
                autoNetwork: monitor != nil
            ),
            connectivityMonitor: monitor
        )
    }

    /// Run `body` and return the `JsBaoError` it threw, failing on anything else.
    private func offlineError(
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> JsBaoError? {
        do {
            try await body()
            XCTFail("expected the call to throw", file: file, line: line)
            return nil
        } catch let error as JsBaoError {
            return error
        } catch {
            XCTFail("expected JsBaoError(.offline), got \(type(of: error)): \(error)", file: file, line: line)
            return nil
        }
    }

    func testPinnedOfflineDocumentsGetThrowsOfflineWithoutAttempting() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }
        client.setNetworkMode(.offline)

        let error = await offlineError {
            _ = try await client.documents.get(documentId: "doc-1")
        }
        XCTAssertEqual(error?.code, .offline)
        XCTAssertEqual(error?.details?["method"], .string("GET"))
        XCTAssertEqual(error?.details?["path"], .string("/documents/doc-1"))
    }

    func testPinnedOfflineClientRequestHelpersThrowOffline() async throws {
        let client = makeClient()
        defer { Task { await client.destroy() } }
        client.setNetworkMode(.offline)

        let json = await offlineError {
            _ = try await client.requestJSON(method: .get, path: "/me")
        }
        XCTAssertEqual(json?.code, .offline)

        let bytes = await offlineError {
            _ = try await client.requestData(method: .post, path: "/blobs", body: Data([1, 2, 3]))
        }
        XCTAssertEqual(bytes?.code, .offline)
        XCTAssertEqual(bytes?.details?["method"], .string("POST"))
    }

    func testUnreachableAutoThrowsOffline() async throws {
        let monitor = FakeConnectivityMonitor()
        let client = makeClient(monitor: monitor)
        defer { Task { await client.destroy() } }

        try await eventually(timeout: 3, description: "monitor started") {
            monitor.isStarted
        }
        monitor.push(false)
        try await eventually(timeout: 3, description: "gate closed after loss") {
            client.networkingAllowed() == false
        }
        XCTAssertEqual(client.networkMode, .auto)

        let error = await offlineError {
            _ = try await client.documents.get(documentId: "doc-1")
        }
        XCTAssertEqual(error?.code, .offline)
    }

    /// Edge case: with networking allowed the request is attempted, and a
    /// failure in transit is still a `JsBaoNetworkError`, not `.offline`.
    func testAllowedRequestThatFailsInTransitThrowsNetworkError() async throws {
        // `.auto` with monitoring off stays reachable, so networking is
        // allowed. (Pinning `.online` would start a token-less auth handoff
        // that can revert the mode to `.offline` mid-test.)
        let client = makeClient()
        defer { Task { await client.destroy() } }
        XCTAssertEqual(client.networkMode, .auto)
        XCTAssertTrue(client.networkingAllowed())

        do {
            _ = try await client.documents.get(documentId: "doc-1")
            XCTFail("nothing listens on port 1")
        } catch is JsBaoNetworkError {
            // attempted, failed in transit
        } catch {
            XCTFail("expected JsBaoNetworkError, got \(type(of: error)): \(error)")
        }
    }
}
