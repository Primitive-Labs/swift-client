import Foundation

// MARK: - Workflows: typed request & response models
//
// These mirror the workflow interfaces published by the JS client
// (they live on `JsBaoClient.d.ts`, not a dedicated `workflowsApi.d.ts`)
// so the two surfaces line up field-for-field. Timestamps stay as
// ISO-8601 `String`s — exactly what JS exposes. Opaque, platform-untouched
// blobs (`input`, `output`, `meta`, rendered step config, …) are typed as
// `JSONValue` (see JSONValue.swift) rather than `[String: Any]`, so they
// decode losslessly and `getStatus`/`listRuns`/etc. now THROW on a shape
// mismatch instead of silently coercing to `[:]` (#991).
//
// `StartWorkflowOptions` and `ListWorkflowRunsOptions` predate this file and
// live in Options.swift (they carry a non-`Codable` `[String: Any]` `meta`
// and are shared with the existing call sites); they are intentionally NOT
// redeclared here.

// MARK: Workflow run record

/// A persisted workflow run record. Mirrors JS `WorkflowRun`.
public struct WorkflowRunInfo: Decodable, Sendable, Equatable {
    public let runId: String
    public let runKey: String
    public let instanceId: String?
    public let workflowId: String?
    public let workflowKey: String?
    public let revisionId: String?
    public let contextDocId: String?
    public let status: String
    public let createdAt: String?
    public let endedAt: String?
    /// User-defined metadata attached to the run (max 1 KB). Opaque blob.
    public let meta: JSONValue?
    /// User who started the run, when the server records it. Not present in
    /// the JS `WorkflowRun` interface but surfaced on some run envelopes;
    /// decoded when present so the apply flow can read it.
    public let startedByUserId: String?

    private enum CodingKeys: String, CodingKey {
        case runId, runKey, instanceId, workflowId, workflowKey
        case revisionId, contextDocId, status, createdAt, endedAt, meta
        case startedByUserId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decodeIfPresent(String.self, forKey: .runId) ?? ""
        runKey = try c.decodeIfPresent(String.self, forKey: .runKey) ?? ""
        instanceId = try c.decodeIfPresent(String.self, forKey: .instanceId)
        workflowId = try c.decodeIfPresent(String.self, forKey: .workflowId)
        workflowKey = try c.decodeIfPresent(String.self, forKey: .workflowKey)
        revisionId = try c.decodeIfPresent(String.self, forKey: .revisionId)
        contextDocId = try c.decodeIfPresent(String.self, forKey: .contextDocId)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt)
        meta = try c.decodeIfPresent(JSONValue.self, forKey: .meta)
        startedByUserId = try c.decodeIfPresent(String.self, forKey: .startedByUserId)
    }
}

// MARK: Start

/// Result of `start`. Mirrors JS `StartWorkflowResult`.
public struct StartWorkflowResult: Decodable, Sendable, Equatable {
    public let runId: String
    public let runKey: String
    public let instanceId: String?
    public let status: String
    /// `true` if the `runKey` matched an existing run and that run was
    /// returned instead of starting a new execution.
    public let existing: Bool?

    private enum CodingKeys: String, CodingKey {
        case runId, runKey, instanceId, status, existing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decodeIfPresent(String.self, forKey: .runId) ?? ""
        runKey = try c.decodeIfPresent(String.self, forKey: .runKey) ?? ""
        instanceId = try c.decodeIfPresent(String.self, forKey: .instanceId)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        existing = try c.decodeIfPresent(Bool.self, forKey: .existing)
    }
}

// MARK: Status / terminate

/// Result of `getStatus` and `terminate`. Mirrors JS `WorkflowStatusResult`.
///
/// `status` is the Cloudflare workflow status; `run` is the persisted DB
/// record (its `status` carries the `apply_*` states).
public struct WorkflowStatusResult: Decodable, Sendable, Equatable {
    public let status: String
    /// Final output of the run, when present. Opaque blob.
    public let output: JSONValue?
    public let error: String?
    public let run: WorkflowRunInfo?

    private enum CodingKeys: String, CodingKey {
        case status, output, error, run
    }

    /// The Cloudflare workflow status object the server nests under `status`:
    /// `{ status, output, error }`. JS's `getWorkflowStatus` reads
    /// `rawStatus.status` / `.output` / `.error` off this object and flattens
    /// them onto the result — we mirror that flattening at decode time.
    private struct CFWorkflowStatus: Decodable {
        let status: String?
        let output: JSONValue?
        let error: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The server returns `{ status: <CF status object>, run }`, where the
        // CF status object is `{ status, output, error }` — NOT a bare status
        // string. JS's `getWorkflowStatus` flattens it (cfStatus =
        // rawStatus.status, output = rawStatus.output, error = rawStatus.error).
        // We do the same. Defensive fallback: tolerate `status` arriving as a
        // bare string (direct construction / already-flattened payloads), and
        // top-level `output`/`error` for the same reason.
        if let cf = (try? c.decodeIfPresent(CFWorkflowStatus.self, forKey: .status)) ?? nil {
            status = cf.status ?? ""
            output = try cf.output ?? c.decodeIfPresent(JSONValue.self, forKey: .output)
            error = try cf.error ?? c.decodeIfPresent(String.self, forKey: .error)
        } else {
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            output = try c.decodeIfPresent(JSONValue.self, forKey: .output)
            error = try c.decodeIfPresent(String.self, forKey: .error)
        }
        run = try c.decodeIfPresent(WorkflowRunInfo.self, forKey: .run)
    }
}

// MARK: List runs

/// A page of workflow runs with an optional pagination cursor. Mirrors JS
/// `ListWorkflowRunsResult`.
public struct ListWorkflowRunsResult: Decodable, Sendable, Equatable {
    public let items: [WorkflowRunInfo]
    public let cursor: String?

    private enum CodingKeys: String, CodingKey { case items, cursor }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([WorkflowRunInfo].self, forKey: .items) ?? []
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
    }
}

// MARK: Step runs

/// A persisted step-run record with debugging data. Mirrors JS
/// `WorkflowStepRunRecord`. The various config / input / output / context
/// fields the platform does not introspect are typed as `JSONValue`.
public struct WorkflowStepRunRecord: Decodable, Sendable, Equatable {
    public let stepRunId: String
    public let runId: String
    public let stepIndex: Int?
    public let stepId: String?
    public let stepKind: String?
    /// `completed` | `failed` | `skipped`.
    public let status: String
    /// Rendered step config (after template evaluation).
    public let config: JSONValue?
    /// Original step config before template rendering (transform steps).
    public let rawConfig: JSONValue?
    public let input: JSONValue?
    public let output: JSONValue?
    public let error: String?
    public let errorDetails: JSONValue?
    public let startedAt: String?
    public let endedAt: String?
    public let durationMs: Double?
    public let inputTokens: Double?
    public let outputTokens: Double?
    public let totalTokens: Double?
    public let retryCount: Double?
    /// Snapshot of input + previous step outputs at the time this step ran.
    public let context: JSONValue?
    /// Template warnings captured during step execution.
    public let templateWarnings: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case stepRunId, runId, stepIndex, stepId, stepKind, status
        case config, rawConfig, input, output, error, errorDetails
        case startedAt, endedAt, durationMs, inputTokens, outputTokens
        case totalTokens, retryCount, context, templateWarnings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stepRunId = try c.decodeIfPresent(String.self, forKey: .stepRunId) ?? ""
        runId = try c.decodeIfPresent(String.self, forKey: .runId) ?? ""
        stepIndex = try c.decodeIfPresent(Int.self, forKey: .stepIndex)
        stepId = try c.decodeIfPresent(String.self, forKey: .stepId)
        stepKind = try c.decodeIfPresent(String.self, forKey: .stepKind)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        config = try c.decodeIfPresent(JSONValue.self, forKey: .config)
        rawConfig = try c.decodeIfPresent(JSONValue.self, forKey: .rawConfig)
        input = try c.decodeIfPresent(JSONValue.self, forKey: .input)
        output = try c.decodeIfPresent(JSONValue.self, forKey: .output)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        errorDetails = try c.decodeIfPresent(JSONValue.self, forKey: .errorDetails)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt)
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs)
        inputTokens = try c.decodeIfPresent(Double.self, forKey: .inputTokens)
        outputTokens = try c.decodeIfPresent(Double.self, forKey: .outputTokens)
        totalTokens = try c.decodeIfPresent(Double.self, forKey: .totalTokens)
        retryCount = try c.decodeIfPresent(Double.self, forKey: .retryCount)
        context = try c.decodeIfPresent(JSONValue.self, forKey: .context)
        templateWarnings = try c.decodeIfPresent(JSONValue.self, forKey: .templateWarnings)
    }
}

/// Result of `listStepRuns`. Mirrors JS `ListWorkflowStepRunsResult`.
public struct ListWorkflowStepRunsResult: Decodable, Sendable, Equatable {
    public let items: [WorkflowStepRunRecord]

    private enum CodingKeys: String, CodingKey { case items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([WorkflowStepRunRecord].self, forKey: .items) ?? []
    }
}

// MARK: Apply flow results

/// Result of `claimApply`. Mirrors JS `ClaimApplyResult`. `reason` carries
/// the refusal taxonomy (`already_claimed`, `not_apply_pending`, …) when
/// `claimed == false`.
public struct ClaimApplyResult: Decodable, Sendable, Equatable {
    public let claimed: Bool
    public let reason: String?

    private enum CodingKeys: String, CodingKey { case claimed, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claimed = try c.decodeIfPresent(Bool.self, forKey: .claimed) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// Result of `confirmApply`. Mirrors JS `ConfirmApplyResult`.
public struct ConfirmApplyResult: Decodable, Sendable, Equatable {
    public let confirmed: Bool
    public let reason: String?

    private enum CodingKeys: String, CodingKey { case confirmed, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// Result of `releaseApply`. Mirrors JS `ReleaseApplyResult`.
public struct ReleaseApplyResult: Decodable, Sendable, Equatable {
    public let released: Bool
    public let reason: String?

    private enum CodingKeys: String, CodingKey { case released, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        released = try c.decodeIfPresent(Bool.self, forKey: .released) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// A single pending-apply entry returned by `getPendingApplies`. The JS
/// surface types this as `any[]`; the Swift surface decodes the run-shaped
/// fields the apply flow reads (`workflowKey`, `runKey`, `runId`,
/// `contextDocId`, `meta`, `startedByUserId`) while keeping the rest opaque.
public struct PendingApplyInfo: Decodable, Sendable, Equatable {
    public let workflowKey: String?
    public let workflowId: String?
    public let runKey: String?
    public let runId: String?
    public let contextDocId: String?
    public let meta: JSONValue?
    public let startedByUserId: String?

    private enum CodingKeys: String, CodingKey {
        case workflowKey, workflowId, runKey, runId, contextDocId
        case meta, startedByUserId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workflowKey = try c.decodeIfPresent(String.self, forKey: .workflowKey)
        workflowId = try c.decodeIfPresent(String.self, forKey: .workflowId)
        runKey = try c.decodeIfPresent(String.self, forKey: .runKey)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        contextDocId = try c.decodeIfPresent(String.self, forKey: .contextDocId)
        meta = try c.decodeIfPresent(JSONValue.self, forKey: .meta)
        startedByUserId = try c.decodeIfPresent(String.self, forKey: .startedByUserId)
    }
}

// MARK: Run-sync

/// Result envelope from `workflows.runSync` (#728/#956). All non-transport
/// outcomes resolve with this shape; only connectivity errors `throw`.
public struct RunSyncWorkflowResult: Decodable, Sendable {
    public let runId: String
    public let runKey: String
    /// `completed` | `failed` | `terminated` | `timeout` | `apply_pending`.
    public let status: String
    /// Final output when `status == "completed"`.
    public let output: JSONValue?
    /// Error message when `status == "failed"`.
    public let error: String?
    /// Persisted run record (present on success).
    public let run: WorkflowRunInfo?
    /// `true` if `runKey` matched an existing run (no new execution occurred).
    public let existing: Bool?
}
