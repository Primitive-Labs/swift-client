import XCTest
@testable import JsBaoClient

/// Regression tests for #2366: a network outage that happens while the client
/// is refreshing its access token must not be reported as a credential
/// failure.
///
/// The bug: `HttpClient.fetchWithRefresh` turned a `.network` refresh outcome
/// into `HttpError(status: 401, message: "Refresh deferred due to network
/// failure")`. `BlobManager.shouldQueueError` treats a 401 as a permanent
/// rejection, so a transient outage during an upload evicted the retained
/// bytes and emitted a terminal `willRetry: false` — the upload was lost
/// instead of being requeued.
///
/// The whole cycle (401 on the upload → refresh → transport failure) runs
/// offline through a `URLProtocol` stub injected into the client's session
/// configuration, so these tests need no dev server. The stub
/// (`RefreshStubURLProtocol`) and the client wiring (`makeWiredClients`) are
/// shared with the other refresh suites and live in
/// `Helpers/RefreshTestSupport.swift`.
final class BlobRefreshOutageTests: XCTestCase {

    override func tearDown() {
        RefreshStubURLProtocol.reset()
        super.tearDown()
    }

    /// A 401 whose refresh fails at the transport must not surface as a
    /// credential failure, and the retry classifier must see it as retryable.
    func testRefreshTransportFailureIsNotReportedAsACredential401() async throws {
        RefreshStubURLProtocol.configure(refreshFailsAtTransport: true)
        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1-stale"))

        do {
            _ = try await http.request(method: "GET", path: "/me")
            XCTFail("the request must fail when the refresh cannot reach the server")
        } catch {
            XCTAssertNotEqual(
                (error as? HttpError)?.status, 401,
                """
                a transport outage during refresh must not be classified as a \
                credential failure — got \(error)
                """)
            XCTAssertTrue(
                BlobManager.shouldQueueError(error),
                "a refresh-time outage must be retryable, got \(error)")
            // Pins the representation #2367 / PR #2549 settled on: a
            // refresh-time transport failure surfaces as the public, retryable
            // `JsBaoNetworkError` — never as an `HttpError` with a status a
            // sign-out path could match. The two assertions above are the
            // contract and must keep holding either way.
            XCTAssertTrue(
                error is JsBaoNetworkError,
                "the failure must surface as the retryable JsBaoNetworkError, got \(error)")
        }
    }

    /// Guard rail: a refresh that the server *rejects* (401) is still an
    /// invalid-credentials failure — unchanged by this fix.
    func testRejectedRefreshStillSurfacesInvalidCredentials() async throws {
        RefreshStubURLProtocol.configure(refreshFailsAtTransport: false)
        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1-stale"))

        do {
            _ = try await http.request(method: "GET", path: "/me")
            XCTFail("the request must fail when the refresh is rejected")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 401, "a rejected refresh stays an HTTP 401")
            XCTAssertEqual(error.message, "Invalid credentials")
            XCTAssertFalse(
                BlobManager.shouldQueueError(error),
                "an invalid credential is still a permanent rejection")
        } catch {
            XCTFail("Expected HttpError(401), got: \(error)")
        }
    }

    /// The reported data loss, end to end: an upload whose 401 refresh hits a
    /// transport outage must be requeued with its bytes retained, not dropped
    /// with a terminal `willRetry: false`.
    func testRefreshOutageRequeuesTheUploadInsteadOfDiscardingTheBytes() async throws {
        RefreshStubURLProtocol.configure(refreshFailsAtTransport: true)
        let (_, http) = makeWiredClients(initialToken: makeTestJwt(userId: "u1-stale"))

        let emitter = EventEmitter()
        let events = LockedBox([BlobUploadFailedEvent]())
        let subscription = emitter.subscribe(BlobUploadFailedEvent.self) { event in
            events.withValue { $0.append(event) }
        }
        defer { subscription.cancel() }

        // A long backoff keeps the single first attempt the only one, so the
        // assertions below read the state the failure left behind.
        let manager = BlobManager(
            logger: Logger(level: .error, scope: "test"),
            uploadConcurrency: 2,
            backoffBaseMs: 100_000,
            backoffMaxMs: 100_000,
            transport: http,
            emit: { @Sendable payload in emitter.emitErased(payload) }
        )

        _ = try? await manager.uploadFromSource(
            documentId: "doc", source: Data("payload".utf8))

        let uploads = await manager.listUploads()
        XCTAssertEqual(
            uploads.count, 1,
            "a refresh-time outage must leave the upload queued for retry")

        let recorded = events.value
        XCTAssertEqual(recorded.count, 1, "exactly one failure event for the one attempt")
        XCTAssertEqual(
            recorded.first?.willRetry, true,
            "a transient outage must report willRetry: true, not a terminal failure")

        let blobId = recorded.first?.blobId ?? ""
        let retained = await manager.hasCachedBytes(documentId: "doc", blobId: blobId)
        XCTAssertTrue(
            retained,
            "the retained bytes must survive so the queued retry has something to send")
    }
}
