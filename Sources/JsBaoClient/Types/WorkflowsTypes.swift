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
    /// ISO-8601 timestamp stamped when the run started. Mirrors JS
    /// `WorkflowRun.startedAt`. Decoded when present.
    public let startedAt: String?
    /// #1367 — ISO-8601 timestamp of the true execution start, stamped once
    /// Cloudflare actually schedules the instance. `nil`/absent while the run is
    /// still queued (`startedAt` remains the request time). Mirrors JS
    /// `WorkflowRun.executionStartedAt`. Decoded when present.
    public let executionStartedAt: String?
    /// #1367 — derived queue delay in ms (`executionStartedAt − startedAt`), i.e.
    /// how long the run sat queued before executing. `nil` while still queued.
    /// Mirrors JS `WorkflowRun.queueDelayMs`. Decoded when present.
    public let queueDelayMs: Int?
    /// #1367 — wall-clock ms the `env.WORKFLOW_APP.create()` call itself took.
    /// `nil` for runs started via a path that does not record it. Mirrors JS
    /// `WorkflowRun.createCallDurationMs`. Decoded when present.
    public let createCallDurationMs: Int?
    public let endedAt: String?
    /// Error message when `status == "failed"`, `null` otherwise. Mirrors JS
    /// `WorkflowRun.errorMessage`. Decoded when present.
    public let errorMessage: String?
    /// #2636 — the platform's classification of this failure, from a closed
    /// set it owns: `"LOCK_CONTENTION"` when the run lost a declarative-lock
    /// race under `onContention: "fail"`, `"LOCK_TIMEOUT"` when it exhausted an
    /// `onContention: "block"` budget. `nil` when the run did not fail, and for
    /// a failure the platform did not classify. Branch on this rather than on
    /// `errorMessage` text. Mirrors JS `WorkflowRun.errorCode`. Decoded when
    /// present.
    public let errorCode: String?
    /// #2636 — why an elided run did not run: `"LOCK_CONTENTION"` when its
    /// declarative lock was held and the definition declared
    /// `onContention: "ignore"`. Only ever set on a run whose `status` is
    /// `"skipped"`; such a run carries no `errorMessage` and produces no error
    /// analytics — it is a visible record that the work was not done, not a
    /// failure. Mirrors JS `WorkflowRun.skipReason`. Decoded when present.
    public let skipReason: String?
    /// #2074 — normalized form of `errorMessage`, with ids, numbers, URLs and
    /// quoted literals replaced by placeholder tokens, so runs that failed for
    /// the same reason share one title you can group on. It is also the string
    /// `analytics errors-groups` titles its groups with. `nil` when the run did
    /// not fail. Mirrors JS `WorkflowRun.errorTitle`. Decoded when present.
    public let errorTitle: String?
    /// #2074 — id of the step that failed the run: the lowest-index step whose
    /// status is `failed`.
    ///
    /// A durable run (`workflows.start()`) that aborted during setup, before
    /// any of its own steps ran, reads `"__setup__"` with
    /// `failedStepKind == "setup"` — a synthetic step, so it will not be found
    /// in the workflow definition. The same abort on a `syncCallable` workflow
    /// (`workflows.runSync()`) reads `nil` here, with the reason still in
    /// `errorMessage`.
    ///
    /// `nil` when the run did not fail, and for the failures that hold no step
    /// results at all: a run rejected at launch, a run reclaimed after its
    /// executor died, or one whose output failed schema validation after every
    /// step completed. Mirrors JS `WorkflowRun.failedStepId`. Decoded when
    /// present.
    public let failedStepId: String?
    /// #2074 — kind of the failed step (`"database.query"`, `"llm"`,
    /// `"setup"` for the synthetic setup-phase step of a durable run, …).
    /// `nil` whenever `failedStepId` is `nil`. Mirrors JS
    /// `WorkflowRun.failedStepKind`. Decoded when present.
    public let failedStepKind: String?
    /// #2074 — normalized title of the failed step's own error, for grouping
    /// failures by step-level cause. `nil` whenever `failedStepId` is `nil`.
    /// Mirrors JS `WorkflowRun.failedStepErrorTitle`. Decoded when present.
    public let failedStepErrorTitle: String?
    /// User-defined metadata attached to the run (max 1 KB). Opaque blob.
    public let meta: JSONValue?
    /// User who started the run, when the server records it. Not present in
    /// the JS `WorkflowRun` interface but surfaced on some run envelopes;
    /// decoded when present so the apply flow can read it.
    public let startedByUserId: String?

    private enum CodingKeys: String, CodingKey {
        case runId, runKey, instanceId, workflowId, workflowKey
        case revisionId, contextDocId, status, createdAt, startedAt
        case executionStartedAt, queueDelayMs, createCallDurationMs, endedAt
        case errorMessage, errorTitle, errorCode, skipReason
        case failedStepId, failedStepKind, failedStepErrorTitle
        case meta
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
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        executionStartedAt = try c.decodeIfPresent(String.self, forKey: .executionStartedAt)
        queueDelayMs = try c.decodeIfPresent(Int.self, forKey: .queueDelayMs)
        createCallDurationMs = try c.decodeIfPresent(Int.self, forKey: .createCallDurationMs)
        endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        errorTitle = try c.decodeIfPresent(String.self, forKey: .errorTitle)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        skipReason = try c.decodeIfPresent(String.self, forKey: .skipReason)
        failedStepId = try c.decodeIfPresent(String.self, forKey: .failedStepId)
        failedStepKind = try c.decodeIfPresent(String.self, forKey: .failedStepKind)
        failedStepErrorTitle = try c.decodeIfPresent(
            String.self, forKey: .failedStepErrorTitle)
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

// MARK: Task slice record

/// The task slice's record, under the workflow surface's old name.
///
/// The struct itself now lives on the FUNCTIONS surface as
/// ``FunctionRunSlice`` — only a function run has a slice record, and the
/// workflow surface is being retired, so the owner is the surface that
/// outlives it. This alias is what the workflow types still read through;
/// deleting them deletes this line and nothing else.
public typealias WorkflowSliceInfo = FunctionRunSlice

// MARK: Status / terminate

/// Result of `getStatus` and `terminate`. Mirrors JS `WorkflowStatusResult`.
///
/// `status` is the server's single reconciled run status; `run` is the
/// persisted DB record.
///
/// #2348 — the server returns exactly one canonical vocabulary on the wire, and
/// the client uses it verbatim:
///
/// `queued` | `running` | `apply_pending` | `apply_claimed` | `completed` |
/// `failed` | `terminated` | `missing`
///
/// Raw Cloudflare spellings (`complete`, `errored`) no longer reach the client,
/// and a terminal run is never rolled back to `running`. It stays a plain
/// `String` rather than a closed enum so a future server-added state can never
/// turn a status read into a decode failure — same reasoning as every other
/// Swift workflow status field.
/// Why a run failed, structured — #3449.
///
/// The status routes answer `status.error` as an object for every failed
/// durable run, DSL or function: `{ name: "WorkflowError", message }` where
/// the platform built it, and the thrown error's own name beside its message
/// where Cloudflare recorded it. `name` is NOT the platform's error code — a
/// refusal leads its MESSAGE with the code (`OUTPUT_SCHEMA_VIOLATION: …`) and
/// reports `name` as `Error`, and the deployed engine drops the name
/// altogether. Read `message`; `name` is a hint.
///
/// Field for field with the JS client's `WorkflowRunError`.
public struct WorkflowRunError: Decodable, Sendable, Equatable {
    /// The error's own name, when the wire carried one.
    public let name: String?
    /// What went wrong. A failed run the client publishes is one it can
    /// describe, so this is never absent.
    public let message: String
    /// Whatever else the wire object carried, key for key.
    ///
    /// Always a JSON OBJECT when present. A wire `details` is one of those
    /// remaining keys like any other, so an error sending `details: ["x"]`
    /// reads here as `details` containing `{"details": ["x"]}` — the array is
    /// kept where it was rather than promoted over the map it lives in. `nil`
    /// when the object carried nothing besides `name` and `message`.
    public let details: JSONValue?

    public init(name: String?, message: String, details: JSONValue? = nil) {
        self.name = name
        self.message = message
        self.details = details
    }

    /// Read a raw `status.error` value, or `nil` when there is none to
    /// publish.
    ///
    /// A wrapper over ``RunErrorEnvelope/read(_:)``, which owns the parsing
    /// and the rule behind it: never throws, never fails the read around it,
    /// and treats anything it cannot vouch for as "no error the client can
    /// describe". The parser sits on the functions surface because this one
    /// is being retired — when it goes, this wrapper goes with it and the
    /// parser stays.
    static func read(_ value: JSONValue?) -> WorkflowRunError? {
        guard let base = RunErrorEnvelope.read(value) else { return nil }
        return WorkflowRunError(
            name: base.name,
            message: base.message,
            details: base.details
        )
    }
}

public struct WorkflowStatusResult: Decodable, Sendable, Equatable {
    /// The server's canonical run status. See the type doc for the vocabulary.
    public let status: String
    /// Final output of the run, when present. Opaque blob.
    public let output: JSONValue?
    /// The failure's MESSAGE, whichever form the server sent (#3449).
    ///
    /// Still `String?`, so every call site that printed it keeps compiling —
    /// and starts receiving a value where it used to get a throw. The string
    /// form arrives verbatim; the object form reads its `message`. See
    /// {@link failure} for the structured value.
    public let error: String?
    /// The same failure, structured (#3449). `nil` for a run that has not
    /// failed, and for a value the client could not read.
    public let failure: WorkflowRunError?
    /// #2636 — why the run did not run, when `status == "skipped"`. The server
    /// sends it next to the status and on the run record; either satisfies it.
    public let skipReason: String?
    public let run: WorkflowRunInfo?
    /// #3381/#3388 — the run's task slice record, a sibling of `status` and
    /// `run` on the wire. `nil` for a request invocation and for a DSL
    /// workflow run, which carry no `slice` key. Same field, same seven
    /// values, as the JS client's `WorkflowStatusResult.slice?`.
    public let slice: WorkflowSliceInfo?

    private enum CodingKeys: String, CodingKey {
        case status, output, error, run, skipReason, slice
    }

    /// The keys of the Cloudflare workflow status object the server nests
    /// under `status`: `{ status, output, error, skipReason }`. JS's
    /// `getWorkflowStatus` reads them off that object and flattens them onto
    /// the result — we mirror that flattening at decode time.
    ///
    /// #3449 — decoded FIELD BY FIELD through a nested container rather than
    /// as one `try?`-wrapped struct. As one struct, an `error` that did not
    /// match its declared type made the whole block `nil`, the decoder fell
    /// into the bare-string branch below, and re-reading `status` as a String
    /// threw `typeMismatch` on the dictionary — a surprise in ONE field cost
    /// the caller the entire response. Field by field, it cannot.
    private enum CFStatusKeys: String, CodingKey {
        case status, output, error, skipReason
    }

    /// Memberwise init, for constructing a result directly (tests, callers
    /// assembling a status from parts). The `status` the server sends is used
    /// verbatim by `getStatus` / `getStatusByRunId` — the client does not
    /// re-derive it (#2348).
    public init(
        status: String,
        output: JSONValue?,
        error: String?,
        run: WorkflowRunInfo?,
        skipReason: String? = nil,
        // Trailing with a default so every pre-#3388 memberwise call still
        // compiles: the block is additive here exactly as it is on the wire.
        slice: WorkflowSliceInfo? = nil,
        // #3449, same rule. A caller assembling a result from a message alone
        // gets the structured value derived from it rather than nothing, so
        // the two fields cannot silently disagree.
        failure: WorkflowRunError? = nil
    ) {
        self.status = status
        self.output = output
        self.error = error
        self.run = run
        self.skipReason = skipReason
        self.slice = slice
        self.failure =
            failure ?? error.map { WorkflowRunError(name: nil, message: $0, details: nil) }
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
        //
        // #3449 — the raw `error` is read as a JSON VALUE at both levels,
        // because it is one: an object for every failed durable run, `null`
        // on a read that has not failed, and a string on the older form.
        var nestedSkipReason: String? = nil
        var rawError: JSONValue? = nil
        if let nested = try? c.nestedContainer(keyedBy: CFStatusKeys.self, forKey: .status) {
            // Field by field, each tolerant of its OWN surprise and of nothing
            // else: a `status` that is not a string reads `""`, and neither it
            // nor a surprising `error` can cost the caller the rest of the
            // response. Each `try?` is annotated with the optional type it
            // produces, so the fallbacks below are live rather than dead.
            let nestedStatus: String? =
                try? nested.decodeIfPresent(String.self, forKey: .status)
            status = nestedStatus ?? ""
            let nestedOutput: JSONValue? =
                try? nested.decodeIfPresent(JSONValue.self, forKey: .output)
            output = try nestedOutput ?? c.decodeIfPresent(JSONValue.self, forKey: .output)
            let nestedError: JSONValue? =
                try? nested.decodeIfPresent(JSONValue.self, forKey: .error)
            rawError =
                try nestedError ?? c.decodeIfPresent(JSONValue.self, forKey: .error)
            nestedSkipReason =
                try? nested.decodeIfPresent(String.self, forKey: .skipReason)
        } else {
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            output = try c.decodeIfPresent(JSONValue.self, forKey: .output)
            rawError = try c.decodeIfPresent(JSONValue.self, forKey: .error)
        }
        // One rule for both branches, and the same one the JS client's
        // `readWorkflowRunError` applies: an already-flattened payload's
        // top-level `error` object decodes exactly as a nested one does.
        let readFailure = WorkflowRunError.read(rawError)
        failure = readFailure
        error = readFailure?.message
        run = try c.decodeIfPresent(WorkflowRunInfo.self, forKey: .run)
        // #2636 — the reason rides next to the status and on the run record.
        let topLevelSkipReason = try c.decodeIfPresent(
            String.self, forKey: .skipReason)
        skipReason = nestedSkipReason ?? topLevelSkipReason ?? run?.skipReason
        // #3388 — the slice block is OBSERVABILITY, never the answer: a block
        // whose shape surprises this client is dropped rather than turned into
        // a failed status read, the same reading the server takes when it
        // cannot read the record (`readSliceBlock` returns null instead of
        // 500ing the route).
        slice = (try? c.decodeIfPresent(WorkflowSliceInfo.self, forKey: .slice)) ?? nil
    }
}

// MARK: List runs

/// A page of workflow runs with an optional pagination cursor. Mirrors JS
/// `ListWorkflowRunsResult`.
public struct ListWorkflowRunsResult: Decodable, Sendable, Equatable {
    public let items: [WorkflowRunInfo]
    /// Continuation token for the next page (#1316).
    public let nextCursor: String?
    /// True when a next page exists (#1316).
    public let hasMore: Bool
    /// Deprecated alias of `nextCursor` kept for one deprecation window
    /// (#1316, #1982). Computed from `nextCursor` so the type's own
    /// initializers never reference the deprecated declaration.
    @available(*, deprecated, message: "Use nextCursor.")
    public var cursor: String? { nextCursor }
    /// How many runs the server examined to produce this page (#2237).
    ///
    /// A `status`-filtered listing cannot be served by the index, so the server
    /// walks recent runs under a fixed budget. With `nextCursor` this tells a
    /// short page apart from a complete answer: no `nextCursor` means the walk
    /// reached the end of history; a `nextCursor` with fewer items than
    /// requested means it stopped at its budget after `scanned` runs and more
    /// history remains. `nil` on unfiltered listings, on `contextDocId`
    /// listings (that view spans every user's runs against the document, so its
    /// row count is not the caller's to see), and against a server that
    /// predates the field — treat it as "unknown", never as zero.
    public let scanned: Int?

    private enum CodingKeys: String, CodingKey {
        case items, cursor, nextCursor, hasMore, scanned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([WorkflowRunInfo].self, forKey: .items) ?? []
        // #1316: prefer `nextCursor`; `cursor` is the deprecated alias.
        let next = try c.decodeIfPresent(String.self, forKey: .nextCursor)
            ?? c.decodeIfPresent(String.self, forKey: .cursor)
        nextCursor = next
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? (next != nil)
        // Optional so an older server still decodes.
        scanned = try c.decodeIfPresent(Int.self, forKey: .scanned)
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
    /// `completed` | `failed` | `terminated` | `timeout` | `apply_pending` |
    /// `skipped`.
    public let status: String
    /// Final output when `status == "completed"`.
    public let output: JSONValue?
    /// Error message when `status == "failed"`.
    public let error: String?
    /// #2636 — why the workflow did not run, when `status == "skipped"`: its
    /// declarative lock was held and the definition declared
    /// `onContention: "ignore"`. The envelope then carries neither `output` nor
    /// `error`.
    public let skipReason: String?
    /// Persisted run record (present on success).
    public let run: WorkflowRunInfo?
    /// `true` if `runKey` matched an existing run (no new execution occurred).
    public let existing: Bool?
}

// MARK: - Typed workflow results (#1547, Phase 3)
//
// The generic `WorkflowsAPI` overloads (`runSync<Input,Output>` /
// `getStatus<Output>`) return these typed envelopes: identical to the untyped
// `RunSyncWorkflowResult` / `WorkflowStatusResult` above but with the opaque
// `output` blob decoded into the generated `<Key>Output` type. They mirror the
// JS client's `RunSyncWorkflowResult<O>` / `WorkflowStatusResult<O>` generics
// (Swift structs cannot carry a defaulted generic parameter, so these are named
// mirrors rather than the same symbol). Constructed by the API layer from the
// untyped result, so no bespoke decode logic diverges from the untyped path.

/// Typed result envelope from the generic `workflows.runSync`. Mirrors JS
/// `RunSyncWorkflowResult<O>` — every field matches `RunSyncWorkflowResult`
/// except `output`, which is decoded into `Output`.
public struct RunSyncResult<Output: Decodable & Sendable>: Sendable {
    public let runId: String
    public let runKey: String
    /// `completed` | `failed` | `terminated` | `timeout` | `apply_pending` |
    /// `skipped`.
    public let status: String
    /// Final output decoded into `Output` when `status == "completed"` (and the
    /// server returned a non-null output); `nil` otherwise.
    public let output: Output?
    /// Error message when `status == "failed"`.
    public let error: String?
    /// #2636 — why the workflow did not run, when `status == "skipped"`: its
    /// declarative lock was held and the definition declared
    /// `onContention: "ignore"`. The result then carries neither `output` nor
    /// `error`. Branch on this rather than on message text — the typed
    /// envelope carries it for the same reason the untyped one does.
    public let skipReason: String?
    /// Persisted run record (present on success).
    public let run: WorkflowRunInfo?
    /// `true` if `runKey` matched an existing run (no new execution occurred).
    public let existing: Bool?

    public init(
        runId: String,
        runKey: String,
        status: String,
        output: Output?,
        error: String?,
        run: WorkflowRunInfo?,
        existing: Bool?,
        // Trailing with a default so the pre-#2636 memberwise call still
        // compiles for anyone constructing one of these directly.
        skipReason: String? = nil
    ) {
        self.runId = runId
        self.runKey = runKey
        self.status = status
        self.output = output
        self.error = error
        self.run = run
        self.existing = existing
        self.skipReason = skipReason
    }
}

/// Typed result of the generic `workflows.getStatus`. Mirrors JS
/// `WorkflowStatusResult<O>` — same fields as `WorkflowStatusResult` except
/// `output`, which is decoded into `Output`. `status` is the server's canonical
/// run status (#2348); `run` is the persisted DB record.
public struct WorkflowStatus<Output: Decodable & Sendable>: Sendable {
    public let status: String
    /// Final output decoded into `Output` when present; `nil` otherwise.
    public let output: Output?
    /// The failure's message, forwarded from the untyped result (#3449).
    public let error: String?
    /// The structured failure, forwarded from the untyped result (#3449).
    /// Typing the `output` blob must not cost a caller the reason it failed.
    public let failure: WorkflowRunError?
    /// #2636 — why the run did not run, when `status == "skipped"`. Forwarded
    /// from the untyped result, which reads it from wherever the server put it
    /// (next to the status, or on the run record).
    public let skipReason: String?
    public let run: WorkflowRunInfo?
    /// #3388 — the run's task slice record, forwarded from the untyped result.
    /// Typing the `output` blob must not cost a caller the block beside it.
    public let slice: WorkflowSliceInfo?

    public init(
        status: String,
        output: Output?,
        error: String?,
        run: WorkflowRunInfo?,
        skipReason: String? = nil,
        slice: WorkflowSliceInfo? = nil,
        failure: WorkflowRunError? = nil
    ) {
        self.status = status
        self.output = output
        self.error = error
        self.run = run
        self.skipReason = skipReason
        self.slice = slice
        self.failure =
            failure ?? error.map { WorkflowRunError(name: nil, message: $0, details: nil) }
    }
}

// MARK: - waitFor (#1443 / #1582)
//
// Ports the JS client's `workflows.waitFor` (#1443). A workflow completion that
// occurs while the socket is down (iOS backgrounding, offline, reconnecting) is
// still delivered after reconnect — instead of depending on a single, never-
// replayed `workflowStatus` WS frame. See `WorkflowsAPI.waitFor`.

/// Options for `WorkflowsAPI.waitFor`. Mirrors JS `WaitForWorkflowOptions`.
public struct WaitForWorkflowOptions: Sendable {
    /// Maximum time to wait for the run to reach a terminal state before
    /// throwing a `.workflowWaitTimeout` `JsBaoError`. Defaults to 15 minutes.
    ///
    /// Set to `0` (or any non-positive value) to disable the timeout entirely.
    /// WARNING: with no timeout the call (and its `workflowStatus`/`status`
    /// listeners) lives until the run terminates — only use this for runs you
    /// know will end.
    public var timeout: TimeInterval?

    public init(timeout: TimeInterval? = nil) {
        self.timeout = timeout
    }
}

/// Result from `WorkflowsAPI.waitFor`. Resolved once the run reaches a terminal
/// state. Mirrors JS `WaitForWorkflowResult`.
///
/// `status` is a plain `String` (not a closed enum) so a future server-added
/// terminal-like state never turns "workflow finished" into a decode failure —
/// matching every other Swift workflow status field. It is one of
/// `completed` / `failed` / `terminated` / `apply_pending` / `apply_claimed` /
/// `skipped` (never `running`). Use `isTerminal` / `isFailure` for common
/// checks.
public struct WaitForWorkflowResult: Sendable {
    /// Terminal status of the run. Never `running`.
    public let status: String
    /// Final output of the run, when available. Opaque blob.
    public let output: JSONValue?
    /// Error message when `status == "failed"`.
    public let error: String?
    /// The structured failure, when `status == "failed"` (#3449). Carried by
    /// every path that settles a wait — the poll, the finalization re-check,
    /// and the terminal `workflowStatus` frame — so a caller reporting a
    /// failure does not have to know which one settled it.
    public let failure: WorkflowRunError?
    /// #2636 — why the run did not run, when `status == "skipped"`
    /// (`"LOCK_CONTENTION"`). `nil` for every other status.
    public let skipReason: String?

    public init(
        status: String,
        output: JSONValue?,
        error: String?,
        skipReason: String? = nil,
        failure: WorkflowRunError? = nil
    ) {
        self.status = status
        self.output = output
        self.error = error
        self.skipReason = skipReason
        // The frame path carries a STRING error, so a caller (and that path)
        // gets the structured value derived from it rather than nothing.
        self.failure =
            failure ?? error.map { WorkflowRunError(name: nil, message: $0, details: nil) }
    }

    /// `true` for any terminal-for-waiting status. Always `true` on a resolved
    /// `waitFor` result (it only settles on a terminal state) — provided for
    /// call-site clarity.
    public var isTerminal: Bool { Self.terminalStatuses.contains(status) }

    /// `true` when the run reported failure (`status == "failed"`). A failed run
    /// resolves normally (does not throw), so branch on this rather than a
    /// `catch`.
    public var isFailure: Bool { status == "failed" }

    /// #2636 — `skipped` belongs here: an elided run (its declarative lock was
    /// held and the definition declared `onContention: "ignore"`) is settled and
    /// will never advance, so a set without it makes `waitFor` keep waiting
    /// until its own timeout.
    static let terminalStatuses: Set<String> = [
        "completed", "failed", "terminated", "apply_pending", "apply_claimed",
        "skipped",
    ]
}

/// Typed result of the generic `WorkflowsAPI.waitFor` overload. Mirrors
/// `WaitForWorkflowResult` but with the opaque `output` blob decoded into
/// `Output`. Named separately from `WaitForWorkflowResult` because Swift does
/// not allow a generic and a non-generic type to share a name — same split as
/// `RunSyncWorkflowResult` / `RunSyncResult<Output>`.
public struct WaitForResult<Output: Decodable & Sendable>: Sendable {
    /// Terminal status of the run. Never `running`.
    public let status: String
    /// Final output decoded into `Output` when present; `nil` otherwise.
    public let output: Output?
    /// Error message when `status == "failed"`.
    public let error: String?
    /// The structured failure, forwarded from the untyped result (#3449).
    public let failure: WorkflowRunError?
    /// #2636 — why the run did not run, when `status == "skipped"`.
    public let skipReason: String?

    public init(
        status: String,
        output: Output?,
        error: String?,
        skipReason: String? = nil,
        failure: WorkflowRunError? = nil
    ) {
        self.status = status
        self.output = output
        self.error = error
        self.skipReason = skipReason
        self.failure =
            failure ?? error.map { WorkflowRunError(name: nil, message: $0, details: nil) }
    }

    /// See `WaitForWorkflowResult.isTerminal`.
    public var isTerminal: Bool { WaitForWorkflowResult.terminalStatuses.contains(status) }
    /// See `WaitForWorkflowResult.isFailure`.
    public var isFailure: Bool { status == "failed" }
}
