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
    private let handlersLock = NSLock()

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

        let result = try await makeRequest("POST", "/workflows/\(encodedKey)/start", body)
        return result as? [String: Any] ?? [:]
    }

    /// Gets the status of a workflow run. Mirrors the JS client. The
    /// response shape is `{ status: <CF status with output/stepResults>,
    /// run: <DB record with status: "apply_pending" | ... > }`.
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
        return result as? [String: Any] ?? [:]
    }

    /// Terminates a running workflow.
    public func terminate(
        workflowKey: String,
        runKey: String
    ) async throws -> [String: Any] {
        let encodedKey = workflowKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowKey
        let encodedRunKey = runKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runKey
        let result = try await makeRequest("POST", "/workflows/\(encodedKey)/instances/\(encodedRunKey)/terminate", nil)
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

    /// Internal — invoked by `JsBaoClient` when a `workflowStatus` WS
    /// message arrives with `needsApply = true`. Looks up the registered
    /// handler for the workflow, runs the claim → handler → confirm
    /// sequence, and releases the claim on any failure.
    internal func handleApplyEvent(_ event: WorkflowStatusEvent) async {
        let handler: WorkflowApplyHandler? = {
            handlersLock.lock()
            defer { handlersLock.unlock() }
            return applyHandlers[event.workflowKey]
        }()

        guard let handler = handler else { return }

        do {
            // 1. Claim the lease.
            let claimResult = try await claimApply(
                workflowKey: event.workflowKey,
                runKey: event.runKey,
                contextDocId: event.contextDocId
            )
            let claimed = claimResult["claimed"] as? Bool ?? false
            if !claimed {
                logger?.debug("[workflowApply] claim refused", [
                    "workflowKey": event.workflowKey,
                    "runKey": event.runKey,
                    "reason": claimResult["reason"] ?? "?"
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
}
