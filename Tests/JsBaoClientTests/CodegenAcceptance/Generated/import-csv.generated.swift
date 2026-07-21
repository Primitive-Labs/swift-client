// AUTO-GENERATED FROM workflows/import-csv.toml — DO NOT EDIT.
// Run `primitive workflows codegen --lang swift` to regenerate.
// fingerprint: b87d8a13f930f11e

import Foundation
import JsBaoClient

public typealias ImportCsvInput = JSONValue

public typealias ImportCsvOutput = JSONValue

/// Typed invoker for the `import-csv` workflow. Bind its `ImportCsvInput` /
/// `ImportCsvOutput` over the generic `WorkflowsAPI` overloads. Obtain one
/// with `importCsv(client)`.
public struct ImportCsvWorkflow: Sendable {
    public let client: JsBaoClient

    public init(client: JsBaoClient) {
        self.client = client
    }

    /// Start the workflow asynchronously; returns the run handle.
    @discardableResult
    public func start(
        input: ImportCsvInput? = nil,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        forceRerun: Bool? = nil
    ) async throws -> StartWorkflowResult {
        try await client.workflows.start(
            workflowKey: "import-csv",
            input: input,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta,
            forceRerun: forceRerun
        )
    }

    /// Fetch a run's status with a typed `output` bound to `ImportCsvOutput`.
    public func getStatus(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatus<ImportCsvOutput> {
        try await client.workflows.getStatus(
            workflowKey: "import-csv",
            runKey: runKey,
            contextDocId: contextDocId
        )
    }
}

/// Typed invoker factory for the `import-csv` workflow.
public func importCsv(_ client: JsBaoClient) -> ImportCsvWorkflow {
    ImportCsvWorkflow(client: client)
}
