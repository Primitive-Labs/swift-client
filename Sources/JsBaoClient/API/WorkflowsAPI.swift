import Foundation

// MARK: - WorkflowsAPI

public final class WorkflowsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
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

    /// Gets the status of a workflow run.
    ///
    /// - Parameters:
    ///   - workflowKey: The workflow identifier.
    ///   - runKey: The run key identifying the specific execution.
    /// - Returns: Status result containing status, output (if completed), and error (if failed).
    public func getStatus(
        workflowKey: String,
        runKey: String
    ) async throws -> [String: Any] {
        let encodedKey = workflowKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workflowKey
        let encodedRunKey = runKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runKey
        let result = try await makeRequest("GET", "/workflows/\(encodedKey)/instances/\(encodedRunKey)/status", nil)
        return result as? [String: Any] ?? [:]
    }

    /// Terminates a running workflow.
    ///
    /// - Parameters:
    ///   - workflowKey: The workflow identifier.
    ///   - runKey: The run key identifying the specific execution.
    /// - Returns: Status result after termination.
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
    ///
    /// - Parameter options: Filtering options (workflowKey, status, limit, cursor).
    /// - Returns: Result with items array and optional pagination cursor.
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
}
