import XCTest
@testable import JsBaoClient

/// A failed run, decoded in Swift against a live server — #3449 behaviors 12
/// and 13, project `server-functions` phase 4.
///
/// The issue reports `getStatus` and `waitFor` THROWING on a real failed task
/// run, so the claim that matters is about a real one. The hermetic suite
/// (`WorkflowStatusErrorHermeticTests`) pins the decode against bytes chosen
/// by hand; this pins it against bytes the server chose.
///
/// D3449-005 makes this the SPONSOR'S ONE COMMAND for the outstanding
/// agent-environment evidence. It targets whatever `TEST_HTTP_URL` /
/// `TEST_WS_URL` name and self-skips when the target will not mint a test app,
/// so
///
///     TEST_HTTP_URL=<agent host> TEST_WS_URL=<agent ws> \
///       swift test --package-path swift-client \
///       --filter FunctionsFailedStatusLiveTests/testFailedTaskRunDecodes
///
/// is the whole of it, and the runbook in
/// `projects/server-functions/swift-status-error-check-2026-09-15.md` says so.
///
/// The cases live in their own suite rather than inside `FunctionsLiveTests`
/// because that suite's `setUp` THROWS when a target will not take its
/// credentials, and a throw there is a failure rather than a skip — which is
/// exactly what a one-command run against an arbitrary host must not do.
final class FunctionsFailedStatusLiveTests: XCTestCase {
    private var ctx: TestContext!
    private var testApp: TestApp!
    private var client: JsBaoClient!
    /// Why the target could not be provisioned, when it could not be.
    private var unavailable: String?

    override func setUp() async throws {
        do {
            let context = TestContext()
            try await context.initialize()
            testApp = try await context.createTestApp(name: "swift-failed-status")
            ctx = context
            client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        } catch {
            // A target that will not take this suite's test credentials is not
            // a failure of the client: it is a target the case cannot run
            // against. Skipping says so, and is what lets the same command
            // point at the agent host, at a local dev server, or at nothing.
            unavailable =
                "target \(TestConfig.httpUrl) refused test setup: \(error)"
        }
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx?.cleanup()
    }

    private func requireTarget() throws {
        if let unavailable { throw XCTSkip(unavailable) }
    }

    private var counter = 0
    private func key(_ label: String) -> String {
        counter += 1
        return "swift-3449-\(label)-\(Int(Date().timeIntervalSince1970))-\(counter)"
    }

    private struct NoOutput: Decodable, Sendable, Equatable {}

    // MARK: - Behavior 12: a failed task run resolves rather than throwing

    /// The case the issue is about, end to end: a pushed task function whose
    /// handler throws, started with `functions.start`, waited with `waitFor`.
    ///
    /// Before this child every one of these calls threw
    /// `typeMismatch(Swift.String, … "Expected to decode String but found a
    /// dictionary instead.")` — the nested decode failed on the object, the
    /// whole-block `try?` fell through, and the fallback re-read `status` as a
    /// string. `waitFor` retried that throw as transient and burned its whole
    /// budget, which is Compound's report of a run stuck `running`.
    func testFailedTaskRunDecodes() async throws {
        try requireTarget()

        let functionKey = key("boom")
        try await ctx.pushFunction(
            appId: testApp.appId,
            functionKey: functionKey,
            bundle: #"export default async function () { throw new Error("boom from swift"); }"#,
            durable: true
        )
        let docId = try await ctx.createDocument(
            appId: testApp.appId, jwt: testApp.ownerJWT
        )

        let started = try await client.functions.start(
            functionKey, input: nil as JSONValue?, contextDocId: docId
        )
        XCTAssertFalse(started.runId.isEmpty)

        // Resolves. Does not throw — that IS behavior 12.
        let settled = try await client.functions.waitFor(
            runId: started.runId,
            options: FunctionWaitOptions(timeout: 120)
        )
        XCTAssertEqual(settled.status, "failed")
        XCTAssertTrue(settled.isFailure)
        // #3565 — ONE structured error on the function type, so `error` IS the
        // value rather than a message beside a `failure`.
        let waitMessage = try XCTUnwrap(
            settled.error?.message,
            "a failed run carries its structured error"
        )
        XCTAssertTrue(
            waitMessage.contains("boom from swift"),
            "the thrown text should survive to the client, got \(waitMessage)"
        )

        // `getStatus` on the same run agrees, and so does the typed overload.
        let status = try await client.functions.getStatus(runId: started.runId)
        XCTAssertEqual(status.status, "failed")
        XCTAssertEqual(status.error?.message, waitMessage)
        // `run` decodes through `FunctionRunInfo`, so a status that came back
        // at all is the whole response decoding, not one field.
        XCTAssertEqual(status.run?.runId, started.runId)
        XCTAssertEqual(status.run?.functionKey, functionKey)

        let typed: FunctionRunResult<NoOutput> = try await client.functions.getStatus(
            runId: started.runId
        )
        XCTAssertEqual(typed.status, "failed")
        XCTAssertEqual(typed.error, status.error)

        let typedWait = try await client.functions.waitFor(
            runId: started.runId,
            as: NoOutput.self,
            options: FunctionWaitOptions(timeout: 120)
        )
        XCTAssertEqual(typedWait.status, "failed")
        XCTAssertEqual(typedWait.error, settled.error)
    }

    // MARK: - Behavior 13: a failed DSL durable run, through both surfaces

}
