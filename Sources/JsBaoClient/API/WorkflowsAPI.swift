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
    private let makeRequest: (String, String, Any?) async throws -> Any
    private let getConnectionId: () -> String
    private let logger: Logger?

    /// Registered apply handlers, keyed by `workflowKey`. Protected by
    /// `handlersLock` so `define` and `handleApplyEvent` can be called from
    /// any thread.
    private var applyHandlers: [String: WorkflowApplyHandler] = [:]

    /// One-shot per-run waiter keyed by `runKey`. Carries the full run
    /// context so reconnect-recovery (`recheckPendingRuns`) and
    /// claim-refused retries can operate without the caller feeding
    /// metadata back in.
    fileprivate struct PerRunWaiter {
        let workflowKey: String
        let contextDocId: String?
        let continuation: CheckedContinuation<WorkflowApplyContext, Error>
        var claimRetryCount: Int
    }

    /// Keyed by `runKey`. Consumed atomically on the first terminal event
    /// (success, failure, timeout, cancellation).
    fileprivate var perRunWaiters: [String: PerRunWaiter] = [:]

    /// Lease TTL on the server is 30s. Retry ~5s after that so the
    /// lease has reliably expired before we re-attempt the claim.
    private static let claimRetryAfter: TimeInterval = 35
    /// Stop retrying claims after this many attempts — the per-run
    /// waiter's timeout will still cover it.
    private static let maxClaimRetries = 3

    private let handlersLock = NSLock()

    private enum RunReconcileDisposition {
        case waitingForFutureEvents
        case resolvedOrInFlight
    }

    public init(
        makeRequest: @escaping (String, String, Any?) async throws -> Any,
        getConnectionId: @escaping () -> String = { "" },
        logger: Logger? = nil
    ) {
        self.makeRequest = makeRequest
        self.getConnectionId = getConnectionId
        self.logger = logger
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
        let encodedKey = workflowKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowKey
        var body: [String: Any] = ["rootInput": input]
        if let runKey = options?.runKey { body["runKey"] = runKey }
        if let contextDocId = options?.contextDocId { body["contextDocId"] = contextDocId }
        if let meta = options?.meta { body["meta"] = meta }
        if options?.forceRerun == true { body["forceRerun"] = true }

        let result = try await makeRequest("POST", "/workflows/\(encodedKey)/start", body)
        // No local `workflowStarted` emit here (#1112): JS emits the event
        // exclusively from the server-pushed `workflowStarted` WS frame
        // (handled in `JsBaoClient.handleWebSocketMessage`), so emitting
        // from the HTTP start path too produced a double emit per start.
        return try JSONCoding.decode(StartWorkflowResult.self, from: result)
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
        let encodedKey = workflowKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowKey
        var body: [String: Any] = ["rootInput": input]
        if let runKey { body["runKey"] = runKey }
        if let contextDocId { body["contextDocId"] = contextDocId }
        if let meta { body["meta"] = meta }
        if let timeoutMs, timeoutMs > 0 { body["timeoutMs"] = timeoutMs }
        let result = try await makeRequest("POST", "/workflows/\(encodedKey)/run-sync", body)
        return try JSONCoding.decode(RunSyncWorkflowResult.self, from: result)
    }

    /// Gets the status of a workflow run. Mirrors the JS client's
    /// `getStatus` — returns a decoded `WorkflowStatusResult` (#954) whose
    /// `status` (CF status) and `run` (DB record) carry the raw shapes.
    /// Throws on a response shape mismatch instead of coercing to `[:]`
    /// (#991).
    public func getStatus(
        workflowKey: String,
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatusResult {
        let encodedKey = workflowKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowKey
        let encodedRunKey = runKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runKey
        var path = "/workflows/\(encodedKey)/instances/\(encodedRunKey)/status"
        if let contextDocId = contextDocId,
           let encoded = contextDocId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?contextDocId=\(encoded)"
        }
        let result = try await makeRequest("GET", path, nil)
        return try JSONCoding.decode(WorkflowStatusResult.self, from: result)
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
        let encodedKey = workflowKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowKey
        let encodedRunKey = runKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runKey
        var path = "/workflows/\(encodedKey)/instances/\(encodedRunKey)/terminate"
        if let contextDocId,
           let encoded = contextDocId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?contextDocId=\(encoded)"
        }
        let result = try await makeRequest("POST", path, nil)
        return try JSONCoding.decode(WorkflowStatusResult.self, from: result)
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
        let encoded = runId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runId
        let result = try await makeRequest("GET", "/workflows/runs/\(encoded)/steps", nil)
        return try JSONCoding.decode(ListWorkflowStepRunsResult.self, from: result)
    }

    /// Lists workflow runs with optional filtering and pagination.
    ///
    /// Now typed: returns a decoded `ListWorkflowRunsResult` (#954) — throws
    /// on a response shape mismatch instead of coercing to `[:]` (#991). The
    /// existing filters (`workflowKey`, `status`, `limit`, `cursor`,
    /// `forward`, `contextDocId`) are preserved.
    public func listRuns(options: ListWorkflowRunsOptions? = nil) async throws -> ListWorkflowRunsResult {
        var queryParts: [String] = []
        if let workflowKey = options?.workflowKey {
            queryParts.append("workflowKey=\(workflowKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? workflowKey)")
        }
        if let status = options?.status {
            queryParts.append("status=\(status.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? status)")
        }
        if let limit = options?.limit {
            queryParts.append("limit=\(limit)")
        }
        if let cursor = options?.cursor {
            queryParts.append("cursor=\(cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor)")
        }
        if let forward = options?.forward {
            queryParts.append("forward=\(forward ? "true" : "false")")
        }
        if let contextDocId = options?.contextDocId,
           let encoded = contextDocId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            queryParts.append("contextDocId=\(encoded)")
        }
        let query = queryParts.isEmpty ? "" : "?\(queryParts.joined(separator: "&"))"
        let result = try await makeRequest("GET", "/workflows/runs\(query)", nil)
        return try JSONCoding.decode(ListWorkflowRunsResult.self, from: result)
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
        let encodedKey = workflowKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowKey
        let encodedRunKey = runKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runKey
        var payload: [String: Any] = ["connectionId": getConnectionId()]
        if let contextDocId = contextDocId { payload["contextDocId"] = contextDocId }
        let result = try await makeRequest(
            "POST",
            "/workflows/\(encodedKey)/instances/\(encodedRunKey)/claim-apply",
            payload
        )
        return try JSONCoding.decode(ClaimApplyResult.self, from: result)
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
        let encodedKey = workflowKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowKey
        let encodedRunKey = runKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runKey
        var payload: [String: Any] = ["connectionId": getConnectionId()]
        if let contextDocId = contextDocId { payload["contextDocId"] = contextDocId }
        let result = try await makeRequest(
            "POST",
            "/workflows/\(encodedKey)/instances/\(encodedRunKey)/confirm-apply",
            payload
        )
        return try JSONCoding.decode(ConfirmApplyResult.self, from: result)
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
        let encodedKey = workflowKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowKey
        let encodedRunKey = runKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runKey
        var payload: [String: Any] = ["connectionId": getConnectionId()]
        if let contextDocId = contextDocId { payload["contextDocId"] = contextDocId }
        let result = try await makeRequest(
            "POST",
            "/workflows/\(encodedKey)/instances/\(encodedRunKey)/release-apply",
            payload
        )
        return try JSONCoding.decode(ReleaseApplyResult.self, from: result)
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
        guard let encoded = contextDocId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        let result = try await makeRequest("GET", "/workflows/pending-applies?contextDocId=\(encoded)", nil)
        if let dict = result as? [String: Any], let items = dict["pendingApplies"] {
            return try JSONCoding.decode([PendingApplyInfo].self, from: items)
        }
        return []
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

    // MARK: - Apply waiter errors

    /// Thrown when a workflow run reaches a terminal non-success state or
    /// times out before output is delivered to a per-run waiter.
    public enum WorkflowRunError: Error, LocalizedError, Sendable {
        /// The workflow reached a terminal `failed` / `terminated` /
        /// `error` state. `message` carries the server's `error` field
        /// when present.
        case terminalFailure(status: String, message: String?)
        /// The client didn't receive output within the timeout budget.
        case timedOut(TimeInterval)

        public var errorDescription: String? {
            switch self {
            case .terminalFailure(let status, let msg):
                if let msg = msg, !msg.isEmpty {
                    return "Workflow \(status): \(msg)"
                }
                return "Workflow \(status)"
            case .timedOut(let seconds):
                return "Workflow did not complete within \(Int(seconds))s"
            }
        }
    }

    /// Check the server's current state for a pending waiter and take
    /// whichever branch matches (trigger apply flow, resolve with
    /// output, throw, or wait). Used by `recheckPendingRuns`
    /// (reconnect-driven re-check).
    private func reconcileRun(
        workflowKey: String,
        runKey: String,
        contextDocId: String?
    ) async -> RunReconcileDisposition {
        do {
            let statusResult = try await getStatus(
                workflowKey: workflowKey,
                runKey: runKey,
                contextDocId: contextDocId
            )
            let runRecord = statusResult.run
            let runStatus = (runRecord?.status)?.lowercased() ?? ""
            let canonicalWorkflowKey = runRecord?.workflowKey ?? workflowKey

            switch runStatus {
            case "apply_pending", "apply_claimed":
                let event = WorkflowStatusEvent(
                    workflowKey: canonicalWorkflowKey,
                    workflowId: "",
                    runKey: runKey,
                    runId: runRecord?.runId ?? "",
                    status: "completed",
                    contextDocId: contextDocId,
                    needsApply: true,
                    meta: Self.metaToAny(runRecord?.meta),
                    startedByUserId: runRecord?.startedByUserId
                )
                await handleApplyEvent(event)
                return .resolvedOrInFlight
            case "completed":
                let ctx = WorkflowApplyContext(
                    workflowKey: workflowKey,
                    runKey: runKey,
                    runId: runRecord?.runId ?? "",
                    contextDocId: contextDocId,
                    output: Self.outputToAny(statusResult.output),
                    startedByUserId: runRecord?.startedByUserId,
                    meta: Self.metaToAny(runRecord?.meta)
                )
                consumePerRunWaiter(runKey: runKey)?
                    .continuation.resume(returning: ctx)
                return .resolvedOrInFlight
            case "failed", "terminated", "error":
                consumePerRunWaiter(runKey: runKey)?
                    .continuation.resume(throwing: WorkflowRunError.terminalFailure(
                        status: runStatus, message: statusResult.error
                    ))
                return .resolvedOrInFlight
            case "":
                consumePerRunWaiter(runKey: runKey)?
                    .continuation.resume(throwing: WorkflowRunError.terminalFailure(
                        status: "not_found",
                        message: "Workflow run \(runKey) not found"
                    ))
                return .resolvedOrInFlight
            default:
                // Still running — leave the waiter registered;
                // `workflowStatus` will deliver when it completes.
                return .waitingForFutureEvents
            }
        } catch let error as HttpError where error.status == 404 {
            consumePerRunWaiter(runKey: runKey)?
                .continuation.resume(throwing: WorkflowRunError.terminalFailure(
                    status: "not_found",
                    message: error.body ?? error.message
                ))
            return .resolvedOrInFlight
        } catch {
            consumePerRunWaiter(runKey: runKey)?
                .continuation.resume(throwing: error)
            return .resolvedOrInFlight
        }
    }

    /// Atomically remove and return the per-run waiter for a runKey.
    /// Returns nil if no waiter is registered (already resolved, timed
    /// out, cancelled, or a stale runKey from a prior session).
    fileprivate func consumePerRunWaiter(runKey: String) -> PerRunWaiter? {
        handlersLock.lock()
        defer { handlersLock.unlock() }
        return perRunWaiters.removeValue(forKey: runKey)
    }

    /// Peek at a registered waiter without consuming it.
    fileprivate func peekPerRunWaiter(runKey: String) -> PerRunWaiter? {
        handlersLock.lock()
        defer { handlersLock.unlock() }
        return perRunWaiters[runKey]
    }

    /// Snapshot the currently-registered waiters for iteration by
    /// `recheckPendingRuns`. Dictionary values are value types so this
    /// is safe to release the lock after.
    fileprivate func snapshotPendingWaiters() -> [(runKey: String, waiter: PerRunWaiter)] {
        handlersLock.lock()
        defer { handlersLock.unlock() }
        return perRunWaiters.map { ($0.key, $0.value) }
    }

    /// Bump the claim-retry counter for a runKey. Returns the new count,
    /// or nil if the waiter is no longer registered.
    fileprivate func incrementClaimRetry(runKey: String) -> Int? {
        handlersLock.lock()
        defer { handlersLock.unlock() }
        guard var waiter = perRunWaiters[runKey] else { return nil }
        waiter.claimRetryCount += 1
        perRunWaiters[runKey] = waiter
        return waiter.claimRetryCount
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

    /// Internal — invoked by `JsBaoClient` when a `workflowStatus` WS
    /// message arrives with `needsApply = true`. Looks up a registered
    /// handler (per-runKey waiter first, then per-workflowKey handler),
    /// runs the claim → handler → confirm sequence, and releases the
    /// claim on any failure.
    ///
    /// On claim refused (stale lease held by a dead connection),
    /// schedules a retry ~35s later (server's lease TTL is 30s). Retries
    /// up to `maxClaimRetries` times, then silently drops the attempt —
    /// the per-run waiter's timeout will eventually fire.
    internal func handleApplyEvent(_ event: WorkflowStatusEvent) async {
        // Peek (don't consume yet) — if we consumed before claim, a
        // refused claim would permanently orphan the waiter.
        let hasPerRunWaiter = (peekPerRunWaiter(runKey: event.runKey) != nil)
        let perKeyHandler: WorkflowApplyHandler? = {
            handlersLock.lock()
            defer { handlersLock.unlock() }
            return applyHandlers[event.workflowKey]
        }()

        guard hasPerRunWaiter || perKeyHandler != nil else { return }

        // Shim — consumes the per-run waiter ONLY at the moment we fire
        // it, after claim + status have succeeded. If claim fails, the
        // waiter stays registered (server may re-emit needsApply once
        // the lease expires, or retry / timeout resolves it).
        let handler: WorkflowApplyHandler = { [weak self] ctx in
            if let waiter = self?.consumePerRunWaiter(runKey: ctx.runKey) {
                waiter.continuation.resume(returning: ctx)
                return
            }
            if let perKey = perKeyHandler {
                try await perKey(ctx)
            }
        }

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
                // Only retry for per-run waiters — per-key-only handlers
                // are the "any one client wins" model and don't need
                // this machinery.
                if hasPerRunWaiter {
                    scheduleApplyRetry(event: event)
                }
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

    /// Background task: after the server's lease TTL (~30s) the refused
    /// claim should become claimable. Re-invokes `handleApplyEvent` up
    /// to `maxClaimRetries` times so a stale apply_claimed state doesn't
    /// hang awaiters until their timeout.
    private func scheduleApplyRetry(event: WorkflowStatusEvent) {
        guard let retryCount = incrementClaimRetry(runKey: event.runKey) else {
            return   // waiter gone (resolved, timed out, cancelled)
        }
        guard retryCount <= Self.maxClaimRetries else {
            logger?.debug("[workflowApply] claim-retry budget exhausted", [
                "runKey": event.runKey,
                "attempts": retryCount
            ])
            return
        }
        let delayNs = UInt64(Self.claimRetryAfter * 1_000_000_000)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard let self = self,
                  self.peekPerRunWaiter(runKey: event.runKey) != nil
            else { return }
            self.logger?.debug("[workflowApply] retrying claim", [
                "runKey": event.runKey,
                "attempt": retryCount
            ])
            await self.handleApplyEvent(event)
        }
    }

    /// Internal — invoked by `JsBaoClient` for a `workflowStatus` WS
    /// message whose `status` is terminal (`completed` / `failed` /
    /// `terminated` / `error`) and whose `needsApply` is false. Resolves
    /// any per-run waiter awaiting that `runKey`:
    ///
    /// - `completed` (run already applied by some client): fetch output
    ///   via `getStatus` and resume the waiter with success. Without
    ///   this path a waiter would hang until its timeout when another
    ///   client on the same user account applies the run first.
    /// - `failed` / `terminated` / `error`: resume with
    ///   `.terminalFailure`.
    ///
    /// No-op if nothing is waiting for this runKey.
    internal func handleTerminalEvent(_ event: WorkflowStatusEvent) async {
        guard peekPerRunWaiter(runKey: event.runKey) != nil else { return }

        let status = event.status.lowercased()
        if status == "completed" {
            do {
                let statusResult = try await getStatus(
                    workflowKey: event.workflowKey,
                    runKey: event.runKey,
                    contextDocId: event.contextDocId
                )
                let output = Self.outputToAny(statusResult.output)
                let ctx = WorkflowApplyContext(
                    workflowKey: event.workflowKey,
                    runKey: event.runKey,
                    runId: event.runId,
                    contextDocId: event.contextDocId,
                    output: output,
                    startedByUserId: event.startedByUserId,
                    meta: Self.metaToAny(statusResult.run?.meta) ?? event.meta
                )
                consumePerRunWaiter(runKey: event.runKey)?
                    .continuation.resume(returning: ctx)
            } catch {
                consumePerRunWaiter(runKey: event.runKey)?
                    .continuation.resume(throwing: error)
            }
        } else {
            // failed / terminated / error
            consumePerRunWaiter(runKey: event.runKey)?
                .continuation.resume(throwing: WorkflowRunError.terminalFailure(
                    status: event.status,
                    message: event.error
                ))
        }
    }

    /// Internal — re-checks every currently-registered per-run waiter
    /// against the server's current state. Called by `JsBaoClient` after
    /// the client reconnects: pending applies that the server tried to
    /// deliver while we were offline (and whose `workflowStatus` events
    /// we missed) get picked up here.
    ///
    /// Per-run waiters carry enough context (workflowKey, contextDocId) to
    /// do this without the caller re-supplying anything. No-op for
    /// `define`-style per-key handlers — those don't have a waiter.
    internal func recheckPendingRuns() async {
        let pending = snapshotPendingWaiters()
        for (runKey, waiter) in pending {
            _ = await reconcileRun(
                workflowKey: waiter.workflowKey,
                runKey: runKey,
                contextDocId: waiter.contextDocId
            )
        }
    }
}
