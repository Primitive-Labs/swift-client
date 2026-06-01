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

    /// One-shot per-run waiter installed by `runAndApply` / `awaitRun`.
    /// Carries the full run context so reconnect-recovery
    /// (`recheckPendingRuns`) and claim-refused retries can operate
    /// without the caller feeding metadata back in.
    fileprivate struct PerRunWaiter {
        let workflowKey: String
        let contextDocId: String?
        let continuation: CheckedContinuation<WorkflowApplyContext, Error>
        var claimRetryCount: Int
    }

    /// Keyed by `runKey`. Consumed atomically on first terminal event
    /// (success, failure, timeout, cancellation). Multiple `runAndApply`
    /// / `awaitRun` calls on the same workflow key coexist cleanly.
    fileprivate var perRunWaiters: [String: PerRunWaiter] = [:]

    /// Lease TTL on the server is 30s. Retry ~5s after that so the
    /// lease has reliably expired before we re-attempt the claim.
    private static let claimRetryAfter: TimeInterval = 35
    /// Stop retrying claims after this many attempts — the outer
    /// `runAndApply`/`awaitRun` timeout will still cover it.
    private static let maxClaimRetries = 3

    private let handlersLock = NSLock()

    private enum RunReconcileDisposition {
        case waitingForFutureEvents
        case resolvedOrInFlight
    }

    /// Optional emitter for `workflowStarted` events. Wired by
    /// `JsBaoClient.setupSubApis`; `nil` when WorkflowsAPI is
    /// constructed directly (tests / standalone usage).
    private weak var events: EventEmitter?

    public init(
        makeRequest: @escaping (String, String, Any?) async throws -> Any,
        getConnectionId: @escaping () -> String = { "" },
        logger: Logger? = nil,
        events: EventEmitter? = nil
    ) {
        self.makeRequest = makeRequest
        self.getConnectionId = getConnectionId
        self.logger = logger
        self.events = events
    }

    // MARK: - Workflow Execution

    /// Starts a workflow execution.
    ///
    /// - Parameters:
    ///   - workflowKey: The workflow identifier (e.g. "analyze-text").
    ///   - input: Input data passed to the workflow.
    ///   - options: Optional start options (runKey for idempotency, contextDocId, meta).
    /// - Returns: Result containing runId, runKey, status, and whether an existing run was returned.
    public func start(
        workflowKey: String,
        input: [String: Any],
        options: StartWorkflowOptions? = nil
    ) async throws -> [String: Any] {
        let encodedKey = workflowKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowKey
        var body: [String: Any] = ["rootInput": input]
        if let runKey = options?.runKey { body["runKey"] = runKey }
        if let contextDocId = options?.contextDocId { body["contextDocId"] = contextDocId }
        if let meta = options?.meta { body["meta"] = meta }
        if options?.forceRerun == true { body["forceRerun"] = true }

        let result = try await makeRequest("POST", "/workflows/\(encodedKey)/start", body)
        let dict = result as? [String: Any] ?? [:]
        // Fire `workflowStarted` so cross-platform subscribers can
        // observe successful starts without polling. Same shape as
        // the JS event.
        if let runId = dict["runId"] as? String {
            events?.emit(.workflowStarted, WorkflowStartedEvent(
                workflowKey: workflowKey, runId: runId
            ))
        }
        return dict
    }

    /// Gets the status of a workflow run. Mirrors the JS client.
    /// Returns the raw envelope with one normalized field added:
    ///
    ///   `["normalizedStatus": ...]` — one of `apply_pending`,
    ///   `apply_claimed`, `complete`, `failed`, `terminated`, or
    ///   `running`. The DB record's `apply_*` states take precedence
    ///   over the CF workflow's terminal states (matches js-bao's
    ///   `getWorkflowStatus`).
    ///
    /// The raw envelope (`status`, `run`) is still in the returned
    /// dict for callers that need the CF/DB shapes directly.
    public func getStatus(
        workflowKey: String,
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> [String: Any] {
        let encodedKey = workflowKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowKey
        let encodedRunKey = runKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runKey
        var path = "/workflows/\(encodedKey)/instances/\(encodedRunKey)/status"
        if let contextDocId = contextDocId,
           let encoded = contextDocId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?contextDocId=\(encoded)"
        }
        let result = try await makeRequest("GET", path, nil)
        var dict = result as? [String: Any] ?? [:]
        dict["normalizedStatus"] = Self.normalizeWorkflowStatus(envelope: dict)
        return dict
    }

    /// CF/DB status reconciliation. Lifted out of `getStatus` so the
    /// `awaitRun` waiter (and future callers) can apply the same
    /// rules to either an arrived event or a polled envelope.
    internal static func normalizeWorkflowStatus(envelope: [String: Any]) -> String {
        let rawStatus = envelope["status"] as? [String: Any]
        let run = envelope["run"] as? [String: Any]
        let cfStatus = (rawStatus?["status"] as? String)?.lowercased() ?? ""
        let dbStatus = run?["status"] as? String
        if dbStatus == "apply_pending" { return "apply_pending" }
        if dbStatus == "apply_claimed" { return "apply_claimed" }
        if cfStatus == "complete" { return "complete" }
        if cfStatus == "errored" { return "failed" }
        if cfStatus == "terminated" { return "terminated" }
        return "running"
    }

    /// Terminates a running workflow.
    ///
    /// - Parameter contextDocId: optional doc-scope for the terminate
    ///   call (matches js-bao's `terminate(runKey, opts: {contextDocId})`).
    ///   Required for workflows that were started with a `contextDocId`
    ///   so the server can route to the right per-doc DO.
    public func terminate(
        workflowKey: String,
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> [String: Any] {
        let encodedKey = workflowKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowKey
        let encodedRunKey = runKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runKey
        var path = "/workflows/\(encodedKey)/instances/\(encodedRunKey)/terminate"
        if let contextDocId,
           let encoded = contextDocId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?contextDocId=\(encoded)"
        }
        let result = try await makeRequest("POST", path, nil)
        return result as? [String: Any] ?? [:]
    }

    /// List the per-step runs of a single workflow run. Useful for
    /// debugging UIs that want to surface the apply-pending /
    /// apply-applied state of each step.
    public func listStepRuns(runId: String) async throws -> [String: Any] {
        let encoded = runId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runId
        let result = try await makeRequest("GET", "/workflows/runs/\(encoded)/steps", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Lists workflow runs with optional filtering and pagination.
    public func listRuns(options: ListWorkflowRunsOptions? = nil) async throws -> [String: Any] {
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
        return result as? [String: Any] ?? [:]
    }

    // MARK: - Apply Flow

    /// Claim the apply lease for a workflow run that's parked in
    /// `apply_pending`. The server transitions the run to `apply_claimed`
    /// for 30 seconds; while the lease is held, no other client can claim
    /// it. Returns `claimed: false` (with a `reason`) if another client
    /// already holds the lease, the run isn't in an apply-pending state,
    /// etc. — see the JS client docs for the full reason taxonomy.
    public func claimApply(
        workflowKey: String,
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> [String: Any] {
        let encodedKey = workflowKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowKey
        let encodedRunKey = runKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runKey
        var payload: [String: Any] = ["connectionId": getConnectionId()]
        if let contextDocId = contextDocId { payload["contextDocId"] = contextDocId }
        let result = try await makeRequest(
            "POST",
            "/workflows/\(encodedKey)/instances/\(encodedRunKey)/claim-apply",
            payload
        )
        return result as? [String: Any] ?? [:]
    }

    /// Confirm a previously-claimed apply. The server transitions the run
    /// from `apply_claimed` to `completed`. Conditional on the same
    /// `connectionId` that called `claimApply` — `not_claimed_by_you` is
    /// returned if the lease was reclaimed by another connection.
    public func confirmApply(
        workflowKey: String,
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> [String: Any] {
        let encodedKey = workflowKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowKey
        let encodedRunKey = runKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runKey
        var payload: [String: Any] = ["connectionId": getConnectionId()]
        if let contextDocId = contextDocId { payload["contextDocId"] = contextDocId }
        let result = try await makeRequest(
            "POST",
            "/workflows/\(encodedKey)/instances/\(encodedRunKey)/confirm-apply",
            payload
        )
        return result as? [String: Any] ?? [:]
    }

    /// Release a previously-claimed apply, sending the run back to
    /// `apply_pending` so another client (or a retry) can claim it.
    /// Conditional on the claiming `connectionId`.
    public func releaseApply(
        workflowKey: String,
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> [String: Any] {
        let encodedKey = workflowKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowKey
        let encodedRunKey = runKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runKey
        var payload: [String: Any] = ["connectionId": getConnectionId()]
        if let contextDocId = contextDocId { payload["contextDocId"] = contextDocId }
        let result = try await makeRequest(
            "POST",
            "/workflows/\(encodedKey)/instances/\(encodedRunKey)/release-apply",
            payload
        )
        return result as? [String: Any] ?? [:]
    }

    /// Fetch the list of workflow runs that are currently in
    /// `apply_pending` (or `apply_claimed` with an expired lease) for a
    /// given context document. Useful for reconnecting clients to recover
    /// applies that arrived while the client was offline.
    public func getPendingApplies(contextDocId: String) async throws -> [[String: Any]] {
        guard let encoded = contextDocId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        let result = try await makeRequest("GET", "/workflows/pending-applies?contextDocId=\(encoded)", nil)
        if let dict = result as? [String: Any], let items = dict["pendingApplies"] as? [[String: Any]] {
            return items
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

    /// Drop a previously-registered apply handler.
    public func undefine(_ workflowKey: String) {
        handlersLock.lock()
        defer { handlersLock.unlock() }
        applyHandlers.removeValue(forKey: workflowKey)
    }

    // MARK: - Parallel-safe run helper

    /// Thrown from `runAndApply` when the workflow reaches a terminal
    /// non-success state or times out before output is delivered.
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

    /// Start a workflow and await its output.
    ///
    /// Unlike the `define` + `start` pair — which assumes a single handler
    /// per `workflowKey` and therefore can't be used for concurrent runs
    /// of the same workflow — this method tracks each call by `runKey` so
    /// N parallel invocations on the same key coexist cleanly.
    ///
    /// The full apply flow (claim → getStatus → confirm) runs inside, and
    /// the returned `WorkflowApplyContext` carries the same output a
    /// handler would receive. Terminal non-success statuses throw
    /// `WorkflowRunError.terminalFailure`; missed output inside the
    /// timeout window throws `.timedOut`. Task cancellation propagates:
    /// a cancelled awaiter removes itself from the dispatch dict and
    /// throws `CancellationError`.
    ///
    /// Coexists with `define`: if a per-run waiter is present for a
    /// given `runKey`, it takes precedence; otherwise the per-key
    /// handler (if registered) runs as before.
    ///
    /// - Parameters:
    ///   - workflowKey: The workflow identifier.
    ///   - input: Workflow input (the server's `rootInput`).
    ///   - options: Optional start options (runKey, contextDocId, meta).
    ///              If `options.runKey` is nil, a unique one is generated.
    ///   - timeout: Max seconds to wait for output. Default 120.
    public func runAndApply(
        workflowKey: String,
        input: [String: Any],
        options: StartWorkflowOptions? = nil,
        timeout: TimeInterval = 120
    ) async throws -> WorkflowApplyContext {
        let runKey = options?.runKey ?? Self.generateRunKey()
        let contextDocId = options?.contextDocId
        let effectiveOptions = StartWorkflowOptions(
            runKey: runKey,
            contextDocId: contextDocId,
            meta: options?.meta
        )
        return try await waitForRun(
            workflowKey: workflowKey,
            runKey: runKey,
            contextDocId: contextDocId,
            timeout: timeout
        ) { [weak self] in
            do {
                _ = try await self?.start(
                    workflowKey: workflowKey,
                    input: input,
                    options: effectiveOptions
                )
            } catch {
                self?.consumePerRunWaiter(runKey: runKey)?
                    .continuation.resume(throwing: error)
            }
        }
    }

    /// Reconnect to an existing workflow run and await its output.
    ///
    /// Use this on app resume / document reopen to pick up a run started
    /// in a previous session. Works across all run states:
    ///
    /// - `apply_pending` / `apply_claimed` (lease available or stale) —
    ///   triggers the client-side apply flow (claim → getStatus →
    ///   confirm) and returns the output.
    /// - `running` / `queued` / `starting` — subscribes to this run's
    ///   `workflowStatus` and awaits completion.
    /// - `completed` (already applied in a prior session) — fetches the
    ///   stored output via `getStatus` and returns it immediately.
    /// - `failed` / `terminated` / `error` — throws `.terminalFailure`.
    /// - run not found — throws `.terminalFailure(status: "not_found")`.
    ///
    /// The waiter is registered eagerly (before the status check) so a
    /// `workflowStatus` arriving mid-method can't be missed.
    public func awaitRun(
        workflowKey: String,
        runKey: String,
        contextDocId: String? = nil,
        timeout: TimeInterval = 120
    ) async throws -> WorkflowApplyContext {
        return try await waitForRun(
            workflowKey: workflowKey,
            runKey: runKey,
            contextDocId: contextDocId,
            timeout: timeout
        ) { [weak self] in
            guard let self else { return }

            let disposition = await self.reconcileRun(
                workflowKey: workflowKey,
                runKey: runKey,
                contextDocId: contextDocId
            )

            guard disposition == .waitingForFutureEvents else { return }

            try? await Task.sleep(nanoseconds: 750_000_000)
            guard self.peekPerRunWaiter(runKey: runKey) != nil else { return }

            if let contextDocId {
                await self.deliverPendingApply(
                    workflowKey: workflowKey,
                    runKey: runKey,
                    contextDocId: contextDocId
                )
            }

            guard self.peekPerRunWaiter(runKey: runKey) != nil else { return }

            _ = await self.reconcileRun(
                workflowKey: workflowKey,
                runKey: runKey,
                contextDocId: contextDocId
            )
        }
    }

    /// Check the server's current state for a pending waiter and take
    /// whichever branch matches (trigger apply flow, resolve with
    /// output, throw, or wait). Shared by `awaitRun` (initial check)
    /// and `recheckPendingRuns` (reconnect-driven re-check).
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
            let runRecord = statusResult["run"] as? [String: Any]
            let runStatus = (runRecord?["status"] as? String)?.lowercased() ?? ""
            let cfStatus = statusResult["status"] as? [String: Any]
            let canonicalWorkflowKey =
                (runRecord?["workflowKey"] as? String)
                ?? workflowKey

            switch runStatus {
            case "apply_pending", "apply_claimed":
                let event = WorkflowStatusEvent(
                    workflowKey: canonicalWorkflowKey,
                    workflowId: "",
                    runKey: runKey,
                    runId: (runRecord?["runId"] as? String) ?? "",
                    status: "completed",
                    contextDocId: contextDocId,
                    needsApply: true,
                    meta: runRecord?["meta"] as? [String: Any],
                    startedByUserId: runRecord?["startedByUserId"] as? String
                )
                await handleApplyEvent(event)
                return .resolvedOrInFlight
            case "completed":
                let output: Any? = {
                    guard let raw = cfStatus?["output"], !(raw is NSNull) else { return nil }
                    return raw
                }()
                let ctx = WorkflowApplyContext(
                    workflowKey: workflowKey,
                    runKey: runKey,
                    runId: (runRecord?["runId"] as? String) ?? "",
                    contextDocId: contextDocId,
                    output: output,
                    startedByUserId: runRecord?["startedByUserId"] as? String,
                    meta: runRecord?["meta"] as? [String: Any]
                )
                consumePerRunWaiter(runKey: runKey)?
                    .continuation.resume(returning: ctx)
                return .resolvedOrInFlight
            case "failed", "terminated", "error":
                let message = (runRecord?["error"] as? String)
                    ?? (cfStatus?["error"] as? String)
                consumePerRunWaiter(runKey: runKey)?
                    .continuation.resume(throwing: WorkflowRunError.terminalFailure(
                        status: runStatus, message: message
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

    /// Shared plumbing for `runAndApply` / `awaitRun`: register a one-shot
    /// waiter for `runKey` (with workflow context for reconnect-recovery),
    /// install a timeout, run `afterRegister` (which is where the caller
    /// fires the workflow or triggers apply), and propagate `Task`
    /// cancellation to the waiter.
    private func waitForRun(
        workflowKey: String,
        runKey: String,
        contextDocId: String?,
        timeout: TimeInterval,
        afterRegister: @Sendable @escaping () async -> Void
    ) async throws -> WorkflowApplyContext {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WorkflowApplyContext, Error>) in
                var shouldProceed = true
                handlersLock.lock()
                if perRunWaiters[runKey] != nil {
                    handlersLock.unlock()
                    shouldProceed = false
                    continuation.resume(throwing: JsBaoError(
                        code: .invalidArgument,
                        message: "runKey \(runKey) is already awaiting output"
                    ))
                } else {
                    perRunWaiters[runKey] = PerRunWaiter(
                        workflowKey: workflowKey,
                        contextDocId: contextDocId,
                        continuation: continuation,
                        claimRetryCount: 0
                    )
                    handlersLock.unlock()
                }
                guard shouldProceed else { return }

                // Timeout — resolves the waiter iff still registered.
                let timeoutNs = UInt64(max(0, timeout) * 1_000_000_000)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNs)
                    self?.consumePerRunWaiter(runKey: runKey)?
                        .continuation.resume(throwing: WorkflowRunError.timedOut(timeout))
                }

                Task { await afterRegister() }
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            self.consumePerRunWaiter(runKey: runKey)?
                .continuation.resume(throwing: CancellationError())
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

    /// Generate a random runKey. Same shape clients tend to build:
    /// `run-<12 hex>-<unix-seconds>`.
    private static func generateRunKey() -> String {
        let randomHex = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        return "run-\(randomHex)-\(Int(Date().timeIntervalSince1970))"
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
            let claimed = claimResult["claimed"] as? Bool ?? false
            if !claimed {
                let reason = claimResult["reason"] ?? "?"
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
            let cfStatus = statusResult["status"] as? [String: Any]
            let output: Any? = {
                guard let raw = cfStatus?["output"], !(raw is NSNull) else { return nil }
                return raw
            }()
            let runRecord = statusResult["run"] as? [String: Any]
            let metaFromRun = runRecord?["meta"] as? [String: Any]

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
                let cfStatus = statusResult["status"] as? [String: Any]
                let output: Any? = {
                    guard let raw = cfStatus?["output"], !(raw is NSNull) else { return nil }
                    return raw
                }()
                let runRecord = statusResult["run"] as? [String: Any]
                let ctx = WorkflowApplyContext(
                    workflowKey: event.workflowKey,
                    runKey: event.runKey,
                    runId: event.runId,
                    contextDocId: event.contextDocId,
                    output: output,
                    startedByUserId: event.startedByUserId,
                    meta: (runRecord?["meta"] as? [String: Any]) ?? event.meta
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

    /// Public — re-checks every currently-registered per-run waiter
    /// against the server's current state. Intended to be called after
    /// the client reconnects: pending applies that the server tried to
    /// deliver while we were offline (and whose `workflowStatus` events
    /// we missed) get picked up here.
    ///
    /// Per-run waiters installed by `runAndApply` and `awaitRun` carry
    /// enough context (workflowKey, contextDocId) to do this without
    /// the caller re-supplying anything. No-op for `define`-style
    /// per-key handlers — those don't have a waiter.
    public func recheckPendingRuns() async {
        let pending = snapshotPendingWaiters()
        for (runKey, waiter) in pending {
            _ = await reconcileRun(
                workflowKey: waiter.workflowKey,
                runKey: runKey,
                contextDocId: waiter.contextDocId
            )
        }
    }

    /// Convenience: fetch any pending applies for a context document and
    /// run them through the registered handlers. Call after reconnect or
    /// when a document is opened, to recover applies that fired while the
    /// client was offline.
    public func deliverPendingApplies(contextDocId: String) async {
        do {
            let runs = try await getPendingApplies(contextDocId: contextDocId)
            for run in runs {
                let event = WorkflowStatusEvent(
                    workflowKey: run["workflowKey"] as? String ?? "",
                    workflowId: run["workflowId"] as? String ?? "",
                    runKey: run["runKey"] as? String ?? "",
                    runId: run["runId"] as? String ?? "",
                    status: "completed",
                    contextDocId: run["contextDocId"] as? String ?? contextDocId,
                    needsApply: true,
                    meta: run["meta"] as? [String: Any],
                    startedByUserId: run["startedByUserId"] as? String
                )
                await handleApplyEvent(event)
            }
        } catch {
            logger?.debug("[pendingApplies] fetch failed", [
                "contextDocId": contextDocId,
                "error": String(describing: error)
            ])
        }
    }

    private func deliverPendingApply(
        workflowKey: String,
        runKey: String,
        contextDocId: String
    ) async {
        do {
            let runs = try await getPendingApplies(contextDocId: contextDocId)
            guard let run = runs.first(where: {
                ($0["runKey"] as? String) == runKey
                    && (($0["workflowKey"] as? String)?.lowercased()
                        == workflowKey.lowercased())
            }) else {
                return
            }

            let canonicalWorkflowKey =
                (run["workflowKey"] as? String)
                ?? workflowKey

            let event = WorkflowStatusEvent(
                workflowKey: canonicalWorkflowKey,
                workflowId: run["workflowId"] as? String ?? "",
                runKey: runKey,
                runId: run["runId"] as? String ?? "",
                status: "completed",
                contextDocId: run["contextDocId"] as? String ?? contextDocId,
                needsApply: true,
                meta: run["meta"] as? [String: Any],
                startedByUserId: run["startedByUserId"] as? String
            )
            await handleApplyEvent(event)
        } catch {
            logger?.debug("[pendingApplies] fetch failed", [
                "contextDocId": contextDocId,
                "runKey": runKey,
                "workflowKey": workflowKey,
                "error": String(describing: error)
            ])
        }
    }
}
