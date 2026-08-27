import XCTest
@testable import JsBaoClient

/// Regression tests for `WebSocketManager.reconnectDelayMs(attempts:maxReconnectDelayMs:)`,
/// the pure exponential-backoff computation behind `calculateReconnectDelay()`.
///
/// Issue #2027: the delay cap used to be applied in the `Int` domain
/// (`min(Int(pow(2.0, attempts)), maxSeconds)`), so once `attempts` reached
/// ~63 the `Double → Int` conversion trapped with "Double value cannot be
/// converted to Int because the result would be greater than Int.max" — before
/// the cap could clamp it. A client that could not reach the server for enough
/// consecutive reconnect cycles crashed the whole process. These tests drive
/// `attempts` far past that point and assert the delay clamps without trapping,
/// while low counts keep their original backoff values.
final class ReconnectDelayTests: XCTestCase {

    // maxReconnectDelayMs = 30_000 → maxSeconds = 30 → capped delay = 200 + 30_000 = 30_200 ms.
    private let maxReconnectDelayMs = 30_000
    private let baseDelayMs = 200

    /// High attempt counts (including well past the ~63 overflow threshold and
    /// past the Double exponent limit where `pow` returns `.infinity`) must
    /// return the capped delay without crashing.
    func testHighAttemptCountsClampWithoutOverflow() {
        let maxSeconds = max(1, maxReconnectDelayMs / 1000)
        let expectedCapped = baseDelayMs + maxSeconds * 1000

        for attempts in [63, 64, 100, 1000, 100_000] {
            let delay = WebSocketManager.reconnectDelayMs(
                attempts: attempts,
                maxReconnectDelayMs: maxReconnectDelayMs
            )
            XCTAssertEqual(
                delay, expectedCapped,
                "attempts=\(attempts) should clamp to the max delay, not trap or exceed it"
            )
        }
    }

    /// Low attempt counts keep the original exponential-backoff progression:
    /// 200 + 2^attempts * 1000, until the cap takes over.
    func testLowAttemptCountsMatchExistingBackoff() {
        // 2^0..2^4 are all below the 30s cap, so they follow the exponential curve.
        let expected: [Int: Int] = [
            0: baseDelayMs + 1 * 1000,   // 2^0 = 1  → 1_200
            1: baseDelayMs + 2 * 1000,   // 2^1 = 2  → 2_200
            2: baseDelayMs + 4 * 1000,   // 2^2 = 4  → 4_200
            3: baseDelayMs + 8 * 1000,   // 2^3 = 8  → 8_200
            4: baseDelayMs + 16 * 1000,  // 2^4 = 16 → 16_200
        ]
        for (attempts, want) in expected {
            let delay = WebSocketManager.reconnectDelayMs(
                attempts: attempts,
                maxReconnectDelayMs: maxReconnectDelayMs
            )
            XCTAssertEqual(delay, want, "attempts=\(attempts) backoff value changed")
        }
    }

    /// The transition point: 2^5 = 32s exceeds the 30s cap, so it clamps.
    func testBackoffClampsOnceExponentExceedsCap() {
        let maxSeconds = max(1, maxReconnectDelayMs / 1000) // 30
        let capped = baseDelayMs + maxSeconds * 1000        // 30_200

        // 2^4 = 16s < 30s cap → not clamped.
        XCTAssertEqual(
            WebSocketManager.reconnectDelayMs(attempts: 4, maxReconnectDelayMs: maxReconnectDelayMs),
            baseDelayMs + 16 * 1000
        )
        // 2^5 = 32s > 30s cap → clamped.
        XCTAssertEqual(
            WebSocketManager.reconnectDelayMs(attempts: 5, maxReconnectDelayMs: maxReconnectDelayMs),
            capped
        )
    }

    /// The default reconnect ceiling is 300 seconds, matching js-bao's
    /// `maxReconnectDelay` default of `300_000` ms
    /// (`src/client/JsBaoClient.ts`). It used to be 30 here, and because both
    /// clients compute the same backoff, that made Swift retry roughly ten
    /// times as often — forever — against a server that is down (#2364).
    func testDefaultReconnectCeilingMatchesTheJsFiveMinuteDefault() {
        let options = JsBaoClientOptions(
            apiUrl: "http://localhost:8787",
            wsUrl: "ws://localhost:8787",
            appId: "app-1"
        )
        XCTAssertEqual(options.maxReconnectDelay, 300, "default ceiling is 5 minutes, as in JS")

        // The option is seconds; the manager takes milliseconds.
        let defaultCeilingMs = Int(options.maxReconnectDelay * 1000)
        XCTAssertEqual(defaultCeilingMs, 300_000)
        XCTAssertEqual(
            WebSocketManager.reconnectDelayMs(attempts: 100, maxReconnectDelayMs: defaultCeilingMs),
            baseDelayMs + 300 * 1000,
            "a client that cannot reach the server settles at one retry every ~5 minutes"
        )

        // An app that wants a tighter ceiling can still ask for one.
        let tighter = JsBaoClientOptions(
            apiUrl: "http://localhost:8787",
            wsUrl: "ws://localhost:8787",
            appId: "app-1",
            maxReconnectDelay: 30
        )
        XCTAssertEqual(tighter.maxReconnectDelay, 30)
    }
}
