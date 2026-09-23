import XCTest
@testable import JsBaoClient

/// `functions.waitFor` does not report a live run missing — #3661.
///
/// The filing is against the JS client, and this surface is its mirror down to
/// the poll schedule and the wording of every refusal, so it had the same
/// defect: the wait ended on the FIRST 404, and `GET
/// /workflows/runs/{runId}/status` answers 404 for two unrelated facts.
///
///  - the run id resolved to no row. The reads behind that are eventually
///    consistent, so a poll a second after a start can miss a committed row.
///  - `{ status: "missing", … }` — the row IS there and unsettled, and the
///    platform cannot see its instance. Inside the launch grace that is the
///    server's deliberate answer for a run between its row write and its
///    instance, and it writes nothing for it on purpose.
///
/// Neither is "this run does not exist", and the second says the opposite. So
/// the wait tells them apart by BODY, the way `terminate` already tells its own
/// three 404s apart (``FunctionTerminateClassifier``).
///
/// Server-free, and in no real time: the scripted transport answers each poll
/// and the fake clock advances only when the wait sleeps, so the three-second
/// stale-read grace is asserted on the arithmetic rather than on the host.
final class FunctionsWaitNotFound3661HermeticTests: XCTestCase {

    /// The status route, scripted per poll.
    private final class ScriptedTransport: Transport, @unchecked Sendable {
        enum Answer {
            case status(String, output: Any? = nil)
            case http(Int, body: String)
        }

        private let lock = NSLock()
        private var script: [Answer]
        private let tail: Answer
        private var _polls = 0

        var polls: Int { lock.withLock { _polls } }

        init(_ script: [Answer], tail: Answer) {
            self.script = script
            self.tail = tail
        }

        func execute(
            method: HTTPMethod,
            path: String,
            body: Data?,
            options: RequestOptions?
        ) async throws -> TransportResponse {
            let answer: Answer = lock.withLock {
                _polls += 1
                return script.isEmpty ? tail : script.removeFirst()
            }
            switch answer {
            case let .status(status, output):
                var statusObj: [String: Any] = ["status": status]
                if let output { statusObj["output"] = output }
                let run: [String: Any] = ["runId": "r1", "runKey": "rk-1", "status": status]
                let data = try JSONSerialization.data(
                    withJSONObject: ["status": statusObj, "run": run]
                )
                return TransportResponse(
                    status: 200,
                    headers: ["Content-Type": "application/json"],
                    body: data
                )
            case let .http(code, body):
                return TransportResponse(
                    status: code,
                    headers: ["Content-Type": "application/json"],
                    body: Data(body.utf8)
                )
            }
        }
    }

    /// A clock the fake sleep advances, so the wait's whole schedule — the
    /// backoff and the grace alike — runs instantly and every sleep is on
    /// record.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_700_000_000)
        private var _sleeps: [TimeInterval] = []

        var now: Date { lock.withLock { _now } }
        var sleeps: [TimeInterval] { lock.withLock { _sleeps } }
        var slept: TimeInterval { sleeps.reduce(0, +) }

        func install(on api: FunctionsAPI) {
            api.clockForTest = { [self] in self.now }
            api.sleepForTest = { [self] seconds in
                self.lock.withLock {
                    self._sleeps.append(seconds)
                    self._now = self._now.addingTimeInterval(seconds)
                }
            }
        }
    }

    private func makeApi(_ transport: ScriptedTransport) -> (FunctionsAPI, FakeClock) {
        let api = FunctionsAPI(transport: transport)
        let clock = FakeClock()
        clock.install(on: api)
        return (api, clock)
    }

    /// `statusByRunId`'s answer when the run id resolved to no row.
    private static let noRow = #"{"error":"Run not found","status":404,"code":"NOT_FOUND"}"#
    /// Its answer for a live, unsettled row whose instance it cannot see.
    private static let instanceUnseen =
        #"{"status":"missing","error":"Workflow instance not found","code":"NOT_FOUND"}"#

    // MARK: - the wait

    func testWaitsThroughAnInstanceMissing404AndSettles() async throws {
        let transport = ScriptedTransport(
            [
                .http(404, body: Self.instanceUnseen),
                .http(404, body: Self.instanceUnseen),
                .http(404, body: Self.instanceUnseen),
                .status("completed", output: ["napped": true]),
            ],
            tail: .status("completed", output: ["napped": true])
        )
        let (api, _) = makeApi(transport)

        let settled = try await api.waitFor(runId: "r1", options: FunctionWaitOptions(timeout: 30))

        XCTAssertEqual(settled.status, "completed")
        XCTAssertEqual(transport.polls, 4)
    }

    func testRetriesARunNotFound404RatherThanFailingOnTheFirst() async throws {
        let transport = ScriptedTransport(
            [.http(404, body: Self.noRow), .http(404, body: Self.noRow), .status("failed")],
            tail: .status("failed")
        )
        let (api, _) = makeApi(transport)

        let settled = try await api.waitFor(runId: "r1", options: FunctionWaitOptions(timeout: 30))

        XCTAssertEqual(settled.status, "failed")
        XCTAssertEqual(transport.polls, 3)
    }

    func testStillReportsNotFoundPastTheStaleReadGrace() async throws {
        let transport = ScriptedTransport([], tail: .http(404, body: Self.noRow))
        let (api, clock) = makeApi(transport)

        do {
            _ = try await api.waitFor(runId: "r1", options: FunctionWaitOptions(timeout: 600))
            XCTFail("a run id that never resolves must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertEqual(error.message, "Function run r1 not found")
        }
        XCTAssertGreaterThan(transport.polls, 1, "the first 404 is no longer final")
        // `FunctionsAPI.waitNotFoundGrace`, spent exactly rather than rounded
        // up to whichever backoff interval straddles it.
        XCTAssertEqual(clock.slept, 3, accuracy: 0.001)
        XCTAssertLessThan(clock.slept, 600, "and nowhere near the requested budget")
    }

    /// The two bodies that mean "no row" without saying `Run not found`: the
    /// workflowKey route's spelling of an absent row under a `missing` status,
    /// and a body the classifier cannot read at all. Both take the bounded
    /// grace, not the caller's whole budget.
    func testAnUnreadableOrAbsentRowBodyTakesTheSameBoundedGrace() async throws {
        for body in [
            #"{"status":"missing","error":"Workflow run not found"}"#,
            "HTTP 404",
        ] {
            let transport = ScriptedTransport([], tail: .http(404, body: body))
            let (api, clock) = makeApi(transport)
            do {
                _ = try await api.waitFor(runId: "r1", options: FunctionWaitOptions(timeout: 600))
                XCTFail("a run id that never resolves must throw")
            } catch let error as JsBaoError {
                XCTAssertEqual(error.code, .notFound, body)
            }
            XCTAssertEqual(clock.slept, 3, accuracy: 0.001, body)
        }
    }

    func testReportsTheNotFoundRatherThanAWaitTimeoutAtTheDeadline() async throws {
        // A timeout shorter than the grace. The run id resolved to nothing on
        // every poll, and "timed out waiting" would hide that.
        let transport = ScriptedTransport([], tail: .http(404, body: Self.noRow))

        do {
            _ = try await makeApi(transport).0
                .waitFor(runId: "r1", options: FunctionWaitOptions(timeout: 0.9))
            XCTFail("a run id that never resolves must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .notFound)
        }
    }

    func testReportsTheNotFoundWhenARunStaysInstanceMissingToTheDeadline() async throws {
        let transport = ScriptedTransport([], tail: .http(404, body: Self.instanceUnseen))

        do {
            _ = try await makeApi(transport).0
                .waitFor(runId: "r1", options: FunctionWaitOptions(timeout: 0.9))
            XCTFail("a run the platform never showed must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .notFound)
        }
    }

    func testARunThatIsMerelySlowStillRaisesTheWaitTimeout() async throws {
        let transport = ScriptedTransport([], tail: .status("running"))

        do {
            _ = try await makeApi(transport).0
                .waitFor(runId: "r1", options: FunctionWaitOptions(timeout: 0.9))
            XCTFail("a slow run must time out")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .workflowWaitTimeout)
        }
    }

    func testGetStatusStaysOneReadThatReportsWhatItRead() async throws {
        // The grace belongs to the WAIT. One status read is a question about now.
        let transport = ScriptedTransport([], tail: .http(404, body: Self.instanceUnseen))

        do {
            _ = try await makeApi(transport).0.getStatus(runId: "r1")
            XCTFail("a 404 must throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertEqual(error.message, "Function run r1 not found")
        }
        XCTAssertEqual(transport.polls, 1)
    }

    /// The error envelope's NUMERIC `status` is not the string `"missing"`: a
    /// run id that resolves to nothing must not buy a live run's unbounded
    /// wait by carrying `status: 404`. `noRow` above is that exact envelope,
    /// and the grace it took in `testStillReportsNotFoundPastTheStaleReadGrace`
    /// is the proof; this pins the other end of it — a body that really does
    /// report a missing instance is polled past three seconds.
    func testAnUnseenInstanceIsNotBoundedByTheStaleReadGrace() async throws {
        let transport = ScriptedTransport(
            [
                .http(404, body: Self.instanceUnseen),
                .http(404, body: Self.instanceUnseen),
                .http(404, body: Self.instanceUnseen),
                .http(404, body: Self.instanceUnseen),
                .status("completed"),
            ],
            tail: .status("completed")
        )
        let (api, clock) = makeApi(transport)

        let settled = try await api.waitFor(runId: "r1", options: FunctionWaitOptions(timeout: 600))

        XCTAssertEqual(settled.status, "completed")
        XCTAssertGreaterThan(clock.slept, 3, "the grace does not bound a run that exists")
    }
}
