import XCTest
@testable import JsBaoClient

/// Wire-shape, decode, and poll-loop tests for `LocksAPI` (#1574, parity with
/// the JS client's `src/client/api/locksApi.ts` from #1518).
///
/// These instantiate the sub-API with a stub `Transport` that records the
/// `(method, path, body)` triple and returns a canned response, so the
/// blocking-acquire edge cases (its own 429, the deadline clamp) can be driven
/// deterministically without a server. The live behavior lives in
/// `LocksTests.swift`.
final class LocksAPITests: XCTestCase {

    // MARK: - Recorder

    /// Records every request and replays a scripted queue of responses. When
    /// the queue runs dry the last entry repeats, so a poll loop can be given
    /// "contended forever".
    ///
    /// Scripts stay as `Any` JSON graphs (and errors are thrown from `execute`
    /// directly), so the 21 wire-shape assertions below are unchanged from the
    /// closure-spine version of this harness.
    final class CallRecorder: Transport, @unchecked Sendable {
        struct Call {
            let method: String
            let path: String
            let body: Any?
        }

        private let lock = NSLock()
        private var responses: [Result<Any, Error>] = [.success([String: Any]())]
        private var index = 0
        private(set) var calls: [Call] = []

        var last: Call? { lock.withLock { calls.last } }
        var callCount: Int { lock.withLock { calls.count } }

        func script(_ responses: [Result<Any, Error>]) {
            lock.withLock {
                self.responses = responses
                self.index = 0
            }
        }

        func respond(with value: Any) {
            script([.success(value)])
        }

        func execute(
            method: HTTPMethod,
            path: String,
            body: Data?,
            options: RequestOptions?
        ) async throws -> TransportResponse {
            let parsedBody: Any? = body.flatMap {
                try? JSONSerialization.jsonObject(with: $0)
            }
            let next: Result<Any, Error> = lock.withLock {
                calls.append(Call(method: method.rawValue, path: path, body: parsedBody))
                let response = responses[min(index, responses.count - 1)]
                index += 1
                return response
            }
            // Scripted errors (e.g. the acquire 429) are thrown as-is, exactly
            // as the closure spine surfaced them.
            let value = try next.get()
            let data = try JSONSerialization.data(withJSONObject: value)
            return TransportResponse(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: data
            )
        }
    }

    private func api(_ recorder: CallRecorder) -> LocksAPI {
        LocksAPI(transport: recorder)
    }

    private func handleJSON(
        key: String = "k",
        handleId: String = "h1",
        leaseExpiresAt: String = "2026-01-01T00:00:00.000Z"
    ) -> [String: Any] {
        ["key": key, "handleId": handleId, "leaseExpiresAt": leaseExpiresAt]
    }

    private func body(_ recorder: CallRecorder) throws -> [String: Any] {
        let raw = try XCTUnwrap(recorder.last?.body)
        return try XCTUnwrap(raw as? [String: Any], "Request body should be a JSON object")
    }

    // MARK: - Wire shapes (behavior 9)

    func test_tryAcquire_POSTsKeyAndTtlInTheBody() async throws {
        let r = CallRecorder()
        r.respond(with: ["acquired": true, "handle": handleJSON(key: "import:1")])

        let handle = try await api(r).tryAcquire(key: "import:1", ttlMs: 60_000)

        XCTAssertEqual(r.last?.method, "POST")
        XCTAssertEqual(r.last?.path, "/locks/acquire")
        let sent = try body(r)
        XCTAssertEqual(sent["key"] as? String, "import:1")
        XCTAssertEqual(sent["ttlMs"] as? Int, 60_000)
        XCTAssertEqual(handle?.key, "import:1")
        XCTAssertEqual(handle?.handleId, "h1")
    }

    func test_tryAcquire_returnsNilOnContention() async throws {
        let r = CallRecorder()
        r.respond(with: [
            "acquired": false,
            "heldBy": "user_1",
            "holderKind": "user",
            "leaseExpiresAt": "2026-01-01T00:00:00.000Z",
            "retryAfterMs": 500,
        ])

        let handle = try await api(r).tryAcquire(key: "k", ttlMs: 1_000)
        XCTAssertNil(handle)
    }

    func test_release_POSTsKeyAndNestedHandleId() async throws {
        let r = CallRecorder()
        r.respond(with: ["released": true])

        let result = try await api(r).release(
            LockHandle(key: "k", handleId: "h1", leaseExpiresAt: "2026-01-01T00:00:00.000Z")
        )

        XCTAssertEqual(r.last?.method, "POST")
        XCTAssertEqual(r.last?.path, "/locks/release")
        let sent = try body(r)
        XCTAssertEqual(sent["key"] as? String, "k")
        XCTAssertEqual((sent["handle"] as? [String: Any])?["handleId"] as? String, "h1")
        XCTAssertTrue(result.released)
        XCTAssertNil(result.reason)
    }

    func test_release_reportsReasonWithoutThrowing() async throws {
        let r = CallRecorder()
        r.respond(with: ["released": false, "reason": "not_holder"])

        let result = try await api(r).release(
            LockHandle(key: "k", handleId: "stale", leaseExpiresAt: "2026-01-01T00:00:00.000Z")
        )
        XCTAssertFalse(result.released)
        XCTAssertEqual(result.reason, "not_holder")
    }

    func test_renew_POSTsKeyHandleAndTtl() async throws {
        let r = CallRecorder()
        r.respond(with: ["renewed": true, "leaseExpiresAt": "2026-01-02T00:00:00.000Z"])

        let result = try await api(r).renew(
            LockHandle(key: "k", handleId: "h1", leaseExpiresAt: "2026-01-01T00:00:00.000Z"),
            ttlMs: 30_000
        )

        XCTAssertEqual(r.last?.method, "POST")
        XCTAssertEqual(r.last?.path, "/locks/renew")
        let sent = try body(r)
        XCTAssertEqual(sent["key"] as? String, "k")
        XCTAssertEqual((sent["handle"] as? [String: Any])?["handleId"] as? String, "h1")
        XCTAssertEqual(sent["ttlMs"] as? Int, 30_000)
        XCTAssertTrue(result.renewed)
        XCTAssertEqual(result.leaseExpiresAt, "2026-01-02T00:00:00.000Z")
    }

    func test_renew_leaseLost() async throws {
        let r = CallRecorder()
        r.respond(with: ["renewed": false, "reason": "lease_lost"])

        let result = try await api(r).renew(
            LockHandle(key: "k", handleId: "h1", leaseExpiresAt: "2026-01-01T00:00:00.000Z"),
            ttlMs: 30_000
        )
        XCTAssertFalse(result.renewed)
        XCTAssertEqual(result.reason, "lease_lost")
        XCTAssertNil(result.leaseExpiresAt)
    }

    func test_status_POSTsTheKeyInTheBodyNotThePath() async throws {
        let r = CallRecorder()
        r.respond(with: [
            "held": true,
            "heldBy": "user_1",
            "holderKind": "workflow",
            "holderRunId": "run_1",
            "acquiredAt": "2026-01-01T00:00:00.000Z",
            "leaseExpiresAt": "2026-01-01T00:01:00.000Z",
        ])

        // A key with `:` and `/` must never need percent-encoding — it rides in
        // the body, which is why the server put the action in the path.
        let status = try await api(r).status(key: "import:tenant/42")

        XCTAssertEqual(r.last?.method, "POST")
        XCTAssertEqual(r.last?.path, "/locks/status")
        XCTAssertEqual(try body(r)["key"] as? String, "import:tenant/42")
        XCTAssertTrue(status.held)
        XCTAssertEqual(status.holderRunId, "run_1")
    }

    func test_status_free() async throws {
        let r = CallRecorder()
        r.respond(with: ["held": false])

        let status = try await api(r).status(key: "k")
        XCTAssertFalse(status.held)
        XCTAssertNil(status.heldBy)
        XCTAssertNil(status.leaseExpiresAt)
    }

    func test_list_GETsLocks() async throws {
        let r = CallRecorder()
        r.respond(with: [
            "locks": [
                [
                    "key": "a",
                    "heldBy": "user_1",
                    "holderKind": "user",
                    "holderRunId": NSNull(),
                    "acquiredAt": "2026-01-01T00:00:00.000Z",
                    "leaseExpiresAt": "2026-01-01T00:01:00.000Z",
                ]
            ]
        ])

        let result = try await api(r).list()

        XCTAssertEqual(r.last?.method, "GET")
        XCTAssertEqual(r.last?.path, "/locks")
        XCTAssertNil(r.last?.body ?? nil)
        XCTAssertEqual(result.locks.count, 1)
        XCTAssertEqual(result.locks[0].key, "a")
        XCTAssertNil(result.locks[0].holderRunId)
    }

    // MARK: - Decode edge cases

    func test_contentionDecodesWithNullHolderFields() async throws {
        let r = CallRecorder()
        r.respond(with: [
            "acquired": false,
            "heldBy": NSNull(),
            "holderKind": NSNull(),
            "leaseExpiresAt": NSNull(),
            "retryAfterMs": 250,
        ])

        let handle = try await api(r).tryAcquire(key: "k", ttlMs: 1_000)
        XCTAssertNil(handle)
    }

    func test_retryAfterMsDecodesFromANonIntegralNumber() throws {
        // Guards the `Double`-then-round decode: a JSON `250.0` must not hard
        // fail the whole acquire response (see #2056 for the failure mode).
        let json = #"{"acquired":false,"retryAfterMs":250.0}"#
        let decoded = try JSONCoding.decoder.decode(
            LockAcquireResponse.self, from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.retryAfterMs, 250)
        XCTAssertEqual(decoded.contention?.retryAfterMs, 250)
    }

    func test_contentionAccessorDefaultsRetryAfterWhenAbsent() throws {
        let decoded = try JSONCoding.decoder.decode(
            LockAcquireResponse.self, from: Data(#"{"acquired":false}"#.utf8)
        )
        XCTAssertEqual(decoded.contention?.retryAfterMs, LocksAPI.defaultRetryAfterMs)
        let acquired = try JSONCoding.decoder.decode(
            LockAcquireResponse.self,
            from: Data(#"{"acquired":true,"handle":{"key":"k","handleId":"h","leaseExpiresAt":"t"}}"#.utf8)
        )
        XCTAssertNil(acquired.contention)
    }

    // MARK: - Blocking acquire (behaviors 7, 8 + edge cases)

    func test_blockingAcquire_returnsTheHandleOnceTheKeyFrees() async throws {
        let r = CallRecorder()
        r.script([
            .success(["acquired": false, "retryAfterMs": 10]),
            .success(["acquired": false, "retryAfterMs": 10]),
            .success(["acquired": true, "handle": handleJSON()]),
        ])

        let handle = try await api(r).acquire(key: "k", ttlMs: 1_000, timeoutMs: 5_000)
        XCTAssertEqual(handle.handleId, "h1")
        XCTAssertEqual(r.callCount, 3, "It should keep polling until the key frees")
    }

    func test_blockingAcquire_throwsLockTimeoutWithKeyAndTimeoutInDetails() async throws {
        let r = CallRecorder()
        r.respond(with: ["acquired": false, "retryAfterMs": 10])

        do {
            _ = try await api(r).acquire(key: "busy", ttlMs: 1_000, timeoutMs: 120)
            XCTFail("Expected a lock timeout")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .lockTimeout)
            XCTAssertEqual(error.details?["key"], .string("busy"))
            XCTAssertEqual(error.details?["timeoutMs"], .number(120))
            XCTAssertTrue(error.message.contains("busy"))
        }
    }

    func test_blockingAcquire_nonPositiveTimeoutMakesOneAttemptThenTimesOut() async throws {
        let r = CallRecorder()
        r.respond(with: ["acquired": false, "retryAfterMs": 10_000])

        do {
            _ = try await api(r).acquire(key: "k", ttlMs: 1_000, timeoutMs: 0)
            XCTFail("Expected a lock timeout")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .lockTimeout)
        }
        XCTAssertEqual(r.callCount, 1, "A non-positive timeout must not sleep or re-poll")
    }

    func test_blockingAcquire_swallowsItsOwn429AndKeepsPolling() async throws {
        let r = CallRecorder()
        r.script([
            .failure(HttpError(
                status: 429,
                message: "HTTP 429",
                body: #"{"error":"Too many lock acquire attempts.","details":{"retryAfter":0.01}}"#
            )),
            .success(["acquired": true, "handle": handleJSON()]),
        ])

        let handle = try await api(r).acquire(key: "k", ttlMs: 1_000, timeoutMs: 5_000)
        XCTAssertEqual(handle.handleId, "h1")
        XCTAssertEqual(r.callCount, 2)
    }

    func test_blockingAcquire_raisesLockTimeoutNot429WhenEveryPollIsRateLimited() async throws {
        let r = CallRecorder()
        r.script([
            .failure(HttpError(status: 429, message: "HTTP 429", body: #"{"details":{"retryAfter":0.01}}"#))
        ])

        do {
            _ = try await api(r).acquire(key: "k", ttlMs: 1_000, timeoutMs: 120)
            XCTFail("Expected a lock timeout")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .lockTimeout, "A 429 must never surface from a blocking acquire")
        }
    }

    func test_blockingAcquire_propagatesNon429Errors() async throws {
        let r = CallRecorder()
        r.script([.failure(HttpError(status: 403, message: "HTTP 403", body: nil))])

        do {
            _ = try await api(r).acquire(key: "k", ttlMs: 1_000, timeoutMs: 5_000)
            XCTFail("Expected the 403 to propagate")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
        }
    }

    func test_tryAcquire_doesNotSwallowThe429() async throws {
        let r = CallRecorder()
        r.script([.failure(HttpError(status: 429, message: "HTTP 429", body: nil))])

        do {
            _ = try await api(r).tryAcquire(key: "k", ttlMs: 1_000)
            XCTFail("tryAcquire must surface the rate limit to its caller")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 429)
        }
    }

    // MARK: - Rate-limit backoff helper

    func test_rateLimitBackoff_readsRetryAfterAndCapsIt() {
        XCTAssertEqual(
            LocksAPI.rateLimitBackoffMs(
                HttpError(status: 429, message: "", body: #"{"details":{"retryAfter":2}}"#)
            ),
            2_000
        )
        XCTAssertEqual(
            LocksAPI.rateLimitBackoffMs(
                HttpError(status: 429, message: "", body: #"{"retryAfter":3500}"#)
            ),
            LocksAPI.maxRateLimitBackoffMs,
            "A fully-exhausted hourly bucket must not park the poll loop"
        )
        XCTAssertEqual(
            LocksAPI.rateLimitBackoffMs(HttpError(status: 429, message: "", body: "not json")),
            LocksAPI.defaultRetryAfterMs
        )
        XCTAssertNil(LocksAPI.rateLimitBackoffMs(HttpError(status: 500, message: "", body: nil)))
        XCTAssertNil(LocksAPI.rateLimitBackoffMs(JsBaoError(code: .unavailable)))
    }

    // MARK: - Client wiring (behavior 10)

    func test_clientExposesLocks() {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://localhost:8787",
            wsUrl: "ws://localhost:8787",
            appId: "app_test",
            token: "test-token",
            offline: true,
            autoNetwork: false
        ))
        XCTAssertNotNil(client.locks, "client.locks must be wired")
    }
}
