import Foundation

// MARK: - WorkflowsAPI

/// Workflow execution + apply-flow client. Mirrors the JS client's
/// `workflows` API surface (start / getStatus / terminate / listRuns plus
/// the apply lifecycle: claimApply / confirmApply / releaseApply /
/// getPendingApplies and the high-level `define(...)` registration).
///
/// The apply flow exists because workflows defined with
/// `requiresClientApply: true` (the default) park in the `apply_pending`
/// state when execution finishes. The server has the output but waits for
/// a client to "apply" it — the client claims a 30s lease, runs its
/// `onApply` handler, and then confirms (or releases on error so another
/// client can retry). `JsBaoClient` calls `handleApplyEvent` automatically
/// when a `workflowStatus` WS message arrives with `needsApply = true`.
public final class WorkflowsAPI: @unchecked Sendable {
    private let transport: any Transport
    private let getConnectionId: () -> String
    private let logger: Logger?

    /// The client's shared event emitter. `waitFor` subscribes to the
    /// `.workflowStatus` and `.status` events through it (mirroring the JS
    /// self-contained `waitFor`). Optional so the API can still be constructed
    /// standalone in unit tests that don't exercise `waitFor` — those pass a
    /// real emitter when they do.
    private let events: EventEmitter?

    /// Registered apply handlers, keyed by `workflowKey`. Protected by
    /// `handlersLock` so `define` and `handleApplyEvent` can be called from
    /// any thread.
    private var applyHandlers: [String: WorkflowApplyHandler] = [:]

    private let handlersLock = NSLock()

    /// Designated initializer — the typed transport spine.
    ///
    /// The client's logger is module-internal (#2363), so it is not a
    /// parameter here; the internal overload below carries it for
    /// `JsBaoClient`'s own construction.
    public convenience init(
        transport: any Transport,
        getConnectionId: @escaping () -> String = { "" },
        events: EventEmitter? = nil
    ) {
        self.init(
            transport: transport,
            getConnectionId: getConnectionId,
            logger: nil,
            events: events
        )
    }

    /// In-module initializer — same as the public one plus the internal
    /// logger. `logger` deliberately has no default value: that is what keeps
    /// `WorkflowsAPI(transport:)` unambiguous between the two.
    init(
        transport: any Transport,
        getConnectionId: @escaping () -> String = { "" },
        logger: Logger?,
        events: EventEmitter? = nil
    ) {
        self.transport = transport
        self.getConnectionId = getConnectionId
        self.logger = logger
        self.events = events
    }

    /// Deprecated: construct with a `Transport` instead. The legacy closure is
    /// wrapped in an adapter so existing call sites keep working for one major
    /// cycle.
    @available(*, deprecated, message: "Use init(transport:) — the untyped makeRequest closure is removed in the next major release.")
    public convenience init(
        makeRequest: @escaping (String, String, Any?) async throws -> Any,
        getConnectionId: @escaping () -> String = { "" },
        events: EventEmitter? = nil
    ) {
        self.init(
            transport: ClosureTransport(makeRequest: makeRequest),
            getConnectionId: getConnectionId,
            logger: nil,
            events: events
        )
    }

    // MARK: - Workflow Execution

    /// Starts a workflow execution.
    ///
    /// - Parameters:
    ///   - workflowKey: The workflow identifier (e.g. "analyze-text").
    ///   - input: Input data passed to the workflow.
    ///   - options: Optional start options (runKey for idempotency, contextDocId, meta).
    /// - Returns: Result containing runId, runKey, status, and whether an existing run was returned.
    ///
    /// Now typed: returns a decoded `StartWorkflowResult` (#954). Throws on a
    /// response shape mismatch instead of coercing to `[:]` (#991). `input`
    /// stays `[String: Any]` — it is the opaque `rootInput` blob the server
    /// does not introspect.
    @discardableResult
    public func start(
        workflowKey: String,
        input: [String: Any],
        options: StartWorkflowOptions? = nil
    ) async throws -> StartWorkflowResult {
        let encodedKey = URLEncoding.encodeComponent(workflowKey)
        // `input` and `meta` are opaque caller data the server does not
        // introspect and the client cannot interpret — so they are serialized
        // directly rather than routed through `JSONValue`, whose single
        // `.number(Double)` case loses exactness past 2^53. `JSONSerialization`
        // writes an `Int64` exactly, which is what the untyped body did.
        var payload: [String: Any] = ["rootInput": input]
        if let runKey = options?.runKey { payload["runKey"] = runKey }
        if let contextDocId = options?.contextDocId { payload["contextDocId"] = contextDocId }
        if let meta = options?.meta { payload["meta"] = meta }
        if options?.forceRerun == true { payload["forceRerun"] = true }
        let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [])

        // No local `workflowStarted` emit here (#1112): JS emits the event
        // exclusively from the server-pushed `workflowStarted` WS frame
        // (handled in `JsBaoClient.handleWebSocketMessage`), so emitting
        // from the HTTP start path too produced a double emit per start.
        return try await transport.request(
            method: .post,
            path: "/workflows/\(encodedKey)/start",
            bodyData: bodyData
        )
    }

    /// Options-struct overload of `start`, mirroring js-bao's single
    /// options-object call (`start({ workflowKey, input, runKey,
    /// contextDocId, meta, forceRerun })`). `workflowKey` and `input` ride in
    /// the options object rather than as separate positional parameters.
    @discardableResult
    public func start(_ options: StartWorkflowOptions) async throws -> StartWorkflowResult {
        try await start(
            workflowKey: options.workflowKey,
            input: options.input,
            options: options
        )
    }

    /// Synchronously run a workflow and wait for its terminal status (#728/#956).
    /// Mirrors js-bao's `workflows.runSync`. The result envelope carries the
    /// terminal `status` (`completed`/`failed`/`terminated`/`timeout`/
    /// `apply_pending`); only transport/connectivity errors throw.
    ///
    /// - Parameter timeoutMs: hard wall-clock ceiling (default server-side
    ///   5000, capped at 30000). On exceed the run resolves with
    ///   `status == "timeout"`.
    ///
    /// (Swift omits the JS `AbortSignal` — the JS transport doesn't wire it
    /// through either; cancel via the surrounding `Task` and read final state
    /// with `getStatus` if needed.)
    public func runSync(
        workflowKey: String,
        input: [String: Any] = [:],
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        timeoutMs: Int? = nil
    ) async throws -> RunSyncWorkflowResult {
        let encodedKey = URLEncoding.encodeComponent(workflowKey)
        // Same reasoning as `start`: `input`/`meta` are opaque caller data, so
        // the bytes are composed here rather than passed through `JSONValue`.
        var payload: [String: Any] = ["rootInput": input]
        if let runKey { payload["runKey"] = runKey }
        if let contextDocId { payload["contextDocId"] = contextDocId }
        if let meta { payload["meta"] = meta }
        if let timeoutMs, timeoutMs > 0 { payload["timeoutMs"] = timeoutMs }
        let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [])
        return try await transport.request(
            method: .post,
            path: "/workflows/\(encodedKey)/run-sync",
            bodyData: bodyData
        )
    }

    /// Gets the status of a workflow run. Mirrors the JS client's
    /// `getStatus` — returns a decoded `WorkflowStatusResult` (#954) whose
    /// `status` is the server's reconciled run status and `run` is the DB
    /// record. Throws on a response shape mismatch instead of coercing to `[:]`
    /// (#991).
    ///
    /// #2348: the server now returns ONE canonical status on the wire — one of
    /// `queued`, `running`, `apply_pending`, `apply_claimed`, `completed`,
    /// `failed`, `terminated`, `missing`. Raw Cloudflare spellings (`complete`,
    /// `errored`) never reach the client, and the server never rolls a terminal
    /// run back to `running`, so the client passes `status` through verbatim
    /// instead of re-deriving it from the run row.
    public func getStatus(
        workflowKey: String,
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatusResult {
        let encodedKey = URLEncoding.encodeComponent(workflowKey)
        let encodedRunKey = URLEncoding.encodeComponent(runKey)
        var query = URLQuery()
        query.appendIfPresent("contextDocId", contextDocId)
        let path = "/workflows/\(encodedKey)/instances/\(encodedRunKey)/status\(query.queryString)"
        return try await transport.request(method: .get, path: path)
    }

    // MARK: - Typed generic overloads (#1547)
    //
    // The published SDK surface for the CLI-generated typed workflow invoker
    // (`primitive workflows codegen --lang swift`). The generated per-workflow
    // factory binds `<Key>Input`/`<Key>Output` over these; only THESE overloads
    // are library surface (the generated invoker structs are app-target code).
    // Each delegates to the untyped method above — encoding the `Codable` input
    // into the opaque `rootInput` object and decoding the opaque `output` blob
    // into `Output` — so no request/response behavior diverges from the untyped
    // path. `input` is optional so an omitted input sends `{}` (parity with the
    // JS client's `input ?? {}`).

    /// Synchronously run a workflow with a typed `Codable` input and a typed
    /// `Output`. Mirrors the JS `runSync<I, O>`. Returns a `RunSyncResult<Output>`
    /// whose `output` is decoded into `Output`; only transport errors throw.
    public func runSync<Input: Encodable, Output: Decodable & Sendable>(
        workflowKey: String,
        input: Input?,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        timeoutMs: Int? = nil
    ) async throws -> RunSyncResult<Output> {
        let encoded = try Self.encodeInputObject(input)
        let untyped = try await runSync(
            workflowKey: workflowKey,
            input: encoded,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta,
            timeoutMs: timeoutMs
        )
        return RunSyncResult(
            runId: untyped.runId,
            runKey: untyped.runKey,
            status: untyped.status,
            output: try Self.decodeTypedOutput(untyped.output),
            error: untyped.error,
            run: untyped.run,
            existing: untyped.existing
        )
    }

    /// Start a workflow with a typed `Codable` input. Mirrors the JS
    /// `start<I>` — the start result (`StartWorkflowResult`) is not output-typed
    /// on either client, so only the input is generic here.
    @discardableResult
    public func start<Input: Encodable>(
        workflowKey: String,
        input: Input?,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        forceRerun: Bool? = nil
    ) async throws -> StartWorkflowResult {
        let encoded = try Self.encodeInputObject(input)
        let options = StartWorkflowOptions(
            workflowKey: workflowKey,
            input: encoded,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta,
            forceRerun: forceRerun
        )
        return try await start(
            workflowKey: workflowKey,
            input: encoded,
            options: options
        )
    }

    /// Fetch a run's status with a typed `output` bound to `Output`. Mirrors the
    /// JS `getStatus<O>`. Returns a `WorkflowStatus<Output>` whose `output` is
    /// decoded into `Output`.
    public func getStatus<Output: Decodable & Sendable>(
        workflowKey: String,
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatus<Output> {
        let untyped = try await getStatus(
            workflowKey: workflowKey,
            runKey: runKey,
            contextDocId: contextDocId
        )
        return WorkflowStatus(
            status: untyped.status,
            output: try Self.decodeTypedOutput(untyped.output),
            error: untyped.error,
            run: untyped.run
        )
    }

    /// Encode a typed `Codable` input into the `[String: Any]` object the
    /// server takes as `rootInput`. A `nil` input (optional-input workflow with
    /// no argument) sends `{}`; a non-object encoding also falls back to `{}`
    /// (the server's `rootInput` is always an object), matching the untyped
    /// `input: [String: Any] = [:]` contract.
    private static func encodeInputObject<Input: Encodable>(
        _ input: Input?
    ) throws -> [String: Any] {
        guard let input else { return [:] }
        let any = try JSONCoding.jsonObject(from: input)
        return (any as? [String: Any]) ?? [:]
    }

    /// Decode the opaque `output` blob into the typed `Output`. An absent or
    /// `.null` output maps to `nil` (no typed output to surface).
    private static func decodeTypedOutput<Output: Decodable>(
        _ value: JSONValue?
    ) throws -> Output? {
        guard let value, !value.isNull else { return nil }
        let any = try JSONCoding.jsonObject(from: value)
        return try JSONCoding.decode(Output.self, from: any)
    }

    /// Terminates a running workflow.
    ///
    /// - Parameter contextDocId: optional doc-scope for the terminate
    ///   call (matches js-bao's `terminate(opts: {workflowKey, runKey,
    ///   contextDocId})`). Required for workflows that were started with a
    ///   `contextDocId` so the server can route to the right per-doc DO.
    /// Now typed: returns a decoded `WorkflowStatusResult` (#954), matching
    /// the JS `terminate` return. Throws on a response shape mismatch instead
    /// of coercing to `[:]` (#991).
    public func terminate(
        workflowKey: String,
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatusResult {
        let encodedKey = URLEncoding.encodeComponent(workflowKey)
        let encodedRunKey = URLEncoding.encodeComponent(runKey)
        var query = URLQuery()
        query.appendIfPresent("contextDocId", contextDocId)
        let path = "/workflows/\(encodedKey)/instances/\(encodedRunKey)/terminate\(query.queryString)"
        return try await transport.request(method: .post, path: path)
    }

    /// Options-struct overload of `terminate`, mirroring js-bao's single
    /// options-object call (`terminate({ workflowKey, runKey, contextDocId })`).
    /// `contextDocId` rides in the options object rather than as a third
    /// positional parameter.
    @discardableResult
    public func terminate(_ options: TerminateWorkflowOptions) async throws -> WorkflowStatusResult {
        try await terminate(
            workflowKey: options.workflowKey,
            runKey: options.runKey,
            contextDocId: options.contextDocId
        )
    }

    /// List the per-step runs of a single workflow run. Useful for
    /// debugging UIs that want to surface the apply-pending /
    /// apply-applied state of each step.
    ///
    /// Now typed: returns a decoded `ListWorkflowStepRunsResult` (#954) —
    /// throws on a response shape mismatch instead of coercing to `[:]`
    /// (#991).
    public func listStepRuns(runId: String) async throws -> ListWorkflowStepRunsResult {
        let encoded = URLEncoding.encodeComponent(runId)
        return try await transport.request(method: .get, path: "/workflows/runs/\(encoded)/steps")
    }

    /// Lists workflow runs with optional filtering and pagination.
    ///
    /// Now typed: returns a decoded `ListWorkflowRunsResult` (#954) — throws
    /// on a response shape mismatch instead of coercing to `[:]` (#991). The
    /// existing filters (`workflowKey`, `status`, `limit`, `cursor`,
    /// `forward`, `contextDocId`) are preserved.
    public func listRuns(options: ListWorkflowRunsOptions? = nil) async throws -> ListWorkflowRunsResult {
        var query = URLQuery()
        query.appendIfPresent("workflowKey", options?.workflowKey)
        query.appendIfPresent("status", options?.status)
        if let limit = options?.limit {
            query.append("limit", limit)
        }
        query.appendIfPresent("cursor", options?.cursor)
        if let forward = options?.forward {
            query.append("forward", forward ? "true" : "false")
        }
        query.appendIfPresent("contextDocId", options?.contextDocId)
        return try await transport.request(method: .get, path: "/workflows/runs\(query.queryString)")
    }

    // MARK: - Apply Flow

    /// Claim the apply lease for a workflow run that's parked in
    /// `apply_pending`. The server transitions the run to `apply_claimed`
    /// for 30 seconds; while the lease is held, no other client can claim
    /// it. Returns `claimed: false` (with a `reason`) if another client
    /// already holds the lease, the run isn't in an apply-pending state,
    /// etc. — see the JS client docs for the full reason taxonomy.
    ///
    /// Now typed: returns a decoded `ClaimApplyResult` (#954) — throws on a
    /// response shape mismatch instead of coercing to `[:]` (#991).
    public func claimApply(
        workflowKey: String,
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> ClaimApplyResult {
        let encodedKey = URLEncoding.encodeComponent(workflowKey)
        let encodedRunKey = URLEncoding.encodeComponent(runKey)
        let payload = ApplyPayload(connectionId: getConnectionId(), contextDocId: contextDocId)
        return try await transport.request(
            method: .post,
            path: "/workflows/\(encodedKey)/instances/\(encodedRunKey)/claim-apply",
            body: payload
        )
    }

    /// Confirm a previously-claimed apply. The server transitions the run
    /// from `apply_claimed` to `completed`. Conditional on the same
    /// `connectionId` that called `claimApply` — `not_claimed_by_you` is
    /// returned if the lease was reclaimed by another connection.
    ///
    /// Now typed: returns a decoded `ConfirmApplyResult` (#954) — throws on a
    /// response shape mismatch instead of coercing to `[:]` (#991).
    public func confirmApply(
        workflowKey: String,
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> ConfirmApplyResult {
        let encodedKey = URLEncoding.encodeComponent(workflowKey)
        let encodedRunKey = URLEncoding.encodeComponent(runKey)
        let payload = ApplyPayload(connectionId: getConnectionId(), contextDocId: contextDocId)
        return try await transport.request(
            method: .post,
            path: "/workflows/\(encodedKey)/instances/\(encodedRunKey)/confirm-apply",
            body: payload
        )
    }

    /// Release a previously-claimed apply, sending the run back to
    /// `apply_pending` so another client (or a retry) can claim it.
    /// Conditional on the claiming `connectionId`.
    ///
    /// Now typed: returns a decoded `ReleaseApplyResult` (#954) — throws on a
    /// response shape mismatch instead of coercing to `[:]` (#991).
    public func releaseApply(
        workflowKey: String,
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> ReleaseApplyResult {
        let encodedKey = URLEncoding.encodeComponent(workflowKey)
        let encodedRunKey = URLEncoding.encodeComponent(runKey)
        let payload = ApplyPayload(connectionId: getConnectionId(), contextDocId: contextDocId)
        return try await transport.request(
            method: .post,
            path: "/workflows/\(encodedKey)/instances/\(encodedRunKey)/release-apply",
            body: payload
        )
    }

    /// Fetch the list of workflow runs that are currently in
    /// `apply_pending` (or `apply_claimed` with an expired lease) for a
    /// given context document. Useful for reconnecting clients to recover
    /// applies that arrived while the client was offline.
    ///
    /// Now typed: returns `[PendingApplyInfo]` (#954). The JS surface types
    /// this as `any[]`; the Swift surface decodes the run-shaped fields the
    /// apply flow reads while keeping the rest opaque. Throws on a shape
    /// mismatch in the `pendingApplies` envelope instead of silently
    /// dropping rows (#991).
    public func getPendingApplies(contextDocId: String) async throws -> [PendingApplyInfo] {
        var query = URLQuery()
        query.append("contextDocId", contextDocId)
        let response: PendingAppliesResponse? = try await transport.requestOptional(
            method: .get,
            path: "/workflows/pending-applies\(query.queryString)"
        )
        return response?.items ?? []
    }

    // MARK: - High-Level Define API

    /// Register an apply handler for a workflow key. When a
    /// `workflowStatus` event arrives with `needsApply = true` for this
    /// key, the client automatically claims the lease, fetches the
    /// workflow output via `getStatus`, calls the handler, and then
    /// confirms the apply. If the handler throws, the claim is released
    /// so another client (or a retry) can pick it up.
    ///
    /// Mirrors the JS client's `client.workflows.define(workflowKey, { onApply })`.
    public func define(_ workflowKey: String, onApply: @escaping WorkflowApplyHandler) {
        handlersLock.lock()
        defer { handlersLock.unlock() }
        applyHandlers[workflowKey] = onApply
    }

    // MARK: - waitFor (#1443 / #1582)

    /// Wait for a workflow run to reach a terminal state — robustly, even across
    /// a WebSocket outage. Ports the JS client's `workflows.waitFor` (#1443).
    ///
    /// Resolves from the terminal `workflowStatus` WS frame with zero extra HTTP
    /// when the socket is up. Because that frame is emitted once and never
    /// replayed, `waitFor` also reconciles against the runId-keyed, non-
    /// destructive `GET /workflows/runs/:runId/status` endpoint immediately after
    /// subscribing (closes the started-before-subscribed race) and again on every
    /// WS reconnect (recovers a terminal frame missed while the socket was down —
    /// the core iOS-backgrounding fix). No interval polling.
    ///
    /// A failed run RESOLVES with `status == "failed"` and the error message — it
    /// does NOT throw. Terminality comes from the server-declared status alone
    /// (#2348): `completed`, `failed`, `terminated`, `apply_pending`, or
    /// `apply_claimed`.
    ///
    /// If a reconcile lands while a run is finishing — the server reports the
    /// execution's status until the platform has published the run's `output`,
    /// while the run record already carries its terminal status — `waitFor`
    /// re-checks on a one-second timer until the status endpoint agrees, so a
    /// caller that missed the terminal frame settles in seconds rather than
    /// waiting out `timeoutMs`.
    ///
    /// Throws on three conditions: the reconcile fetch 404s (unknown or
    /// not-owned `runId` → `.notFound`), the run reports `missing` (its record
    /// no longer resolves to an execution, so it will never reach a terminal
    /// state → `.notFound`), or `timeoutMs` elapses (`.workflowWaitTimeout`).
    /// Every exit path clears the timer and cancels both event subscriptions.
    ///
    /// - Note: reconcile deliberately uses the runId-keyed status endpoint, never
    ///   the runKey-keyed `getStatus`. Keying on `runId` avoids the runKey
    ///   route's history of answering 404 for a `runSync` run.
    public func waitFor(
        runId: String,
        options: WaitForWorkflowOptions? = nil
    ) async throws -> WaitForWorkflowResult {
        guard !runId.isEmpty else {
            throw JsBaoError(code: .invalidArgument, message: "runId is required for workflows.waitFor")
        }
        guard let events = self.events else {
            throw JsBaoError(code: .unavailable, message: "workflows.waitFor requires the client event emitter")
        }

        let defaultTimeoutMs = 15 * 60 * 1000  // 15 minutes
        let timeoutMs = options?.timeoutMs ?? defaultTimeoutMs

        // Honor a caller that was already cancelled before we set anything up —
        // return promptly instead of subscribing and leaking listeners.
        if Task.isCancelled {
            throw CancellationError()
        }

        let coordinator = WaitForCoordinator()

        // withTaskCancellationHandler so a cancelled awaiting Task settles the
        // wait (throwing CancellationError) and tears down the subscriptions +
        // timer, instead of staying suspended until a terminal frame or timeout
        // — which never arrives when timeoutMs <= 0. The cancel handler routes
        // through the same single-settle `coordinator.settle(...)` path as every
        // other exit, so the continuation can never be resumed twice.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WaitForWorkflowResult, Error>) in
                // Settle exactly once: whichever of {terminal frame, reconcile,
                // timeout, cancellation} arrives first claims the resume, cancels
                // the timer, and removes both subscriptions.
                func finish(_ result: Result<WaitForWorkflowResult, Error>) {
                    coordinator.settle(result)
                }

                func reconcile() {
                    guard coordinator.beginReconcile() else { return }
                    Task { [weak self] in
                        guard let self = self else {
                            _ = coordinator.endReconcile()
                            return
                        }
                        // Coalescing loop: if a reconnect requested another
                        // reconcile while this fetch was in flight,
                        // `endReconcile()` returns true and we run exactly one
                        // more fetch (multiple requests collapse into a single
                        // pending re-run). Once the wait settles, `endReconcile()`
                        // returns false and the loop stops — no unbounded stacking
                        // of fetches, no fetch after settle.
                        repeat {
                            do {
                                if let terminal = try await self.reconcileTerminal(
                                    runId: runId,
                                    isSettled: { coordinator.isSettled }
                                ) {
                                    finish(.success(terminal))
                                }
                            } catch {
                                // A 404 means the run is unknown or not readable by
                                // this caller — fail immediately. Other
                                // (transient/network) errors are swallowed; the next
                                // frame, reconnect, or timeout still covers the wait.
                                if Self.isNotFound(error) {
                                    finish(.failure(JsBaoError(
                                        code: .notFound,
                                        message: "Workflow run \(runId) not found"
                                    )))
                                }
                            }
                        } while coordinator.endReconcile()
                    }
                }

                let workflowSub = events.subscribe(WorkflowStatusEvent.self) { event in
                    guard event.runId == runId else { return }
                    // The workflowStatus frame is only emitted on a terminal
                    // transition and carries the terminal payload directly —
                    // resolve from it with zero extra HTTP. Apply-required
                    // workflows are the one wrinkle: the server broadcasts status
                    // "completed" with needsApply true while the run row is
                    // apply_pending; map the frame to apply_pending so the event
                    // path agrees with the reconcile path. This mapping stays
                    // after #2348 — the frame is the one surface where the apply
                    // state is only recoverable from `needsApply` (the HTTP
                    // status endpoints report `apply_pending` directly).
                    let status = event.needsApply ? "apply_pending" : event.status
                    finish(.success(WaitForWorkflowResult(
                        status: status,
                        output: Self.jsonValueFromAny(event.output),
                        error: event.error
                    )))
                }

                let statusSub = events.subscribe(StatusChangedEvent.self) { event in
                    // On WS reconnect, re-run the single reconcile fetch to recover
                    // a terminal frame missed during the outage. No interval timer.
                    if event.status == .connected {
                        reconcile()
                    }
                }

                var timeoutTask: Task<Void, Never>? = nil
                // 0 (or any non-positive value) disables the timeout — the
                // listeners live until the run terminates (or the caller cancels).
                if timeoutMs > 0 {
                    timeoutTask = Task {
                        try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                        finish(.failure(JsBaoError(
                            code: .workflowWaitTimeout,
                            message: "workflows.waitFor timed out after \(timeoutMs)ms waiting for run \(runId)"
                        )))
                    }
                }

                coordinator.install(statusSub: statusSub, workflowSub: workflowSub, timeoutTask: timeoutTask)
                // Hand the continuation to the coordinator last. If a cancellation
                // already settled the wait (its handler can fire before or during
                // this closure), the continuation resumes immediately with the
                // stored result rather than suspending forever.
                coordinator.setContinuation(continuation)

                // Reconcile once at start to close the started-before-subscribed
                // race — the terminal frame may have fired before these listeners
                // attached and is never replayed.
                reconcile()
            }
        } onCancel: {
            // Cancellation settles the wait once and tears everything down via the
            // same claim path — safe even if it races the setup above.
            coordinator.settle(.failure(CancellationError()))
        }
    }

    /// Typed generic overload of `waitFor` — decodes the run's opaque `output`
    /// blob into `Output`. Mirrors the `getStatus<Output>` / `runSync<Output>`
    /// overloads. `output` is `nil` when absent or when `status != "completed"`.
    public func waitFor<Output: Decodable & Sendable>(
        runId: String,
        as outputType: Output.Type,
        options: WaitForWorkflowOptions? = nil
    ) async throws -> WaitForResult<Output> {
        let base = try await waitFor(runId: runId, options: options)
        return WaitForResult(
            status: base.status,
            output: try Self.decodeTypedOutput(base.output),
            error: base.error
        )
    }

    /// Fetch a run's status keyed by `runId` via the #1443 endpoint
    /// (`GET /workflows/runs/:runId/status`). Like `getStatus`, the server's
    /// canonical `status` is returned verbatim (#2348). A 404 surfaces as an
    /// `HttpError` (status 404) that `waitFor` maps to `.notFound`.
    internal func getStatusByRunId(runId: String) async throws -> WorkflowStatusResult {
        let encoded = URLEncoding.encodeComponent(runId)
        return try await transport.request(
            method: .get,
            path: "/workflows/runs/\(encoded)/status"
        )
    }

    /// How long the finalization re-check waits between fetches, and how many
    /// times it retries before settling from the run record (#2348).
    static let finalizeRecheckIntervalMs: UInt64 = 1000
    static let finalizeMaxRechecks = 30

    /// One reconcile fetch, plus a bounded re-check through the server's
    /// finalization window (#2348).
    ///
    /// A workflow writes its own run row terminal from inside the execution, and
    /// the platform publishes the run's `output` only once that execution
    /// returns; in between, the server deliberately reports the EXECUTION's
    /// in-flight status so a status read never carries `completed` with a `nil`
    /// output. The terminal `workflowStatus` frame fires at the start of that
    /// window and is never replayed, so a caller that missed it and reconciles
    /// inside the window has nothing left to wake it and would wait out the
    /// whole timeout. When the response's own run record says the run has ended,
    /// re-check on a short timer instead; if the execution still has not
    /// published after the window, settle from the record rather than hang.
    ///
    /// Throws `.notFound` for a `missing` run: its record no longer resolves to
    /// an execution, so it will never reach a terminal state (the CLI stops on
    /// `missing` too, and this path used to be a 404).
    private func reconcileTerminal(
        runId: String,
        isSettled: @escaping @Sendable () -> Bool
    ) async throws -> WaitForWorkflowResult? {
        var res = try await getStatusByRunId(runId: runId)
        if let terminal = Self.terminalFromReconcile(res) { return terminal }
        if res.status == "missing" {
            throw JsBaoError(
                code: .notFound,
                message: "Workflow run \(runId) is no longer resolvable (status: missing)"
            )
        }

        var attempts = 0
        while let stored = Self.finalizingTerminalStatus(res), !isSettled() {
            if attempts >= Self.finalizeMaxRechecks {
                return WaitForWorkflowResult(
                    status: stored,
                    output: res.output,
                    error: res.error
                )
            }
            attempts += 1
            try? await Task.sleep(nanoseconds: Self.finalizeRecheckIntervalMs * 1_000_000)
            if isSettled() { return nil }
            // A transient failure inside the window must not abandon the
            // re-check. The caller swallows anything that isn't `.notFound` and
            // then leaves the `repeat` loop, and inside the window nothing else
            // would wake the wait — the terminal frame fired at the start of
            // the window and is never replayed. So keep re-checking here
            // (still bounded by `finalizeMaxRechecks`) against the last good
            // response, and propagate only `.notFound`.
            do {
                res = try await getStatusByRunId(runId: runId)
            } catch {
                if Self.isNotFound(error) { throw error }
                continue
            }
            if let terminal = Self.terminalFromReconcile(res) { return terminal }
        }
        return nil
    }

    /// The run record's terminal status when the server reports a NON-terminal
    /// status for a run that has already ended — the finalization window. `nil`
    /// when the report and the record agree.
    static func finalizingTerminalStatus(_ res: WorkflowStatusResult) -> String? {
        guard !WaitForWorkflowResult.terminalStatuses.contains(res.status) else { return nil }
        guard let stored = res.run?.status else { return nil }
        return WaitForWorkflowResult.terminalStatuses.contains(stored) ? stored : nil
    }

    /// Map a reconcile response to a terminal `waitFor` result, or `nil` if the
    /// run is not yet terminal.
    ///
    /// #2348: terminality is decided by the server-declared status alone — one
    /// of `completed`, `failed`, `terminated`, `apply_pending`, `apply_claimed`.
    /// The client no longer infers a terminal state from `run.endedAt` or from
    /// the presence of `run.errorMessage`, and no longer maps raw Cloudflare
    /// spellings: the server reconciles the run before responding, so its
    /// `status` is authoritative.
    static func terminalFromReconcile(_ res: WorkflowStatusResult) -> WaitForWorkflowResult? {
        guard WaitForWorkflowResult.terminalStatuses.contains(res.status) else { return nil }
        return WaitForWorkflowResult(
            status: res.status,
            output: res.output,
            error: res.error
        )
    }

    /// Recognise a "run not found" (HTTP 404) from either error shape the status
    /// endpoint can throw: an `HttpError` with `status == 404`, or a `JsBaoError`
    /// with code `.notFound`.
    static func isNotFound(_ error: Error) -> Bool {
        if let http = error as? HttpError, http.status == 404 { return true }
        if let jsBao = error as? JsBaoError, jsBao.code == .notFound { return true }
        return false
    }

    /// Convert a raw WS-frame `Any?` payload into a `JSONValue?`. `nil`/`NSNull`
    /// map to `nil`.
    static func jsonValueFromAny(_ value: Any?) -> JSONValue? {
        guard let value, !(value is NSNull) else { return nil }
        return try? JSONCoding.decode(JSONValue.self, from: value)
    }

    /// Bridge a typed `JSONValue` output back into the `Any?` the
    /// untouchable `WorkflowApplyContext` carries. A `.null` (or absent)
    /// value maps to `nil` so handlers see "no output" rather than an
    /// `NSNull`, matching the prior `!(raw is NSNull)` guard.
    private static func outputToAny(_ value: JSONValue?) -> Any? {
        guard let value, !value.isNull else { return nil }
        return try? JSONCoding.jsonObject(from: value)
    }

    /// Bridge a typed `JSONValue` meta blob into the `[String: Any]?` the
    /// untouchable event/context structs carry. Non-object metas map to
    /// `nil` (the wire shape is always an object when present).
    private static func metaToAny(_ value: JSONValue?) -> [String: Any]? {
        guard let value, !value.isNull else { return nil }
        return (try? JSONCoding.jsonObject(from: value)) as? [String: Any]
    }

    /// Internal — invoked by `JsBaoClient` when a `workflowStatus` WS message
    /// arrives with `needsApply = true`. Looks up the per-workflowKey handler
    /// registered via `define(...)`, runs the claim → handler → confirm
    /// sequence, and releases the claim on any failure. No-op when no handler is
    /// registered for the key (the "any one client wins" model — another client
    /// with a handler applies it).
    ///
    /// (#1975: the per-run waiter branch is gone — completion waiting is now
    /// handled by the self-contained `waitFor`, which resolves at `apply_pending`
    /// without claiming/applying. `define()` and this apply flow are unchanged.)
    internal func handleApplyEvent(_ event: WorkflowStatusEvent) async {
        let handler: WorkflowApplyHandler? = {
            handlersLock.lock()
            defer { handlersLock.unlock() }
            return applyHandlers[event.workflowKey]
        }()

        guard let handler else { return }

        do {
            // 1. Claim the lease.
            let claimResult = try await claimApply(
                workflowKey: event.workflowKey,
                runKey: event.runKey,
                contextDocId: event.contextDocId
            )
            if !claimResult.claimed {
                let reason = claimResult.reason ?? "?"
                logger?.debug("[workflowApply] claim refused", [
                    "workflowKey": event.workflowKey,
                    "runKey": event.runKey,
                    "reason": reason
                ])
                return
            }

            // 2. Fetch the full output via getStatus. The CF status block
            //    carries `output` regardless of the apply-flow status.
            let statusResult = try await getStatus(
                workflowKey: event.workflowKey,
                runKey: event.runKey,
                contextDocId: event.contextDocId
            )
            let output = Self.outputToAny(statusResult.output)
            let metaFromRun = Self.metaToAny(statusResult.run?.meta)

            // 3. Run the user's handler.
            try await handler(WorkflowApplyContext(
                workflowKey: event.workflowKey,
                runKey: event.runKey,
                runId: event.runId,
                contextDocId: event.contextDocId,
                output: output,
                startedByUserId: event.startedByUserId,
                meta: metaFromRun ?? event.meta
            ))

            // 4. Confirm the apply.
            _ = try await confirmApply(
                workflowKey: event.workflowKey,
                runKey: event.runKey,
                contextDocId: event.contextDocId
            )
        } catch {
            // Release the claim so another client can retry.
            logger?.warn("[workflowApply] apply handler failed", [
                "workflowKey": event.workflowKey,
                "runKey": event.runKey,
                "error": String(describing: error)
            ])
            do {
                _ = try await releaseApply(
                    workflowKey: event.workflowKey,
                    runKey: event.runKey,
                    contextDocId: event.contextDocId
                )
            } catch {
                logger?.debug("[workflowApply] failed to release claim", [
                    "workflowKey": event.workflowKey,
                    "runKey": event.runKey,
                    "error": String(describing: error)
                ])
            }
        }
    }
}

// MARK: - Request / response shims

/// Body shared by the three apply-lease verbs (claim / confirm / release).
private struct ApplyPayload: Encodable, Sendable {
    let connectionId: String
    let contextDocId: String?
}

/// The pending-applies endpoint answers with a `{ pendingApplies }` envelope.
/// Any other shape yields an empty list (matching the previous
/// `result as? [String: Any]` probe), while a present-but-malformed
/// `pendingApplies` still throws rather than silently dropping rows (#991).
private struct PendingAppliesResponse: Decodable, Sendable {
    let items: [PendingApplyInfo]

    private enum CodingKeys: String, CodingKey { case pendingApplies }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              container.contains(.pendingApplies) else {
            items = []
            return
        }
        items = try container.decode([PendingApplyInfo].self, forKey: .pendingApplies)
    }
}

/// Thread-safe one-shot settle coordinator for `WorkflowsAPI.waitFor`. Guards
/// the single continuation-resume against the racing settle sources (terminal
/// frame, reconcile fetch, timeout, caller cancellation) and coalesces
/// overlapping reconcile requests.
private final class WaitForCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var reconciling = false
    /// A reconcile was requested while one was already in flight. Coalesces any
    /// number of concurrent requests into a single queued re-run.
    private var pendingReconcile = false
    private var continuation: CheckedContinuation<WaitForWorkflowResult, Error>?
    /// Set when `settle` runs before the continuation is installed (cancellation
    /// can fire before/while the continuation closure sets up). Drained by
    /// `setContinuation`.
    private var pendingResult: Result<WaitForWorkflowResult, Error>?
    private var statusSub: EventSubscription?
    private var workflowSub: EventSubscription?
    private var timeoutTask: Task<Void, Never>?

    /// Record the subscriptions/timer so a later settle can tear them down. If
    /// the wait already settled before install (a terminal frame delivered
    /// during subscription, or an early cancellation), cancel them immediately
    /// so nothing leaks.
    func install(
        statusSub: EventSubscription?,
        workflowSub: EventSubscription?,
        timeoutTask: Task<Void, Never>?
    ) {
        lock.lock()
        if settled {
            lock.unlock()
            statusSub?.cancel()
            workflowSub?.cancel()
            timeoutTask?.cancel()
            return
        }
        self.statusSub = statusSub
        self.workflowSub = workflowSub
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    /// Hand the continuation to the coordinator once the closure has it. If the
    /// wait already settled (e.g. cancellation raced the setup), resume it
    /// immediately with the stored result rather than leaving the caller
    /// suspended forever.
    func setContinuation(_ c: CheckedContinuation<WaitForWorkflowResult, Error>) {
        lock.lock()
        if let pending = pendingResult {
            pendingResult = nil
            lock.unlock()
            c.resume(with: pending)
            return
        }
        continuation = c
        lock.unlock()
    }

    /// Single settle path: claim the exclusive right to resume, tear down the
    /// subscriptions/timer, and resume the continuation (or stash the result for
    /// `setContinuation` if it isn't installed yet). Idempotent — a second call
    /// is a no-op, so the continuation can never be resumed twice.
    /// Whether the wait has already settled — read by the finalization re-check
    /// loop so it stops fetching once someone else claimed the resume.
    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settled
    }

    func settle(_ result: Result<WaitForWorkflowResult, Error>) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        let statusSub = self.statusSub
        let workflowSub = self.workflowSub
        let timeoutTask = self.timeoutTask
        self.statusSub = nil
        self.workflowSub = nil
        self.timeoutTask = nil
        let c = continuation
        continuation = nil
        if c == nil {
            // Continuation not installed yet — resumed by setContinuation.
            pendingResult = result
        }
        lock.unlock()

        statusSub?.cancel()
        workflowSub?.cancel()
        timeoutTask?.cancel()
        c?.resume(with: result)
    }

    /// Overlap guard: returns `true` if the caller may start a reconcile fetch.
    /// If one is already in flight, records a queued request (`pendingReconcile`)
    /// and returns `false` so the in-flight fetch runs one more time on
    /// completion instead of dropping this request. Returns `false` if the wait
    /// already settled.
    func beginReconcile() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if settled { return false }
        if reconciling {
            pendingReconcile = true
            return false
        }
        reconciling = true
        return true
    }

    /// Called when a reconcile fetch finishes. Returns `true` if a reconcile was
    /// queued while this one was in flight and the wait hasn't settled — the
    /// caller should loop and run exactly one more fetch, keeping the in-flight
    /// flag held so a concurrent `beginReconcile` can't also start one. Returns
    /// `false` otherwise, releasing the in-flight flag.
    func endReconcile() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !settled && pendingReconcile {
            pendingReconcile = false
            // Keep `reconciling == true`: we're looping, still in flight.
            return true
        }
        reconciling = false
        return false
    }
}
