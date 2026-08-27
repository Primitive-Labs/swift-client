import XCTest
@testable import JsBaoClient

/// #2806 — the extras the CLI-generated Swift workflow factory needs to reach
/// parity with the JS factory (`terminate`, `cronTriggers.create/update`,
/// `define`).
///
/// The generated factory binds only PUBLISHED client surface, so the typed
/// `terminate<Output>` overload it calls is exercised here directly against a
/// recording transport — no dev server, no network. The generated factory's own
/// binding is proved by compiling the committed acceptance files
/// (`CodegenAcceptance/WorkflowCodegenAcceptanceTests.swift`).
final class WorkflowFactoryExtrasHermeticTests: XCTestCase {

    private func api(_ transport: RecordingTransport) -> WorkflowsAPI {
        WorkflowsAPI(transport: transport, getConnectionId: { "conn-1" })
    }

    /// The typed overload decodes the terminated run's partial `output` into
    /// `Output` — the Swift counterpart of the JS `terminate<O>` the generated
    /// factory binds `<Key>Output` over.
    func test_genericTerminate_typedOutput() async throws {
        let transport = RecordingTransport(json: #"""
        {"status":{"status":"terminated","output":{"checkoutUrl":"https://x"}},
         "run":{"runId":"r","runKey":"rk_1","status":"terminated"}}
        """#)
        let ended: WorkflowStatus<CreateCheckoutSessionOutput> =
            try await api(transport).terminate(
                workflowKey: "create-checkout-session",
                runKey: "rk_1"
            )
        let call = try XCTUnwrap(transport.lastCall)
        XCTAssertEqual(call.method, .post)
        XCTAssertEqual(
            call.path,
            "/workflows/create-checkout-session/instances/rk_1/terminate"
        )
        XCTAssertEqual(ended.status, "terminated")
        XCTAssertEqual(ended.output?.checkoutUrl, "https://x")
    }

    /// A terminated run with no output at all decodes to a `nil` typed output
    /// rather than throwing (same rule as the typed `getStatus`).
    func test_genericTerminate_absentOutputIsNil() async throws {
        let transport = RecordingTransport(json: #"""
        {"status":{"status":"terminated"},
         "run":{"runId":"r","runKey":"rk_2","status":"terminated"}}
        """#)
        let ended: WorkflowStatus<CreateCheckoutSessionOutput> =
            try await api(transport).terminate(
                workflowKey: "create-checkout-session",
                runKey: "rk_2",
                contextDocId: "doc_1"
            )
        XCTAssertNil(ended.output)
        // The doc scope reaches the wire, so a per-doc run routes correctly.
        XCTAssertEqual(
            transport.lastCall?.path,
            "/workflows/create-checkout-session/instances/rk_2/terminate?contextDocId=doc_1"
        )
    }

    // MARK: - Cron `rootInput` is tri-state on update

    /// A fully-populated `CronTriggerInfo` payload, so the update decodes and a
    /// wire-shape regression is what fails these tests.
    private func cronTriggerJSON() -> String {
        #"""
        {"triggerId":"trg_1","triggerKey":"k","displayName":"d","description":null,
         "cron":"* * * * *","timezone":"UTC","workflowKey":"tick",
         "overlapPolicy":"skip","rootInput":null,"inputMapping":null,
         "status":"active","lastError":null,"lastTriggeredAt":null,
         "lastTriggeredRunId":null,"nextFireAt":null,"skippedCount":0,
         "firedCount":0,"createdBy":"u1","createdAt":"2024-01-01T00:00:00Z",
         "modifiedAt":"2024-01-01T00:00:00Z"}
        """#
    }

    /// The generated factory's `update` lowers a `.clear` root input to
    /// `JSONValue.null`; this pins what that lowering puts on the wire — an
    /// EXPLICIT null, which is what clears a stored root input (JS sends the
    /// same thing for `rootInput: null`). Asserted on the client call the
    /// generated helper makes, since `client.cronTriggers` is built from the
    /// client's own HTTP stack and cannot be handed a stub transport; that the
    /// generated helper passes `.null` for `.clear` is pinned by the CLI unit
    /// test and compiled by the acceptance set.
    func test_cronUpdate_nullRootInput_clearsOnTheWire() async throws {
        let transport = RecordingTransport(json: cronTriggerJSON())
        _ = try await CronTriggersAPI(transport: transport).update(
            triggerId: "trg_1",
            params: UpdateCronTriggerParams(workflowKey: "tick", rootInput: .null)
        )
        let body = try XCTUnwrap(transport.lastCall?.jsonBody?.objectValue)
        XCTAssertEqual(
            body["rootInput"], JSONValue.null,
            "a cleared rootInput must reach the wire as an explicit null"
        )
    }

    /// The omitted state stays distinguishable from the cleared one: no
    /// `rootInput` key at all, so the stored root input is left untouched.
    func test_cronUpdate_omittedRootInput_isAbsentFromTheWire() async throws {
        let transport = RecordingTransport(json: cronTriggerJSON())
        _ = try await CronTriggersAPI(transport: transport).update(
            triggerId: "trg_1",
            params: UpdateCronTriggerParams(cron: "*/2 * * * *", workflowKey: "tick")
        )
        let body = try XCTUnwrap(transport.lastCall?.jsonBody?.objectValue)
        XCTAssertNil(body["rootInput"])
        XCTAssertEqual(body["cron"], JSONValue.string("*/2 * * * *"))
    }
}
