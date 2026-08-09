import XCTest
@testable import JsBaoClient

/// Acceptance tests for the CLI-generated Swift workflow codegen (issue #1547,
/// Phase 3, behaviors 12-15).
///
/// The committed `.generated.swift` files under `Generated/` are the acceptance
/// set the maintainer decision (item 2) requires: they are emitted by
/// `primitive workflows codegen --lang swift` from the fixture TOMLs in
/// `cli/tests/fixtures/swift-invoker-acceptance/workflows/` and committed here so
/// `swift build` (behavior 12) and the full `swift test` (behavior 13) validate
/// that generated Swift compiles and round-trips against the real library.
///
/// This file covers:
///   - behavior 14: `<Key>Input`/`<Key>Output` encode → JSON → decode → equal,
///     and a server-shaped JSON fixture decodes into the generated type.
///   - behavior 15: the generated invoker binds `<Key>Input`/`<Key>Output` over
///     the additive generic `WorkflowsAPI` overloads, `runSync` only for
///     `syncCallable` workflows. The compile of `Generated/` + `bindingsCompile`
///     below is the binding proof; the generic overloads are exercised live
///     against a recording transport.
final class WorkflowCodegenAcceptanceTests: XCTestCase {

    // MARK: - Stub transport

    /// `RecordingTransport` records the request and returns canned bytes — the
    /// same pattern the API-parity tests use to exercise a client method
    /// without a live server. Hold the transport so the recorded call can be
    /// read back after the `await`.
    private func api(_ transport: RecordingTransport) -> WorkflowsAPI {
        WorkflowsAPI(transport: transport, getConnectionId: { "conn-1" })
    }

    // MARK: - Behavior 14: round-trip + server-shaped decode

    func test_input_encodeDecodeRoundTrips() throws {
        let input = CreateCheckoutSessionInput(
            priceId: "price_123",
            quantity: 2,
            mode: .subscription
        )
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(CreateCheckoutSessionInput.self, from: data)
        XCTAssertEqual(decoded, input)
    }

    func test_output_serverShapedJSON_decodes() throws {
        // A server-shaped payload for the checkout output, including the
        // nullable `expiresAt` absent.
        let json = #"{"checkoutUrl":"https://pay.example/abc"}"#.data(using: .utf8)!
        let out = try JSONDecoder().decode(CreateCheckoutSessionOutput.self, from: json)
        XCTAssertEqual(out.checkoutUrl, "https://pay.example/abc")
        XCTAssertNil(out.expiresAt)
    }

    func test_requiredNullable_explicitNull_roundTrips() throws {
        // `nickname` is required-nullable → explicit null on encode, lenient
        // decode. An open-object `extra` catch-all preserves unknown keys.
        let json = #"{"name":"Ada","nickname":null,"favoriteColor":"green"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(UpdateProfileInput.self, from: json)
        XCTAssertEqual(decoded.name, "Ada")
        XCTAssertNil(decoded.nickname)
        XCTAssertEqual(decoded.extra["favoriteColor"], .string("green"))

        // Re-encode must preserve both the explicit null and the extra key.
        let reencoded = try JSONEncoder().encode(decoded)
        let obj = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        XCTAssertNotNil(obj)
        XCTAssertTrue(obj?.keys.contains("nickname") ?? false,
                      "required-nullable nickname must encode as explicit null")
        XCTAssertEqual(obj?["favoriteColor"] as? String, "green")
    }

    func test_oneOfOutput_decodesByDiscriminator() throws {
        let cardJSON = #"{"kind":"card","last4":"4242"}"#.data(using: .utf8)!
        let card = try JSONDecoder().decode(ProcessPaymentOutput.self, from: cardJSON)
        guard case let .card(branch) = card else {
            return XCTFail("expected .card branch")
        }
        XCTAssertEqual(branch.last4, "4242")

        let bankJSON = #"{"kind":"bank","accountId":"acct_1"}"#.data(using: .utf8)!
        let bank = try JSONDecoder().decode(ProcessPaymentOutput.self, from: bankJSON)
        guard case let .bank(branch) = bank else {
            return XCTFail("expected .bank branch")
        }
        XCTAssertEqual(branch.accountId, "acct_1")
    }

    func test_schemaLess_typealias_isJSONValue() throws {
        // A schema-less workflow's Input/Output alias to JSONValue.
        let value: ImportCsvInput = .object(["rows": .number(3)])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ImportCsvOutput.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // MARK: - Behavior 15: generic WorkflowsAPI overloads (published surface)

    func test_genericRunSync_typedInputAndOutput() async throws {
        let transport = RecordingTransport(json: #"""
        {"runId":"run_1","runKey":"rk_1","status":"completed",
         "output":{"checkoutUrl":"https://pay.example/abc"}}
        """#)
        let result: RunSyncResult<CreateCheckoutSessionOutput> =
            try await api(transport).runSync(
                workflowKey: "create-checkout-session",
                input: CreateCheckoutSessionInput(priceId: "price_123")
            )
        let call = try XCTUnwrap(transport.lastCall)
        XCTAssertEqual(call.method, .post)
        XCTAssertEqual(call.path, "/workflows/create-checkout-session/run-sync")
        // Typed input was encoded into the opaque `rootInput` object.
        let rootInput = try XCTUnwrap(call.jsonBody?["rootInput"])
        XCTAssertEqual(rootInput["priceId"]?.stringValue, "price_123")
        // Typed output decoded from the opaque `output` blob.
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.output?.checkoutUrl, "https://pay.example/abc")
    }

    func test_genericRunSync_oneOfOutput() async throws {
        let transport = RecordingTransport(json: #"""
        {"runId":"run_2","runKey":"rk_2","status":"completed",
         "output":{"kind":"bank","accountId":"acct_9"}}
        """#)
        let result: RunSyncResult<ProcessPaymentOutput> =
            try await api(transport).runSync(
                workflowKey: "process-payment",
                input: ProcessPaymentInput(amount: 42)
            )
        guard case let .bank(branch) = result.output else {
            return XCTFail("expected .bank branch decoded from generic runSync")
        }
        XCTAssertEqual(branch.accountId, "acct_9")
    }

    func test_genericGetStatus_typedOutput() async throws {
        let transport = RecordingTransport(json: #"""
        {"status":{"status":"completed","output":{"checkoutUrl":"https://x"}},
         "run":{"runId":"r","runKey":"k","status":"completed"}}
        """#)
        let status: WorkflowStatus<CreateCheckoutSessionOutput> =
            try await api(transport).getStatus(
                workflowKey: "create-checkout-session",
                runKey: "rk_1"
            )
        XCTAssertEqual(status.output?.checkoutUrl, "https://x")
    }

    func test_genericStart_encodesTypedInput() async throws {
        let transport = RecordingTransport(
            json: #"{"runId":"run_3","runKey":"rk_3","status":"running"}"#
        )
        let started: StartWorkflowResult = try await api(transport).start(
            workflowKey: "create-checkout-session",
            input: CreateCheckoutSessionInput(priceId: "p_1", quantity: 5)
        )
        XCTAssertEqual(started.runId, "run_3")
        let rootInput = try XCTUnwrap(transport.lastCall?.jsonBody?["rootInput"])
        XCTAssertEqual(rootInput["priceId"]?.stringValue, "p_1")
        XCTAssertEqual(rootInput["quantity"]?.numberValue, 5)
    }

    func test_genericStart_nilInputSendsEmptyObject() async throws {
        let transport = RecordingTransport(
            json: #"{"runId":"r","runKey":"k","status":"running"}"#
        )
        // Optional-input workflow: passing nil sends `{}` (parity with JS).
        let _: StartWorkflowResult = try await api(transport).start(
            workflowKey: "import-csv",
            input: Optional<ImportCsvInput>.none
        )
        let rootInput = try XCTUnwrap(transport.lastCall?.jsonBody?["rootInput"]?.objectValue)
        XCTAssertTrue(rootInput.isEmpty)
    }
}

/// Compile-only proof (behavior 15) that the committed invoker factories bind
/// `<Key>Input`/`<Key>Output` over the generic `WorkflowsAPI` overloads. Never
/// executed — being COMPILED is the assertion. `runSync` is referenced only for
/// the `syncCallable` workflows (`create-checkout-session`, `process-payment`);
/// the async-only ones (`import-csv`, `update-profile`) expose `start` +
/// `getStatus` only — the generator does not emit `runSync` for them, which the
/// TS golden asserts negatively.
@available(*, unavailable)
private func _acceptanceInvokerBindingsCompile(_ client: JsBaoClient) async throws {
    let checkout = createCheckoutSession(client)
    let checkoutOut: RunSyncResult<CreateCheckoutSessionOutput> =
        try await checkout.runSync(input: CreateCheckoutSessionInput(priceId: "p"))
    _ = checkoutOut.output?.checkoutUrl
    let checkoutStatus: WorkflowStatus<CreateCheckoutSessionOutput> =
        try await checkout.getStatus(runKey: "rk")
    _ = checkoutStatus.output
    let checkoutStart: StartWorkflowResult =
        try await checkout.start(input: CreateCheckoutSessionInput(priceId: "p"))
    _ = checkoutStart.runId

    let payment = processPayment(client)
    let paymentOut: RunSyncResult<ProcessPaymentOutput> =
        try await payment.runSync(input: ProcessPaymentInput(amount: 1))
    _ = paymentOut.output

    // Async-only invokers: start + getStatus, input optional (schema-less /
    // typed) — no runSync member exists to call.
    let importer = importCsv(client)
    _ = try await importer.start(input: nil)
    _ = try await importer.getStatus(runKey: "rk")

    let profile = updateProfile(client)
    _ = try await profile.start(input: UpdateProfileInput(name: "n", nickname: nil))
}
