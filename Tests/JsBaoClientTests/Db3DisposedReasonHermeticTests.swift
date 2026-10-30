import XCTest
@testable import JsBaoClient

/// #5044 behaviour 15 — a `DB3_DISPOSED` rejection says why the subscription
/// ended, in the web client's words: `details["reason"]` is `disposed`
/// (`dispose()`), `destroyed` (the client was destroyed, and a subscribe after
/// it), `closed` (a document door's close), `evicted` (the local copy was
/// removed, explicitly or by the retention policy) or `identity-changed` (a
/// sign-out or another user's sign-in), and `details["db3Id"]` names the db3.
/// The set of reasons is the one `src/client/internal/db3Lifecycle.ts` gives
/// its `DB3_DISPOSED` errors.
final class Db3DisposedReasonHermeticTests: XCTestCase {

    private static let id = "01JD5044REASONSXXXXXXXXXXX"

    /// A db3 that is a db3 and never goes live: every `ready()` stays pending
    /// until a door ends it.
    private func lifecycle(destroyed: Bool = false) -> Db3Lifecycle {
        Db3Lifecycle(deps: Db3LifecycleDeps(destroyed: { destroyed }, resolveFormat: { _ in 3 }))
    }

    private func subscribe(_ lifecycle: Db3Lifecycle) throws -> Db3Subscription {
        try lifecycle.subscribe(Self.id, options: Db3SubscribeOptions(readyTimeout: .infinity))
    }

    /// The error `ready()` threw.
    private func rejection(_ subscription: Db3Subscription) async -> JsBaoError? {
        do {
            try await subscription.ready()
            return nil
        } catch {
            return error as? JsBaoError
        }
    }

    private func assertDisposed(
        _ error: JsBaoError?, _ reason: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(error?.code, .db3Disposed, file: file, line: line)
        XCTAssertEqual(error?.details?["reason"]?.stringValue, reason, file: file, line: line)
        XCTAssertEqual(error?.details?["db3Id"]?.stringValue, Self.id, file: file, line: line)
    }

    private func jsSource(_ path: String) throws -> String {
        guard ClientSourceText.isMonorepoCheckout else {
            throw XCTSkip("the JS client source is not present (published SwiftPM mirror)")
        }
        return try ClientSourceText.repoFile(path)
    }

    /// The `reason` of every `DB3_DISPOSED` error the JS lifecycle builds.
    private func jsReasons() throws -> Set<String> {
        let source = try jsSource("src/client/internal/db3Lifecycle.ts")
        var reasons: Set<String> = []
        var rest = source[...]
        while let start = rest.range(of: "new JsBaoError(\"DB3_DISPOSED\"") {
            let tail = rest[start.upperBound...]
            let end = tail.range(of: "})")?.upperBound ?? tail.endIndex
            let call = tail[..<end]
            if let at = call.range(of: "reason: \"") {
                let value = call[at.upperBound...].prefix { $0 != "\"" }
                reasons.insert(String(value))
            }
            rest = tail[end...]
        }
        return reasons
    }

    func testEveryDoorSaysWhyTheSubscriptionEnded() async throws {
        var seen: Set<String> = []
        func note(_ error: JsBaoError?) {
            if let reason = error?.details?["reason"]?.stringValue { seen.insert(reason) }
        }

        // dispose()
        do {
            let lifecycle = lifecycle()
            let handle = try subscribe(lifecycle)
            handle.dispose()
            let error = await rejection(handle)
            assertDisposed(error, "disposed")
            note(error)
        }

        // destroy(), and a subscribe after it
        do {
            let lifecycle = lifecycle()
            let handle = try subscribe(lifecycle)
            await lifecycle.destroy()
            let error = await rejection(handle)
            assertDisposed(error, "destroyed")
            note(error)
            XCTAssertThrowsError(try subscribe(lifecycle)) { thrown in
                self.assertDisposed(thrown as? JsBaoError, "destroyed")
            }
        }
        do {
            XCTAssertThrowsError(try subscribe(lifecycle(destroyed: true))) { thrown in
                self.assertDisposed(thrown as? JsBaoError, "destroyed")
            }
        }

        // A document door's close
        do {
            let lifecycle = lifecycle()
            let handle = try subscribe(lifecycle)
            lifecycle.closedByDoor(Self.id)
            let error = await rejection(handle)
            assertDisposed(error, "closed")
            note(error)
        }

        // The local copy removed, explicitly and by the retention policy
        for reason in [Db3EvictedEvent.Reason.explicit, .retention] {
            let lifecycle = lifecycle()
            let handle = try subscribe(lifecycle)
            try await lifecycle.removeStore(Self.id, force: true, reason: reason)
            let error = await rejection(handle)
            assertDisposed(error, "evicted")
            note(error)
        }

        // A sign-out or another user's sign-in
        do {
            let lifecycle = lifecycle()
            let handle = try subscribe(lifecycle)
            lifecycle.forgetStates()
            await lifecycle.releaseAll(unbind: true)
            let error = await rejection(handle)
            assertDisposed(error, "identity-changed")
            note(error)
        }

        XCTAssertEqual(seen, ["disposed", "destroyed", "closed", "evicted", "identity-changed"])
        let web = try jsReasons()
        XCTAssertEqual(seen, web, "the web client's DB3_DISPOSED reasons, verbatim")
    }
}
