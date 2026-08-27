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

    /// Terminate a run; `output` is bound to `ImportCsvOutput` (a terminated
    /// run can carry partial output).
    @discardableResult
    public func terminate(
        runKey: String,
        contextDocId: String? = nil
    ) async throws -> WorkflowStatus<ImportCsvOutput> {
        try await client.workflows.terminate(
            workflowKey: "import-csv",
            runKey: runKey,
            contextDocId: contextDocId
        )
    }

    /// Register this workflow's apply handler. Emitted only because
    /// `import-csv` is apply-mode (parity with JS). The context's `output`
    /// is the client's untyped `Any?`.
    public func define(onApply: @escaping WorkflowApplyHandler) {
        client.workflows.define("import-csv", onApply: onApply)
    }

    /// Cron triggers scoped to the `import-csv` workflow. The workflow key is
    /// pinned by the helpers below, so a trigger cannot be redirected.
    public var cronTriggers: CronTriggers {
        CronTriggers(client: client)
    }

    /// Typed cron-trigger management for the `import-csv` workflow.
    public struct CronTriggers: Sendable {
        public let client: JsBaoClient

        public init(client: JsBaoClient) {
            self.client = client
        }

        /// Create a cron trigger that fires this workflow.
        @discardableResult
        public func create(
            triggerKey: String,
            displayName: String,
            cron: String,
            timezone: String? = nil,
            description: String? = nil,
            overlapPolicy: CronOverlapPolicy? = nil,
            rootInput: ImportCsvInput? = nil,
            inputMapping: JSONValue? = nil
        ) async throws -> CronTriggerInfo {
            try await client.cronTriggers.create(
                params: CreateCronTriggerParams(
                    triggerKey: triggerKey,
                    displayName: displayName,
                    cron: cron,
                    workflowKey: "import-csv",
                    timezone: timezone,
                    description: description,
                    overlapPolicy: overlapPolicy,
                    rootInput: try rootInput.map { try JSONValue(encoding: $0) },
                    inputMapping: inputMapping
                )
            )
        }

        /// Update a cron trigger that fires this workflow. Omitted fields stay
        /// unchanged; `description` and `rootInput` both remove the stored
        /// value with `.clear`.
        @discardableResult
        public func update(
            triggerId: String,
            displayName: String? = nil,
            description: Updatable<String>? = nil,
            cron: String? = nil,
            timezone: String? = nil,
            overlapPolicy: CronOverlapPolicy? = nil,
            rootInput: Updatable<ImportCsvInput>? = nil,
            inputMapping: JSONValue? = nil
        ) async throws -> CronTriggerInfo {
            let rootInputValue: JSONValue? = try rootInput.map {
                (change: Updatable<ImportCsvInput>) throws -> JSONValue in
                switch change {
                case .clear: return .null
                case let .value(input): return try JSONValue(encoding: input)
                }
            }
            return try await client.cronTriggers.update(
                triggerId: triggerId,
                params: UpdateCronTriggerParams(
                    displayName: displayName,
                    description: description,
                    cron: cron,
                    timezone: timezone,
                    workflowKey: "import-csv",
                    overlapPolicy: overlapPolicy,
                    rootInput: rootInputValue,
                    inputMapping: inputMapping
                )
            )
        }
    }
}

/// Typed invoker factory for the `import-csv` workflow.
public func importCsv(_ client: JsBaoClient) -> ImportCsvWorkflow {
    ImportCsvWorkflow(client: client)
}
