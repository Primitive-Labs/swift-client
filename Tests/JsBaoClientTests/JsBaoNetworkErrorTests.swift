import Foundation
import XCTest
@testable import JsBaoClient

/// `JsBaoNetworkError` is the public error apps catch instead of `URLError`
/// (#2367), so its three behavioral claims need assertions rather than a
/// source-text grep:
///
///  1. `URLError.cancelled` normalizes to `CancellationError`, **not** to a
///     network error. `packages/swift-primitive-app` deleted its
///     `catch let urlError as URLError where …cancelled` clauses on the
///     strength of that, so inverting the branch would silently reroute every
///     task-cancellation to the network handler.
///  2. Every other `URLError` normalizes to a `JsBaoNetworkError` that keeps
///     the underlying `errorCode`, which is the only thing `isTimeout` has to
///     work from.
///  3. Errors the client already owns pass through untouched — a
///     `JsBaoError` must not be re-labelled a transport failure.
///
/// Before this suite the only tests naming the type read source text
/// (`InternalVisibilityTests`, `TransportSpineTests`), so all three could be
/// inverted with the suite green.
final class JsBaoNetworkErrorTests: XCTestCase {

    // MARK: - Claim 1: cancellation is not a network error

    func testCancelledURLErrorNormalizesToCancellationError() {
        let normalized = JsBaoNetworkError.normalizing(URLError(.cancelled))

        XCTAssertTrue(
            normalized is CancellationError,
            "URLError.cancelled must normalize to CancellationError, not \(type(of: normalized))"
        )
        XCTAssertFalse(
            normalized is JsBaoNetworkError,
            "a cancelled request is not a network failure — apps catch CancellationError for it"
        )
    }

    // MARK: - Claim 2: other URLErrors keep their code

    func testTimedOutURLErrorNormalizesToNetworkErrorWithIsTimeout() throws {
        let normalized = JsBaoNetworkError.normalizing(URLError(.timedOut))

        let networkError = try XCTUnwrap(
            normalized as? JsBaoNetworkError,
            "URLError.timedOut must normalize to JsBaoNetworkError"
        )
        XCTAssertEqual(networkError.urlErrorCode, URLError.Code.timedOut.rawValue)
        XCTAssertTrue(networkError.isTimeout)
        XCTAssertEqual(networkError.message, URLError(.timedOut).localizedDescription)
    }

    func testNonTimeoutURLErrorIsNotReportedAsATimeout() throws {
        let normalized = JsBaoNetworkError.normalizing(URLError(.notConnectedToInternet))

        let networkError = try XCTUnwrap(normalized as? JsBaoNetworkError)
        XCTAssertEqual(networkError.urlErrorCode, URLError.Code.notConnectedToInternet.rawValue)
        XCTAssertFalse(
            networkError.isTimeout,
            "isTimeout is computed from urlErrorCode, so a non-timeout code must read false"
        )
    }

    /// `isTimeout` is computed rather than stored precisely so it cannot
    /// disagree with the code it is derived from. Pin that: a hand-built value
    /// carrying a non-timeout code must not claim to be a timeout.
    func testIsTimeoutCannotContradictItsCode() {
        XCTAssertTrue(
            JsBaoNetworkError(
                message: "anything", urlErrorCode: URLError.Code.timedOut.rawValue
            ).isTimeout
        )
        XCTAssertFalse(
            JsBaoNetworkError(
                message: "Request timed out", urlErrorCode: URLError.Code.cannotFindHost.rawValue
            ).isTimeout,
            "isTimeout must follow urlErrorCode, not the message text"
        )
        XCTAssertFalse(
            JsBaoNetworkError(message: "no code at all").isTimeout,
            "a failure with no URLError code is not classifiable as a timeout"
        )
    }

    /// `init(transport:)` is the single mapping the WS path shares
    /// (`WebSocketManager.transportFailure(from:)`), so dropping the code here
    /// would silently blank `ConnectionErrorEvent`'s code too.
    func testTransportInitCarriesTheURLErrorCodeThrough() {
        let error = JsBaoNetworkError(transport: URLError(.networkConnectionLost))

        XCTAssertEqual(error.urlErrorCode, URLError.Code.networkConnectionLost.rawValue)
        XCTAssertEqual(error.message, URLError(.networkConnectionLost).localizedDescription)
    }

    func testTransportInitOfANonURLErrorHasNoCode() {
        let error = JsBaoNetworkError(transport: JsBaoError(code: .offline, message: "nope"))

        XCTAssertNil(error.urlErrorCode)
        XCTAssertEqual(error.message, "nope")
        XCTAssertFalse(error.isTimeout)
    }

    // MARK: - Claim 3: the client's own errors pass through

    func testClientOwnedErrorsPassThroughNormalizationUntouched() throws {
        let original = JsBaoError(code: .accessDenied, message: "denied")
        let normalized = JsBaoNetworkError.normalizing(original)

        let passedThrough = try XCTUnwrap(
            normalized as? JsBaoError,
            "a JsBaoError must not be relabelled as a transport failure"
        )
        XCTAssertEqual(passedThrough.code, .accessDenied)
        XCTAssertEqual(passedThrough.message, "denied")
    }

    func testHttpErrorPassesThroughNormalizationUntouched() throws {
        let original = HttpError(status: 401, message: "Invalid credentials")
        let normalized = JsBaoNetworkError.normalizing(original)

        let passedThrough = try XCTUnwrap(
            normalized as? HttpError,
            "the credential path must keep throwing HttpError(status: 401)"
        )
        XCTAssertEqual(passedThrough.status, 401)
    }

    // MARK: - Surface details

    func testErrorDescriptionIsTheMessageVerbatim() {
        let error = JsBaoNetworkError(message: "The Internet connection appears to be offline.")

        XCTAssertEqual(
            error.errorDescription,
            "The Internet connection appears to be offline.",
            "the client does not prefix the underlying message"
        )
        XCTAssertEqual(error.localizedDescription, error.message)
    }

    func testEquatableComparesMessageAndCode() {
        let a = JsBaoNetworkError(message: "same", urlErrorCode: 1)
        let b = JsBaoNetworkError(message: "same", urlErrorCode: 1)
        let c = JsBaoNetworkError(message: "same", urlErrorCode: 2)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
