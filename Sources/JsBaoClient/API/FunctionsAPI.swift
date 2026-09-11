import Foundation

// MARK: - FunctionsAPI

/// Server functions, available as `client.functions`. Mirrors the JS client's
/// `client.functions` (`src/client/api/functionsApi.ts`) — #3278.
///
/// A function is TypeScript an app's team authored in its config tree and
/// pushed with `primitive config push`. A REQUEST function is invoked and
/// answers its result; a TASK function is started and answers a run id that
/// is polled on exactly the routes a DSL workflow run is. The method set is
/// JS's and nothing more: `invoke`, `start`, `getStatus`, `waitFor`,
/// `terminate`. The client-apply trio stays on `workflows`, where both
/// clients keep it — a function run never enters `apply_pending`.
///
/// `terminate` and the run-id status fetch delegate to `WorkflowsAPI` with the
/// function key in the workflow-key slot: that IS the alias, not a second
/// protocol. `waitFor` is the one method that cannot delegate — a function run
/// broadcasts no `workflowStatus` frame, so it polls.
public final class FunctionsAPI: @unchecked Sendable {
    private let transport: any Transport
    private let workflows: WorkflowsAPI
    private let logger: Logger?

    /// Designated initializer — the typed transport spine. `workflows` is the
    /// sibling sub-API the control routes delegate to.
    public convenience init(transport: any Transport, workflows: WorkflowsAPI) {
        self.init(transport: transport, workflows: workflows, logger: nil)
    }

    /// In-module initializer — same as the public one plus the internal
    /// logger. `logger` has no default so the two stay unambiguous.
    init(transport: any Transport, workflows: WorkflowsAPI, logger: Logger?) {
        self.transport = transport
        self.workflows = workflows
        self.logger = logger
    }

    // MARK: - Poll schedule (waitFor)

    /// The JS client's schedule: 400 ms doubling to 5 s, a 15-minute default.
    static let waitMinInterval: TimeInterval = 0.4
    static let waitMaxInterval: TimeInterval = 5
    static let waitDefaultTimeout: TimeInterval = 15 * 60

    /// Test seams: the clock the deadline is measured on and the sleep the
    /// schedule waits with. A hermetic test installs a fake clock that a fake
    /// sleep advances, so the schedule's arithmetic (doubling, saturation, the
    /// clamp, the bounded finalization re-check) is pinned exactly and in no
    /// real time. Never set in production code.
    var clockForTest: (@Sendable () -> Date)?
    var sleepForTest: (@Sendable (TimeInterval) async throws -> Void)?

    private func now() -> Date { clockForTest?() ?? Date() }

    private func sleep(_ seconds: TimeInterval) async throws {
        if let sleepForTest {
            try await sleepForTest(seconds)
            return
        }
        try await Task.sleep(nanoseconds: UInt64(Swift.max(0, seconds) * 1_000_000_000))
    }

    // MARK: - invoke (request functions)

    /// Invoke a request function and wait for its result.
    ///
    /// `input` is named for what it is on this side of the wire; it travels
    /// as the envelope's `rootInput`. It stays `[String: Any]` and is
    /// serialized directly, so an `Int64` past 2^53 reaches the wire exactly
    /// (the `workflows.start` rule); `[:]` sends `rootInput: {}`. `timeout` is
    /// seconds here and `timeoutMs` on the wire — the platform default is 5 s
    /// and the ceiling 30 s; nil, zero or negative omits it. `meta` is passed
    /// through unvalidated; the server's 1 KB limit is its `400 INVALID_META`.
    ///
    /// A settled invocation never throws, whatever its `status`. A platform
    /// refusal (access, disabled, unpushed, rate, unknown key) throws an
    /// `HttpError` with the server's `errorCode` on `serverCode`. Calling this
    /// on a TASK function throws `.functionModeMismatch` — the server answered
    /// a start envelope, which promises none of what this method's type does.
    public func invoke(
        _ functionKey: String,
        input: [String: Any] = [:],
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> FunctionInvokeResult {
        try await invokeRequest(
            functionKey: functionKey,
            rootInput: input,
            contextDocId: contextDocId,
            meta: meta,
            timeout: timeout
        )
    }

    /// Typed `invoke`: an `Encodable` input, `output` decoded into `Output`.
    /// The binding surface for generated per-key Swift types, in the shape the
    /// workflow overloads use.
    ///
    /// The input is encoded once and sent as the JSON value it produces —
    /// object, array, string, number or boolean — unchanged, exactly as the JS
    /// client forwards `input`. A function whose schema declares an array or
    /// scalar root receives that. This is where the port deliberately does
    /// NOT follow `WorkflowsAPI`, whose `rootInput` is always an object: a
    /// non-object lowered to `{}` would silently change what the function
    /// runs. A `nil` input omits `rootInput` (the server supplies `{}`); an
    /// input that fails to encode throws `.invalidArgument` before any request
    /// is made.
    public func invoke<Input: Encodable, Output: Decodable & Sendable>(
        _ functionKey: String,
        input: Input?,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> FunctionResult<Output> {
        let rootInput = try Self.encodeInput(input)
        let untyped = try await invokeRequest(
            functionKey: functionKey,
            rootInput: rootInput,
            contextDocId: contextDocId,
            meta: meta,
            timeout: timeout
        )
        return FunctionResult(
            status: untyped.status,
            output: try Self.decodeTypedOutput(untyped.output),
            error: untyped.error,
            errorCode: untyped.errorCode,
            limits: untyped.limits
        )
    }

    // MARK: - start (task functions)

    /// Start a task function and get its run id back.
    ///
    /// Same route as `invoke`; the MODE decides what it answers. The run is
    /// polled on exactly the routes a DSL workflow run is (`getStatus`,
    /// `waitFor`, `terminate` below). `runKey` makes the start idempotent per
    /// `(caller, contextDocId, runKey)`: a repeat answers the run that already
    /// exists with `existing == true`, never a second run. There is no
    /// `forceRerun` and no `timeoutMs` on this route.
    ///
    /// Calling this on a REQUEST function throws `.functionModeMismatch` — the
    /// function ran and answered its result, so there is no run to poll.
    @discardableResult
    public func start(
        _ functionKey: String,
        input: [String: Any] = [:],
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil
    ) async throws -> FunctionStartResult {
        try await startRequest(
            functionKey: functionKey,
            rootInput: input,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta
        )
    }

    /// Typed `start`: an `Encodable` input sent as the JSON value it encodes
    /// to, under the same rules as the typed `invoke`. The start envelope is
    /// not output-typed on either client, so only the input is generic here.
    @discardableResult
    public func start<Input: Encodable>(
        _ functionKey: String,
        input: Input?,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil
    ) async throws -> FunctionStartResult {
        let rootInput = try Self.encodeInput(input)
        return try await startRequest(
            functionKey: functionKey,
            rootInput: rootInput,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta
        )
    }

    // MARK: - getStatus / waitFor (by run id)

    /// The current status of a function run, by run id. Same route and same
    /// flattened envelope as `workflows.getStatus` — a function run IS a run
    /// row. Throws `.invalidArgument` for an empty `runId`.
    public func getStatus(runId: String) async throws -> WorkflowStatusResult {
        guard !runId.isEmpty else {
            throw JsBaoError(code: .invalidArgument, message: "runId is required for functions.getStatus")
        }
        return try await workflows.getStatusByRunId(runId: runId)
    }

    /// Typed `getStatus`: `output` decoded into `Output`.
    public func getStatus<Output: Decodable & Sendable>(runId: String) async throws -> WorkflowStatus<Output> {
        let untyped = try await getStatus(runId: runId)
        return WorkflowStatus(
            status: untyped.status,
            output: try Self.decodeTypedOutput(untyped.output),
            error: untyped.error,
            run: untyped.run,
            skipReason: untyped.skipReason
        )
    }

    /// Wait for a function run to reach a terminal state.
    ///
    /// POLLS, where `workflows.waitFor` waits on a `workflowStatus` frame. A
    /// function run broadcasts nothing over the socket, so a delegate to the
    /// workflow method would reconcile once, see `running`, and wait out its
    /// whole timeout with nothing left to wake it. The interval starts at
    /// 0.4 s and doubles to 5 s, the last sleep is clamped to what is left of
    /// the budget, and one poll is taken at the deadline itself before the
    /// wait throws `.workflowWaitTimeout` — giving up as soon as the next
    /// interval would overshoot gave up to a whole interval back. The default
    /// timeout is 15 minutes; 0 or a negative value disables it.
    ///
    /// Terminal: `completed`, `failed`, `terminated`, `skipped`,
    /// `apply_pending`, `apply_claimed`. A failed run RESOLVES with
    /// `status == "failed"`; it does not throw. A 404 and a run reporting
    /// `missing` throw `.notFound` (a `missing` run never reaches a terminal
    /// state — the same reading `workflows.waitFor` takes). A transient error
    /// between polls is retried, not surfaced. A run whose record already
    /// reads terminal while the status block still reports the execution
    /// (the finalization window) is re-checked on the short timer
    /// `workflows.waitFor` uses and settles from the record after the bounded
    /// re-check. Cancelling the surrounding `Task` throws `CancellationError`
    /// promptly and stops polling.
    public func waitFor(
        runId: String,
        options: WaitForWorkflowOptions? = nil
    ) async throws -> WaitForWorkflowResult {
        guard !runId.isEmpty else {
            throw JsBaoError(code: .invalidArgument, message: "runId is required for functions.waitFor")
        }
        let timeout = options?.timeout ?? Self.waitDefaultTimeout
        let unbounded = !(timeout > 0 && timeout.isFinite)
        let deadline: Date? = unbounded ? nil : now().addingTimeInterval(timeout)
        let timeoutMs = timeout.wholeMilliseconds

        var delay = Self.waitMinInterval
        while true {
            try Task.checkCancellation()
            let status: WorkflowStatusResult?
            do {
                status = try await getStatus(runId: runId)
            } catch {
                // A 404 means the run is unknown or not readable by this
                // caller — fail now. Anything else is transient: the next
                // poll, or the timeout, still covers the wait.
                if WorkflowsAPI.isNotFound(error) {
                    throw JsBaoError(code: .notFound, message: "Workflow run \(runId) not found")
                }
                if error is CancellationError { throw error }
                logger?.debug("[functions.waitFor] poll failed; retrying", [
                    "runId": runId, "error": String(describing: error),
                ])
                status = nil
            }
            if let status {
                if let terminal = WorkflowsAPI.terminalFromReconcile(status) { return terminal }
                if status.status == "missing" {
                    throw JsBaoError(
                        code: .notFound,
                        message: "Workflow run \(runId) is no longer resolvable (status: missing)"
                    )
                }
                if let settled = try await recheckFinalizationWindow(
                    runId: runId, first: status, deadline: deadline, timeoutMs: timeoutMs
                ) {
                    return settled
                }
            }
            let remaining = deadline.map { $0.timeIntervalSince(now()) }
            if let remaining, remaining <= 0 {
                // Same code the workflow wait raises: it is the same fact about
                // the same kind of run.
                throw JsBaoError(
                    code: .workflowWaitTimeout,
                    message: "functions.waitFor timed out after \(timeoutMs)ms waiting for run \(runId)"
                )
            }
            let sleepFor = remaining.map { Swift.min(delay, $0) } ?? delay
            try await sleep(sleepFor)
            delay = Swift.min(delay * 2, Self.waitMaxInterval)
        }
    }

    /// Typed `waitFor`: `output` decoded into `Output`, nil when absent.
    public func waitFor<Output: Decodable & Sendable>(
        runId: String,
        as outputType: Output.Type,
        options: WaitForWorkflowOptions? = nil
    ) async throws -> WaitForResult<Output> {
        let base = try await waitFor(runId: runId, options: options)
        return WaitForResult(
            status: base.status,
            output: try Self.decodeTypedOutput(base.output),
            error: base.error,
            skipReason: base.skipReason
        )
    }

    // MARK: - terminate (the alias)

    /// Terminate a running function run. The function key goes in the
    /// workflow-key slot: the request is `workflows.terminate`'s, byte for
    /// byte, and so is the answer.
    public func terminate(_ ref: FunctionRunRef) async throws -> WorkflowStatusResult {
        try await workflows.terminate(
            workflowKey: ref.functionKey,
            runKey: ref.runKey,
            contextDocId: ref.contextDocId
        )
    }

    /// Typed `terminate`: a terminated run can carry partial output, decoded
    /// into `Output`.
    public func terminate<Output: Decodable & Sendable>(_ ref: FunctionRunRef) async throws -> WorkflowStatus<Output> {
        try await workflows.terminate(
            workflowKey: ref.functionKey,
            runKey: ref.runKey,
            contextDocId: ref.contextDocId
        )
    }

    // MARK: - The one route, and the mode check

    /// The one place an invoke body is composed and its answer classified.
    private func invokeRequest(
        functionKey: String,
        rootInput: Any?,
        contextDocId: String?,
        meta: [String: Any]?,
        timeout: TimeInterval?
    ) async throws -> FunctionInvokeResult {
        var payload: [String: Any] = [:]
        if let rootInput { payload["rootInput"] = rootInput }
        if let contextDocId { payload["contextDocId"] = contextDocId }
        if let meta { payload["meta"] = meta }
        // Seconds on this side (the #2367 convention), `timeoutMs` on the wire.
        if let timeout, timeout > 0 {
            payload["timeoutMs"] = timeout.wholeMilliseconds
        }
        let envelope = try await post(functionKey: functionKey, payload: payload)

        // The route is one route and the MODE decides what it answers. A task
        // function answers the start envelope, which has no `output` and no
        // terminal `status` — everything this method's return type promises.
        // Say so, in the mode words the config key and the docs use.
        if let runId = envelope.runId, envelope.runKey != nil {
            throw JsBaoError(
                code: .functionModeMismatch,
                message: "Function '\(functionKey)' is a task function: it starts a RUN rather than returning a result. "
                    + "Call functions.start(key, …) and poll with functions.getStatus / functions.waitFor.",
                details: ["functionKey": .string(functionKey), "runId": .string(runId)]
            )
        }
        return FunctionInvokeResult(
            status: envelope.status ?? "",
            output: envelope.output,
            error: envelope.error,
            errorCode: envelope.errorCode,
            limits: envelope.limits
        )
    }

    /// The one place a start body is composed and its answer classified.
    private func startRequest(
        functionKey: String,
        rootInput: Any?,
        runKey: String?,
        contextDocId: String?,
        meta: [String: Any]?
    ) async throws -> FunctionStartResult {
        var payload: [String: Any] = [:]
        if let rootInput { payload["rootInput"] = rootInput }
        if let runKey { payload["runKey"] = runKey }
        if let contextDocId { payload["contextDocId"] = contextDocId }
        if let meta { payload["meta"] = meta }
        let envelope = try await post(functionKey: functionKey, payload: payload)

        // The mirror of the check in `invoke`: a request function ran and
        // answered with its RESULT, so there is no run id to poll.
        guard let runId = envelope.runId, let runKey = envelope.runKey else {
            throw JsBaoError(
                code: .functionModeMismatch,
                message: "Function '\(functionKey)' is a request function: it returns a result rather than starting a run. "
                    + "Call functions.invoke(key, …) instead.",
                details: [
                    "functionKey": .string(functionKey),
                    "status": envelope.status.map(JSONValue.string) ?? .null,
                ]
            )
        }
        return FunctionStartResult(
            runId: runId,
            runKey: runKey,
            instanceId: envelope.instanceId,
            status: envelope.status ?? "",
            existing: envelope.existing,
            output: envelope.output,
            error: envelope.error
        )
    }

    /// `POST /functions/{key}`, the body serialized directly from the `Any`
    /// graph so opaque caller data (`rootInput`, `meta`) reaches the wire as
    /// spelled. The answer is decoded into the union of both envelopes; the
    /// callers above decide which one they were handed.
    private func post(functionKey: String, payload: [String: Any]) async throws -> FunctionRouteEnvelope {
        let encodedKey = URLEncoding.encodeComponent(functionKey)
        let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [])
        return try await transport.request(
            method: .post,
            path: "/functions/\(encodedKey)",
            bodyData: bodyData
        )
    }

    /// Encode a typed input into the JSON value it produces — any JSON type,
    /// not just an object — for the `rootInput` slot. `nil` means "no
    /// input", which omits the field. An input that fails to encode is the
    /// caller's mistake, reported before any request goes out.
    private static func encodeInput<Input: Encodable>(_ input: Input?) throws -> Any? {
        guard let input else { return nil }
        do {
            return try JSONCoding.jsonObject(from: input)
        } catch {
            throw JsBaoError(
                code: .invalidArgument,
                message: "functions: input could not be encoded as JSON: \(error)"
            )
        }
    }

    /// Decode the opaque `output` blob into the typed `Output`. An absent or
    /// `.null` output maps to `nil`.
    private static func decodeTypedOutput<Output: Decodable>(_ value: JSONValue?) throws -> Output? {
        guard let value, !value.isNull else { return nil }
        let any = try JSONCoding.jsonObject(from: value)
        return try JSONCoding.decode(Output.self, from: any)
    }

    /// The finalization window: the run record already reads terminal while
    /// the status block still reports the execution in flight, because the
    /// server withholds `completed` until the output is published. Re-check on
    /// the short timer `workflows.waitFor` uses; settle from the record after
    /// the bounded re-check rather than polling on. Returns `nil` when the
    /// first response is not in the window.
    private func recheckFinalizationWindow(
        runId: String,
        first: WorkflowStatusResult,
        deadline: Date?,
        timeoutMs: Int
    ) async throws -> WaitForWorkflowResult? {
        var res = first
        var attempts = 0
        while let stored = WorkflowsAPI.finalizingTerminalStatus(res) {
            if attempts >= WorkflowsAPI.finalizeMaxRechecks {
                return WaitForWorkflowResult(
                    status: stored,
                    output: res.output,
                    error: res.error,
                    skipReason: res.skipReason
                )
            }
            attempts += 1
            if let deadline, deadline.timeIntervalSince(now()) <= 0 {
                throw JsBaoError(
                    code: .workflowWaitTimeout,
                    message: "functions.waitFor timed out after \(timeoutMs)ms waiting for run \(runId)"
                )
            }
            try await sleep(TimeInterval(WorkflowsAPI.finalizeRecheckIntervalMs) / 1000)
            do {
                res = try await getStatus(runId: runId)
            } catch {
                if WorkflowsAPI.isNotFound(error) {
                    throw JsBaoError(code: .notFound, message: "Workflow run \(runId) not found")
                }
                if error is CancellationError { throw error }
                continue
            }
            if let terminal = WorkflowsAPI.terminalFromReconcile(res) { return terminal }
        }
        return nil
    }
}

// MARK: - Route envelope

/// The union of what `POST /functions/{key}` can answer: the invoke envelope
/// (`status` / `output` / `error` / `errorCode` / `limits`) or the workflow
/// start envelope (`runId` / `runKey` / `instanceId` / `status` /
/// `existing`). `runId` + `runKey` is the discriminator: the request path
/// writes no run row precisely so that there is nothing to poll, so a run id
/// on this route means a task start and nothing else.
private struct FunctionRouteEnvelope: Decodable, Sendable {
    let status: String?
    let output: JSONValue?
    let error: String?
    let errorCode: String?
    let limits: FunctionInvokeLimits?
    let runId: String?
    let runKey: String?
    let instanceId: String?
    let existing: Bool?

    private enum CodingKeys: String, CodingKey {
        case status, output, error, errorCode, limits, runId, runKey, instanceId, existing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        // A present-but-null `output` is `.null`, not absent: `decodeIfPresent`
        // would fold the two together, and the untyped envelope keeps them
        // apart (the typed overloads map both to `nil`).
        // Spelled as a statement, not a `?:` with a `nil` arm: `JSONValue` is
        // `ExpressibleByNilLiteral`, so that arm would have been `.null`.
        if c.contains(.output) {
            output = try c.decode(JSONValue.self, forKey: .output)
        } else {
            output = nil
        }
        error = try c.decodeIfPresent(String.self, forKey: .error)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        limits = try c.decodeIfPresent(FunctionInvokeLimits.self, forKey: .limits)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        runKey = try c.decodeIfPresent(String.self, forKey: .runKey)
        instanceId = try c.decodeIfPresent(String.self, forKey: .instanceId)
        existing = try c.decodeIfPresent(Bool.self, forKey: .existing)
    }
}
