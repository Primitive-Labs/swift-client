import Foundation

// MARK: - Server functions: the run status, in function vocabulary (#3565)
//
// `client.functions` answered the WORKFLOW status types, so a Swift caller
// polling a function run read a `skipReason` and a `run.workflowId` the server
// can never set for a function, and a missing run reported itself as a missing
// WORKFLOW run. Polling the workflow run routes stays an implementation
// choice; these are what the caller sees instead.
//
// Field for field with the JS client's `FunctionRunStatus` and its readers
// (`src/client/internal/functionRunStatus.ts`), so the two clients answer the
// same block — which on this side is enforced by construction, because Swift
// can only decode the keys it declares.

/// Why a function run failed. The ONE structured error on this surface.
///
/// The workflow type carries two fields for this — a message on `error` and a
/// normalized `failure` beside it — because principle 5 forbade moving a
/// published value. This is a new type, so it has one.
public struct FunctionRunError: Decodable, Sendable, Equatable {
    /// The thrown error's own NAME, when the engine preserved one (`Error`,
    /// `TypeError`, a tenant's own class).
    ///
    /// `nil` for a failure read off the persisted row: the platform keeps only
    /// the message there and labels it `WorkflowError`, which is a placeholder
    /// rather than a name, so this client drops it. Also `nil` whenever the
    /// engine dropped the name, which the deployed engine does. NEVER the
    /// platform's code — read ``code`` for that.
    public let name: String?
    /// What went wrong. A failure the client publishes is one it can describe,
    /// so this is never absent. A platform refusal leads its message with its
    /// code (`OUTPUT_SCHEMA_VIOLATION: …`).
    public let message: String
    /// The platform's classification, when it made one. The same value as
    /// ``FunctionRunInfo/errorCode``.
    ///
    /// A plain `String?`, by the Swift client's convention: a spelling the
    /// server adds must never fail a decode. The closed set is documented on
    /// the JS client's `FunctionRunErrorCode`.
    public let code: String?
    /// Whatever else the wire object carried, key for key. A wire `details` is
    /// one of those remaining keys like any other, so an error sending
    /// `details: ["x"]` reads here as `details` containing `{"details": ["x"]}`.
    public let details: JSONValue?

    public init(
        name: String? = nil,
        message: String,
        code: String? = nil,
        details: JSONValue? = nil
    ) {
        self.name = name
        self.message = message
        self.code = code
        self.details = details
    }

    /// The platform's placeholder name, which is not a name.
    ///
    /// `settledStatusResponse` writes `{ name: "WorkflowError", message }` for
    /// EVERY failure read off a terminal row, function rows included — and
    /// since the engine sink settles a function run's row at the end of its
    /// invocation, that is the ordinary path a caller's first read takes. It
    /// says nothing about the function, so the function readers drop it rather
    /// than moving it into ``details``.
    static let platformPlaceholderName = "WorkflowError"

    /// Read a raw `status.error` value, or `nil` when there is none to publish.
    ///
    /// NEVER throws and never fails the read around it — the #3449 rule, and
    /// the whole reason that child existed. Delegates to
    /// ``RunErrorEnvelope/read(_:)``, which is the one parser for this field,
    /// and adds the two function-side projections: the wire's `code` key is
    /// lifted out of the remaining keys, and the placeholder name is dropped.
    public static func read(_ value: JSONValue?) -> FunctionRunError? {
        guard let base = RunErrorEnvelope.read(value) else { return nil }

        // Only a STRING `code` is lifted. A `code` of another JSON kind is not
        // the platform's classification whatever else it is, so it stays under
        // `details` as the ordinary extra key it is.
        var code: String? = nil
        var details = base.details
        if let object = details?.objectValue, let raw = object["code"]?.stringValue {
            code = raw
            var rest = object
            rest.removeValue(forKey: "code")
            details = rest.isEmpty ? nil : .object(rest)
        }

        return FunctionRunError(
            name: base.name == platformPlaceholderName ? nil : base.name,
            message: base.message,
            code: code,
            details: details
        )
    }
}

/// A function run's row, with only the fields a function row has.
///
/// `workflowId`, `workflowKey`, `revisionId`, `skipReason` and the three
/// `failedStep*` fields are DSL vocabulary the server never sets for a function
/// row, so they are not declared and do not reach a caller. `executionMode` is
/// left out for a different reason: the row still stores the pre-#3482
/// spelling of it, and phase 7 is where that moves.
public struct FunctionRunInfo: Decodable, Sendable, Equatable {
    public let runId: String
    public let runKey: String
    public let instanceId: String?
    public let contextDocId: String?
    /// The function this run belongs to. `nil` for a DSL run read through this
    /// surface, which is not refused — the route is shared by design.
    public let functionId: String?
    public let functionKey: String?
    /// Who the run executed AS — `sys:<appId>` for a trigger-fired root.
    public let executionPrincipal: String?
    /// The function that started this one, for a nested start.
    public let parentFunctionKey: String?
    public let parentRunId: String?
    /// How deep in a nested-start tree this run is. `0` for a root.
    public let nestDepth: Int?
    public let status: String
    public let startedAt: String?
    public let executionStartedAt: String?
    public let queueDelayMs: Int?
    public let createCallDurationMs: Int?
    public let endedAt: String?
    public let errorMessage: String?
    /// The platform's classification of this failure. Same value as
    /// ``FunctionRunError/code``.
    public let errorCode: String?
    public let errorTitle: String?
    public let meta: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case runId, runKey, instanceId, contextDocId
        case functionId, functionKey, executionPrincipal
        case parentFunctionKey, parentRunId, nestDepth
        case status, startedAt, executionStartedAt, queueDelayMs
        case createCallDurationMs, endedAt
        case errorMessage, errorCode, errorTitle, meta
    }

    public init(
        runId: String = "",
        runKey: String = "",
        instanceId: String? = nil,
        contextDocId: String? = nil,
        functionId: String? = nil,
        functionKey: String? = nil,
        executionPrincipal: String? = nil,
        parentFunctionKey: String? = nil,
        parentRunId: String? = nil,
        nestDepth: Int? = nil,
        status: String = "",
        startedAt: String? = nil,
        executionStartedAt: String? = nil,
        queueDelayMs: Int? = nil,
        createCallDurationMs: Int? = nil,
        endedAt: String? = nil,
        errorMessage: String? = nil,
        errorCode: String? = nil,
        errorTitle: String? = nil,
        meta: JSONValue? = nil
    ) {
        self.runId = runId
        self.runKey = runKey
        self.instanceId = instanceId
        self.contextDocId = contextDocId
        self.functionId = functionId
        self.functionKey = functionKey
        self.executionPrincipal = executionPrincipal
        self.parentFunctionKey = parentFunctionKey
        self.parentRunId = parentRunId
        self.nestDepth = nestDepth
        self.status = status
        self.startedAt = startedAt
        self.executionStartedAt = executionStartedAt
        self.queueDelayMs = queueDelayMs
        self.createCallDurationMs = createCallDurationMs
        self.endedAt = endedAt
        self.errorMessage = errorMessage
        self.errorCode = errorCode
        self.errorTitle = errorTitle
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The `WorkflowRunInfo` defaults, for the same reason: a run block the
        // client cannot fully read is still a run block, and the three fields
        // the server always fills default rather than throwing.
        runId = try c.decodeIfPresent(String.self, forKey: .runId) ?? ""
        runKey = try c.decodeIfPresent(String.self, forKey: .runKey) ?? ""
        instanceId = try c.decodeIfPresent(String.self, forKey: .instanceId)
        contextDocId = try c.decodeIfPresent(String.self, forKey: .contextDocId)
        functionId = try c.decodeIfPresent(String.self, forKey: .functionId)
        functionKey = try c.decodeIfPresent(String.self, forKey: .functionKey)
        executionPrincipal = try c.decodeIfPresent(String.self, forKey: .executionPrincipal)
        parentFunctionKey = try c.decodeIfPresent(String.self, forKey: .parentFunctionKey)
        parentRunId = try c.decodeIfPresent(String.self, forKey: .parentRunId)
        nestDepth = try c.decodeIfPresent(Int.self, forKey: .nestDepth)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        executionStartedAt = try c.decodeIfPresent(String.self, forKey: .executionStartedAt)
        queueDelayMs = try c.decodeIfPresent(Int.self, forKey: .queueDelayMs)
        createCallDurationMs = try c.decodeIfPresent(Int.self, forKey: .createCallDurationMs)
        endedAt = try c.decodeIfPresent(String.self, forKey: .endedAt)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        errorTitle = try c.decodeIfPresent(String.self, forKey: .errorTitle)
        meta = try c.decodeIfPresent(JSONValue.self, forKey: .meta)
    }
}

/// The raw shape every `status.error` arrives in, parsed once.
///
/// OWNED BY THIS SURFACE, for the same reason ``FunctionRunSlice`` is: the
/// workflow surface is being retired and this parser has to outlive it.
/// ``WorkflowRunError`` reads through this until then, so deleting that type
/// deletes a wrapper rather than the one parser for the field.
///
/// NEVER throws and never fails the read around it — the #3449 rule. A value
/// of another JSON kind, and an object whose `message` is not a string, are
/// both "no error the client can describe", the same reading the `slice`
/// block takes (#3388): a status is an answer about a run, and a field the
/// client cannot vouch for must not cost the caller the answer.
struct RunErrorEnvelope {
    let name: String?
    let message: String
    let details: JSONValue?

    static func read(_ value: JSONValue?) -> RunErrorEnvelope? {
        guard let value, !value.isNull else { return nil }

        // The older form: a bare string is the message and nothing else.
        if let message = value.stringValue {
            return RunErrorEnvelope(name: nil, message: message, details: nil)
        }

        guard let object = value.objectValue else { return nil }
        guard let message = object["message"]?.stringValue else { return nil }

        // A `name` that is not a string reads as no name. It is the error's
        // NAME, and one invented out of a number would be worse than none —
        // and it is the `name` key rather than one of the remaining ones, so
        // it does not fall through into `details` either.
        let name = object["name"]?.stringValue

        var rest: [String: JSONValue] = [:]
        for (key, entry) in object where key != "name" && key != "message" {
            rest[key] = entry
        }

        return RunErrorEnvelope(
            name: name,
            message: message,
            details: rest.isEmpty ? nil : .object(rest)
        )
    }
}

/// The task slice's record on a function run (#3381). Mirrors the JS client's
/// status `slice` field for field.
///
/// OWNED BY THIS SURFACE. Only a function run has a slice record, so the block
/// takes a function name and the retiring workflow surface reads it through
/// `typealias WorkflowSliceInfo = FunctionRunSlice`. The custom `init(from:)`
/// below is the reason this is a move and not a copy: its throw semantics —
/// a non-numeric count drops the whole block rather than fabricating a `0` —
/// are pinned by tests, and two copies of them would drift.
///
/// A task run executes as a series of SLICES: the engine runs the handler until
/// it returns or hibernates, and each wake is a new slice with its own
/// credential. `refreshCount` is how many times that credential was refreshed
/// through the gateway instead of yielding, and `ceilingAt` is the 12-hour bound
/// on THIS slice, measured from its own start — a run that hibernates and wakes
/// continues in another slice, with a fresh ceiling. It is the same block
/// `primitive functions runs` prints as its `REFRESHES` column.
///
/// ADDITIVE, and present only for a task run that HAS a record: a request
/// invocation and a DSL workflow run carry no `slice` key at all, and read
/// `nil` here. Timestamps are epoch milliseconds (what the route sends), not
/// the ISO-8601 strings a run record carries — the slice record is the
/// platform's own bookkeeping, and the client passes its numbers through
/// verbatim rather than reformatting them.
public struct FunctionRunSlice: Decodable, Sendable, Equatable {
    /// Id of the slice record. The one field the server always fills.
    public let sliceId: String
    /// When this slice started, epoch ms. `nil` when the record does not
    /// carry it.
    public let startedAt: Int?
    /// The 12-hour bound THIS slice ends at, epoch ms — `startedAt` plus the
    /// slice maximum, not a deadline for the run, which can continue in a
    /// later slice with a ceiling of its own.
    public let ceilingAt: Int?
    /// When THIS slice settled, epoch ms; `nil` while the slice is open. A
    /// settled slice is not a finished run: a slice that yielded settles here
    /// and the run continues in the next slice, so a caller watching a run
    /// still reads `status`, never this field.
    public let settledAt: Int?
    /// How THIS slice settled (`"completed"`, `"failed"`, `"cpu-yield"`, …);
    /// `nil` while the slice is open. `"cpu-yield"` is the slice that gave up
    /// its CPU budget for the run to carry on in another one. A plain
    /// `String` for the same reason every other status on this surface is
    /// one: a server-added spelling must never turn a status read into a
    /// decode failure.
    public let settledStatus: String?
    /// When the credential was last refreshed, epoch ms; `nil` for a slice
    /// that never refreshed.
    public let lastRefreshAt: Int?
    /// How many times the credential was refreshed through the gateway
    /// instead of yielding. `0` for a run short enough never to need one.
    public let refreshCount: Int
    /// How many of this run's slices the platform tore down and restarted — a
    /// platform deploy resets the engine's Durable Object under every executing
    /// slice, and an isolate eviction does the same.
    ///
    /// The engine re-runs the interrupted step as a further attempt, so a run
    /// that was reset and then finished reads `completed` with no failure and
    /// no error code: this count is the only place that history shows. `0` for
    /// a run nothing reset, and for a server that predates the field.
    public let resets: Int
    /// When the most recent reset was counted, epoch ms; `nil` until there is
    /// one.
    public let lastResetAt: Int?
    /// What named the most recent reset: `"code-updated"` when the platform
    /// build changed underneath the run, `"evicted"` when the runtime said the
    /// isolate was reset, `"unknown"` when the platform saw a teardown it could
    /// not attribute. `nil` until there has been one. A plain `String` for the
    /// same reason `settledStatus` is one.
    public let lastResetCause: String?

    private enum CodingKeys: String, CodingKey {
        case sliceId, startedAt, ceilingAt, settledAt, settledStatus
        case lastRefreshAt, refreshCount
        case resets, lastResetAt, lastResetCause
    }

    public init(
        sliceId: String,
        startedAt: Int? = nil,
        ceilingAt: Int? = nil,
        settledAt: Int? = nil,
        settledStatus: String? = nil,
        lastRefreshAt: Int? = nil,
        refreshCount: Int = 0,
        resets: Int = 0,
        lastResetAt: Int? = nil,
        lastResetCause: String? = nil
    ) {
        self.sliceId = sliceId
        self.startedAt = startedAt
        self.ceilingAt = ceilingAt
        self.settledAt = settledAt
        self.settledStatus = settledStatus
        self.lastRefreshAt = lastRefreshAt
        self.refreshCount = refreshCount
        self.resets = resets
        self.lastResetAt = lastResetAt
        self.lastResetCause = lastResetCause
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `sliceId` is what makes this a record: a block without one is not a
        // slice, and throwing here is what the status decode reads as "no
        // record" (see the status result's `slice`).
        sliceId = try c.decode(String.self, forKey: .sliceId)
        startedAt = try Self.epochMillis(c, .startedAt)
        ceilingAt = try Self.epochMillis(c, .ceilingAt)
        settledAt = try Self.epochMillis(c, .settledAt)
        settledStatus = try c.decodeIfPresent(String.self, forKey: .settledStatus)
        lastRefreshAt = try Self.epochMillis(c, .lastRefreshAt)
        // Absent and `null` alike read 0 — the server always sends the count,
        // so this is tolerance for a payload that predates it. A value that is
        // not a number THROWS, which drops the whole block: a fabricated `0`
        // would read as "this run never refreshed", which is telemetry the
        // client does not have.
        refreshCount = try c.decodeIfPresent(Int.self, forKey: .refreshCount) ?? 0
        // #3566 — the same reading for the reset count, and for the same
        // reason: a fabricated `0` would say "the platform never reset this
        // run".
        resets = try c.decodeIfPresent(Int.self, forKey: .resets) ?? 0
        lastResetAt = try Self.epochMillis(c, .lastResetAt)
        lastResetCause = try c.decodeIfPresent(String.self, forKey: .lastResetCause)
    }

    /// One epoch-millisecond field: absent and `null` alike read `nil`, and a
    /// number arrives as `Double` first so a non-integral value is taken
    /// rather than refused. A value that is not a number throws, and the block
    /// it belongs to is dropped rather than published with a hole in it.
    private static func epochMillis(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> Int? {
        guard let raw = try container.decodeIfPresent(Double.self, forKey: key),
              raw.isFinite else { return nil }
        // `Int(exactly:)` rather than `Int(_:)`: a value outside `Int`'s range
        // would TRAP, and no timestamp is worth crashing a status read for.
        return Int(exactly: raw.rounded())
    }
}

/// What `functions.getStatus` answers.
///
/// Decoded FIELD BY FIELD through the nested `status` container, the #3449
/// rule: a surprise in one field cannot cost the caller the read, so a
/// malformed `error` or `slice` drops to `nil` with the status kept. An
/// already-flattened payload decodes by the same rule.
public struct FunctionRunStatus: Decodable, Sendable, Equatable {
    /// The server's status for this run, verbatim. The six words a function
    /// run can report are `queued`, `running`, `completed`, `failed`,
    /// `terminated` and `missing`; a plain `String` because a spelling the
    /// server adds must never turn a status read into a decode failure.
    public let status: String
    /// Final output of the run, when present. Opaque blob.
    public let output: JSONValue?
    /// `true` only when the platform could store a PREVIEW of the output
    /// rather than the whole value. `nil` otherwise.
    public let outputTruncated: Bool?
    /// Present when the run failed. The one structured error.
    public let error: FunctionRunError?
    public let run: FunctionRunInfo?
    public let slice: FunctionRunSlice?

    private enum CodingKeys: String, CodingKey {
        case status, output, outputTruncated, error, run, slice
    }

    /// The keys the server nests under `status`.
    private enum NestedKeys: String, CodingKey {
        case status, output, outputTruncated, error
    }

    public init(
        status: String,
        output: JSONValue? = nil,
        outputTruncated: Bool? = nil,
        error: FunctionRunError? = nil,
        run: FunctionRunInfo? = nil,
        slice: FunctionRunSlice? = nil
    ) {
        self.status = status
        self.output = output
        self.outputTruncated = outputTruncated
        self.error = error
        self.run = run
        self.slice = slice
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var rawError: JSONValue? = nil
        if let nested = try? c.nestedContainer(keyedBy: NestedKeys.self, forKey: .status) {
            let nestedStatus: String? =
                try? nested.decodeIfPresent(String.self, forKey: .status)
            status = nestedStatus ?? ""
            let nestedOutput: JSONValue? =
                try? nested.decodeIfPresent(JSONValue.self, forKey: .output)
            output = try nestedOutput ?? c.decodeIfPresent(JSONValue.self, forKey: .output)
            outputTruncated =
                (try? nested.decodeIfPresent(Bool.self, forKey: .outputTruncated)) ?? nil
            rawError = (try? nested.decodeIfPresent(JSONValue.self, forKey: .error)) ?? nil
        } else {
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            output = try c.decodeIfPresent(JSONValue.self, forKey: .output)
            outputTruncated = try? c.decodeIfPresent(Bool.self, forKey: .outputTruncated)
            rawError = try? c.decodeIfPresent(JSONValue.self, forKey: .error)
        }
        error = FunctionRunError.read(rawError)
        // A block the client cannot read is "no block", never a thrown status:
        // the run and the slice are observability beside the answer.
        run = try? c.decodeIfPresent(FunctionRunInfo.self, forKey: .run)
        slice = try? c.decodeIfPresent(FunctionRunSlice.self, forKey: .slice)
    }

    /// The three statuses a function run can have SETTLED on.
    ///
    /// `missing` is NOT one: that run's execution can no longer be resolved,
    /// which is a not-found rather than an ending. Neither are the DSL-only
    /// states, which a function run never enters.
    public static let terminalStatuses: Set<String> = [
        "completed", "failed", "terminated",
    ]

    /// Every status a function run can report.
    public static let statusValues: Set<String> = [
        "queued", "running", "completed", "failed", "terminated", "missing",
    ]

    /// Has this run settled?
    public var isTerminal: Bool { Self.terminalStatuses.contains(status) }

    /// Did it settle by failing?
    public var isFailure: Bool { status == "failed" }
}

/// The typed twin of ``FunctionRunStatus``: `output` decoded into `Output`.
///
/// The `FunctionInvokeResult` / `FunctionResult<Output>` pairing, applied to
/// the run surface.
public struct FunctionRunResult<Output: Decodable & Sendable>: Sendable {
    public let status: String
    public let output: Output?
    public let outputTruncated: Bool?
    public let error: FunctionRunError?
    public let run: FunctionRunInfo?
    public let slice: FunctionRunSlice?

    public init(
        status: String,
        output: Output? = nil,
        outputTruncated: Bool? = nil,
        error: FunctionRunError? = nil,
        run: FunctionRunInfo? = nil,
        slice: FunctionRunSlice? = nil
    ) {
        self.status = status
        self.output = output
        self.outputTruncated = outputTruncated
        self.error = error
        self.run = run
        self.slice = slice
    }

    public var isTerminal: Bool { FunctionRunStatus.terminalStatuses.contains(status) }
    public var isFailure: Bool { status == "failed" }
}

/// How long `functions.waitFor` may wait.
///
/// Structurally what `WaitForWorkflowOptions` carries, and nominally its own:
/// a function caller names a function type. The rename is declared in
/// `swift-client/CHANGELOG.md`, which is the whole mitigation for a break on a
/// client with no versions (its own words).
public struct FunctionWaitOptions: Sendable {
    /// Maximum time to wait for the run to settle before throwing
    /// `.workflowWaitTimeout`. Defaults to 15 minutes; `0` or a negative value
    /// waits indefinitely.
    public var timeout: TimeInterval?

    public init(timeout: TimeInterval? = nil) {
        self.timeout = timeout
    }
}

// MARK: - Terminate's three different 404s (#3565, D3565-013)

/// What a terminate 404 actually said.
///
/// `POST /workflows/{key}/instances/{runKey}/terminate` answers
/// `404 { status: "missing", error }` for THREE different things: a row that
/// does not exist, a row with no instance id, and ANY exception out of
/// `instance.terminate()` with the engine's own message as `error`. Folding
/// all three into "not found" would throw the engine's diagnostic away and
/// tell a caller their live run does not exist.
public enum FunctionTerminateNotFound: Sendable, Equatable {
    case notFound
    case engineFailure(diagnostic: String)
}

/// The classifier, and the two sentences it matches.
///
/// A hermetic guard holds this list to the controller's own text, so phase 7's
/// rename of the wire is caught rather than silently reclassifying every
/// not-found as an engine failure.
public enum FunctionTerminateClassifier {
    /// The two sentences the route answers when the run is genuinely not there.
    public static let missingSentences: [String] = [
        "Workflow run not found",
        "Workflow instance not found",
    ]

    /// Classify a terminate 404 by its body text.
    ///
    /// A body the classifier cannot read is a NOT-FOUND: that is the answer the
    /// route gave before any of this existed, and reporting an engine failure
    /// for a body with nothing in it would invent a live run out of silence.
    /// Read through `JSONValue`, the module's typed currency, rather than
    /// `JSONSerialization` into `[String: Any]`: `TransportSpineTests` holds
    /// the untyped-dictionary count outside the transport surface to a
    /// ceiling, and a new one here would be a new untyped site for a value
    /// this type already describes.
    public static func classify(body: String?) -> FunctionTerminateNotFound {
        guard
            let body,
            let data = body.data(using: .utf8),
            let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
            let object = parsed.objectValue
        else { return .notFound }
        guard object["status"]?.stringValue == "missing" else { return .notFound }
        guard let diagnostic = object["error"]?.stringValue, !diagnostic.isEmpty else {
            return .notFound
        }
        if missingSentences.contains(diagnostic) { return .notFound }
        return .engineFailure(diagnostic: diagnostic)
    }
}

// MARK: - The run-status route's two different 404s (#3661)

/// What a run-status 404 actually said.
///
/// `GET /workflows/runs/{runId}/status` answers 404 for two unrelated facts,
/// and folding them together is what made `functions.waitFor` report a live
/// run missing:
///
///  - the run id resolved to no row. The reads behind that are eventually
///    consistent, so a poll a second after a start can miss a committed row.
///  - `status: "missing"`: the row IS there and is not settled, and the
///    platform cannot see its instance. Inside the launch grace that is the
///    deliberate answer for a run between its row write and its instance, and
///    the route writes nothing for it.
public enum FunctionRunStatusNotFound: Sendable, Equatable {
    case noRun
    case instanceUnseen(diagnostic: String)
}

/// The classifier, and the sentence that means "no row" under a `missing`.
public enum FunctionRunStatusClassifier {
    /// `statusByRunId` answers its own absent-row 404 through the plain error
    /// envelope, so it never carries `status: "missing"`; the workflowKey /
    /// runKey status route spells the same fact this way, and a client pointed
    /// at either must read it the same way.
    public static let absentRowSentence = "Workflow run not found"

    /// Classify a run-status 404 by its body text.
    ///
    /// A body the classifier cannot read is `noRun`, matching
    /// ``FunctionTerminateClassifier/classify(body:)``'s reading of silence:
    /// the unbounded wait the other branch earns must be granted on something
    /// the route actually said. Read through `JSONValue` for the same reason
    /// that one is — `TransportSpineTests` holds the untyped-dictionary count
    /// outside the transport surface to a ceiling.
    public static func classify(body: String?) -> FunctionRunStatusNotFound {
        guard
            let body,
            let data = body.data(using: .utf8),
            let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
            let object = parsed.objectValue
        else { return .noRun }
        // Strictly the string. The error envelope carries a NUMERIC `status`
        // (404), which must never be read as the instance report.
        guard object["status"]?.stringValue == "missing" else { return .noRun }
        let diagnostic = object["error"]?.stringValue ?? ""
        if diagnostic == absentRowSentence { return .noRun }
        return .instanceUnseen(diagnostic: diagnostic)
    }
}

// MARK: - The one "is this a 404?" reading, for the function surface

extension FunctionRunStatus {
    /// Recognise a "run not found" from either error shape the routes throw:
    /// an `HttpError` with `status == 404`, or a `JsBaoError` with code
    /// `.notFound`. The same two shapes the workflow surface recognises; the
    /// function surface asks it here so it names no workflow type.
    static func isNotFound(_ error: Error) -> Bool {
        if let http = error as? HttpError, http.status == 404 { return true }
        if let jsBao = error as? JsBaoError, jsBao.code == .notFound { return true }
        return false
    }
}
