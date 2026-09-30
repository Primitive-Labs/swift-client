import Foundation

// MARK: - FunctionsAPI

/// Server functions, available as `client.functions`. Mirrors the JS client's
/// `client.functions` (`src/client/api/functionsApi.ts`) — #3278.
///
/// A function is TypeScript an app's team authored in its config tree and
/// pushed with `primitive config push`. A REQUEST function is invoked and
/// answers its result; a TASK function is started and answers a run id that
/// is polled on exactly the routes a DSL workflow run is. The method set is
/// JS's and nothing more: `invoke`, `start`, `getStatus`, `waitFor`,
/// `terminate`. The client-apply trio stays on `workflows`, where both
/// clients keep it — a function run never enters `apply_pending`.
///
/// #3565 — the three control methods post the run routes THEMSELVES and
/// answer `FunctionRunStatus` / `FunctionRunResult<Output>`. Polling those
/// routes stays an implementation choice; it used to reach the caller as
/// vocabulary — a `skipReason` and a `run.workflowId` the server can never set
/// for a function, and a missing run reported as a missing WORKFLOW run. This
/// class references no workflow type and holds no `WorkflowsAPI`.
///
/// `waitFor` polls rather than waiting on a frame: a function run broadcasts
/// no `workflowStatus`, so a listener would have nothing to wake it.
public final class FunctionsAPI: @unchecked Sendable {
    private let transport: any Transport
    private let logger: Logger?

    /// Designated initializer — the typed transport spine.
    public convenience init(transport: any Transport) {
        self.init(transport: transport, logger: nil)
    }

    /// In-module initializer — same as the public one plus the internal
    /// logger. `logger` has no default so the two stay unambiguous.
    init(transport: any Transport, logger: Logger?) {
        self.transport = transport
        self.logger = logger
    }

    // MARK: - Poll schedule (waitFor)

    /// The JS client's schedule: 400 ms doubling to 5 s, a 15-minute default.
    static let waitMinInterval: TimeInterval = 0.4
    static let waitMaxInterval: TimeInterval = 5
    static let waitDefaultTimeout: TimeInterval = 15 * 60

    /// How long a wait keeps polling a run id the platform reports NO ROW for
    /// — #3661, and the JS client's `FUNCTION_WAIT_NOT_FOUND_GRACE_MS`.
    ///
    /// Bounds one thing only: an eventually consistent read that has not
    /// caught up with a committed row. That is a phenomenon of a replica, not
    /// of a run, so it is measured in seconds; three of them is several polls'
    /// worth of it and short enough that a mistyped run id still fails while
    /// the caller is watching. A run the platform CAN see and cannot probe is
    /// not bounded by this — it is bounded by the caller's own timeout.
    static let waitNotFoundGrace: TimeInterval = 3

    /// Test seams: the clock the deadline is measured on and the sleep the
    /// schedule waits with. A hermetic test installs a fake clock that a fake
    /// sleep advances, so the schedule's arithmetic (doubling, saturation, the
    /// clamp, the bounded finalization re-check) is pinned exactly and in no
    /// real time. Never set in production code.
    var clockForTest: (@Sendable () -> Date)?
    var sleepForTest: (@Sendable (TimeInterval) async throws -> Void)?

    private func now() -> Date { clockForTest?() ?? Date() }

    private func sleep(_ seconds: TimeInterval) async throws {
        if let sleepForTest {
            try await sleepForTest(seconds)
            return
        }
        try await Task.sleep(nanoseconds: UInt64(Swift.max(0, seconds) * 1_000_000_000))
    }

    // MARK: - invoke (request functions)

    /// Invoke a request function and wait for its result: an `Encodable`
    /// input, `output` decoded into `Output`.
    ///
    /// This is the ONLY way in, and the binding surface the generated per-key
    /// Swift types use. #3278 shipped an untyped `[String: Any]` twin beside
    /// it because no per-key types existed yet to express an invocation with;
    /// #3344 generated them, and the twin went with the reason for it. A
    /// caller whose function has no declared schema — or who is genuinely
    /// dynamic — names the witness: `invoke(key, input: nil as JSONValue?)`
    /// bound `as FunctionResult<JSONValue>`.
    ///
    /// `input` is named for what it is on this side of the wire; it travels
    /// as the envelope's `rootInput`. `timeout` is seconds here and
    /// `timeoutMs` on the wire — the platform default is 5 s and the ceiling
    /// 30 s; nil, zero or negative omits it. `meta` is passed through
    /// unvalidated; the server's 1 KB limit is its `400 INVALID_META`.
    ///
    /// A settled invocation never throws, whatever its `status`. A platform
    /// refusal (access, disabled, unpushed, rate, unknown key) throws an
    /// `HttpError` with the server's `errorCode` on `serverCode`. Calling this
    /// on a TASK function throws `.functionModeMismatch` — the server answered
    /// a start envelope, which promises none of what this method's type does.
    ///
    /// The input is encoded once and sent as the JSON value it produces —
    /// object, array, string, number or boolean — unchanged, exactly as the JS
    /// client forwards `input`. A function whose schema declares an array or
    /// scalar root receives that. This is where the port deliberately does
    /// NOT follow `WorkflowsAPI`, whose `rootInput` is always an object: a
    /// non-object lowered to `{}` would silently change what the function
    /// runs. A `nil` input omits `rootInput` (the server supplies `{}`); an
    /// input that fails to encode throws `.invalidArgument` before any request
    /// is made.
    public func invoke<Input: Encodable, Output: Decodable & Sendable>(
        _ functionKey: String,
        input: Input?,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> FunctionResult<Output> {
        let rootInput = try Self.encodeInput(input)
        let untyped = try await invokeRequest(
            functionKey: functionKey,
            rootInput: rootInput,
            contextDocId: contextDocId,
            meta: meta,
            timeout: timeout
        )
        return FunctionResult(
            status: untyped.status,
            output: try Self.decodeTypedOutput(untyped.output),
            error: untyped.error,
            errorCode: untyped.errorCode,
            limits: untyped.limits,
            invocationId: untyped.invocationId
        )
    }

    // MARK: - start (task functions)

    /// Start a task function and get its run id back: an `Encodable` input
    /// sent as the JSON value it encodes to, under the same rules as `invoke`.
    /// The start envelope is not output-typed on either client, so only the
    /// input is generic here.
    ///
    /// Same route as `invoke`; the MODE decides what it answers. The run is
    /// polled on exactly the routes a DSL workflow run is (`getStatus`,
    /// `waitFor`, `terminate` below). `runKey` makes the start idempotent per
    /// `(caller, contextDocId, runKey)`: a repeat answers the run that already
    /// exists with `existing == true`, never a second run. There is no
    /// `forceRerun` and no `timeoutMs` on this route.
    ///
    /// Calling this on a REQUEST function throws `.functionModeMismatch` — the
    /// function ran and answered its result, so there is no run to poll.
    ///
    /// As with `invoke`, the untyped `[String: Any]` twin #3278 shipped is
    /// gone (#3344): call a generated `<Key>Function`, or name the witness
    /// (`start(key, input: nil as JSONValue?)`) for a dynamic one.
    @discardableResult
    public func start<Input: Encodable>(
        _ functionKey: String,
        input: Input?,
        runKey: String? = nil,
        contextDocId: String? = nil,
        meta: [String: Any]? = nil
    ) async throws -> FunctionStartResult {
        let rootInput = try Self.encodeInput(input)
        return try await startRequest(
            functionKey: functionKey,
            rootInput: rootInput,
            runKey: runKey,
            contextDocId: contextDocId,
            meta: meta
        )
    }

    // MARK: - getStatus / waitFor (by run id)

    /// The current status of a function run, by run id.
    ///
    /// GETs the run-status route itself and answers the FUNCTION shape: one
    /// structured ``FunctionRunError`` with the platform's `code` on it, a run
    /// block carrying only fields a function row has, and none of the workflow
    /// DSL's vocabulary. Throws `.invalidArgument` for an empty `runId`.
    ///
    /// A run id that is not this app's, or does not exist, throws `.notFound`
    /// with `Function run <id> not found`. Every other refusal — a 403 from
    /// the access gate, a 5xx — propagates as it arrived.
    ///
    /// A task run that has a slice record also carries `slice` (#3388): its
    /// refresh count, the current slice's 12-hour ceiling and how the slice
    /// settled. `nil` for a request invocation and for a DSL run.
    public func getStatus(runId: String) async throws -> FunctionRunStatus {
        guard !runId.isEmpty else {
            throw JsBaoError(code: .invalidArgument, message: "runId is required for functions.getStatus")
        }
        let encoded = URLEncoding.encodeComponent(runId)
        do {
            return try await transport.request(
                method: .get,
                path: "/workflows/runs/\(encoded)/status"
            )
        } catch {
            // The status route has no other 404: there is one thing it cannot
            // find. WHICH of its two 404s it was travels on `details.reason`
            // for the wait to branch on (#3661); the code and the message do
            // not move.
            if FunctionRunStatus.isNotFound(error) {
                let classified = FunctionRunStatusClassifier.classify(
                    body: (error as? HttpError)?.body
                )
                var details: [String: JSONValue] = ["runId": .string(runId)]
                switch classified {
                case .noRun:
                    details["reason"] = .string("no-run")
                case let .instanceUnseen(diagnostic):
                    details["reason"] = .string("instance-unseen")
                    if !diagnostic.isEmpty { details["diagnostic"] = .string(diagnostic) }
                }
                throw JsBaoError(
                    code: .notFound,
                    message: "Function run \(runId) not found",
                    details: details
                )
            }
            throw error
        }
    }

    /// Typed `getStatus`: `output` decoded into `Output`.
    public func getStatus<Output: Decodable & Sendable>(
        runId: String
    ) async throws -> FunctionRunResult<Output> {
        let untyped = try await getStatus(runId: runId)
        return try Self.typed(untyped)
    }

    /// Wait for a function run to reach a terminal state.
    ///
    /// POLLS, where a workflow wait listens for a frame: a function run
    /// broadcasts nothing over the socket, so a listener would reconcile once,
    /// see `running`, and wait out its whole timeout with nothing left to wake
    /// it. The interval starts at 0.4 s and doubles to 5 s, the last sleep is
    /// clamped to what is left of the budget, and one poll is taken at the
    /// deadline itself before the wait throws `.workflowWaitTimeout`. The
    /// default timeout is 15 minutes; 0 or a negative value disables it.
    ///
    /// SETTLES on exactly `completed`, `failed` and `terminated` — the three
    /// ``FunctionRunStatus/isTerminal`` names. A failed run RESOLVES with
    /// `status == "failed"` and its `error`; it does not throw.
    ///
    /// A NOT-FOUND IS RETRIED, and how far depends on which one the platform
    /// reported, so a run id `start` has just returned is safe to wait on: it
    /// is not reported missing while the run is starting or running. A run
    /// that EXISTS, has not settled, and whose instance the platform cannot
    /// see yet — what a run between its creation and its first execution looks
    /// like — is polled to your own timeout. A run id that resolves to nothing
    /// is retried for ``waitNotFoundGrace`` (a poll issued a second after a
    /// start can be answered by a replica that has not caught up with it) and
    /// no longer. Either way the wait ends in `.notFound` with the same
    /// message the first refusal would have thrown, and a wait whose timeout
    /// runs out while its last read was a not-found reports that `.notFound`
    /// rather than `.workflowWaitTimeout`. A run reporting `missing` in a 200
    /// body throws `.notFound` in function words. A read
    /// reporting one of the DSL-only states (reachable only by handing this
    /// method a DSL run id, which is not refused) throws `.invalidArgument`
    /// naming the status, rather than settling on a value outside the type's
    /// own terminal set or spinning to the deadline. A transient error between
    /// polls is retried, not surfaced. A run whose record already reads
    /// terminal while the status block still reports the execution (the
    /// finalization window) is re-checked on a short timer and settles from the
    /// record after the bounded re-check. Cancelling the surrounding `Task`
    /// throws `CancellationError` promptly and stops polling.
    public func waitFor(
        runId: String,
        options: FunctionWaitOptions? = nil
    ) async throws -> FunctionRunStatus {
        guard !runId.isEmpty else {
            throw JsBaoError(code: .invalidArgument, message: "runId is required for functions.waitFor")
        }
        let timeout = options?.timeout ?? Self.waitDefaultTimeout
        let unbounded = !(timeout > 0 && timeout.isFinite)
        let deadline: Date? = unbounded ? nil : now().addingTimeInterval(timeout)
        let timeoutMs = timeout.wholeMilliseconds

        // #3661 — the stale-read window, measured from the START of the wait
        // rather than from each 404: a run id that has never resolved in three
        // seconds of polling is not a row a replica is late with. The
        // classification itself is `FunctionRunStatusClassifier`, and the
        // instance-unseen branch is the server's deliberate answer inside the
        // launch grace, where it writes nothing on purpose — so the fix could
        // never be to change what the route says.
        let notFoundDeadline = now().addingTimeInterval(Self.waitNotFoundGrace)

        var delay = Self.waitMinInterval
        /// The last poll's not-found, cleared by any read that succeeded.
        var notFound: JsBaoError? = nil
        while true {
            try Task.checkCancellation()
            var status: FunctionRunStatus? = nil
            notFound = nil
            do {
                status = try await getStatus(runId: runId)
            } catch {
                // `getStatus` already reworded the 404 and said which one it
                // was. An unseen instance is a row that exists, so the wait
                // keeps its own deadline; an unresolved run id gets the
                // stale-read grace and then this throws it, unchanged, as it
                // always did. Anything else is transient: the next poll, or
                // the deadline, still covers it.
                if let jsBao = error as? JsBaoError, jsBao.code == .notFound {
                    let unseen = jsBao.details?["reason"]?.stringValue == "instance-unseen"
                    if !unseen, now() >= notFoundDeadline { throw jsBao }
                    notFound = jsBao
                }
                if error is CancellationError { throw error }
                logger?.debug("[functions.waitFor] poll failed; retrying", [
                    "runId": runId, "error": String(describing: error),
                ])
            }
            if let status {
                if status.isTerminal { return status }
                if status.status == "missing" {
                    throw JsBaoError(
                        code: .notFound,
                        message: "Function run \(runId) is no longer resolvable (status: missing)"
                    )
                }
                if !FunctionRunStatus.statusValues.contains(status.status) {
                    throw JsBaoError(
                        code: .invalidArgument,
                        message: "functions.waitFor: run \(runId) reported status "
                            + "\"\(status.status)\", which is not a function run status"
                    )
                }
                if let settled = try await recheckFinalizationWindow(
                    runId: runId, first: status, deadline: deadline, timeoutMs: timeoutMs
                ) {
                    return settled
                }
            }
            let remaining = deadline.map { $0.timeIntervalSince(now()) }
            if let remaining, remaining <= 0 {
                // #3661 — a caller whose every poll was a not-found is told
                // THAT. The budget ran out downstream of it, and "timed out
                // waiting" would send them to look at a run the platform never
                // showed them.
                if let notFound { throw notFound }
                // Same code the workflow wait raises: it is the same fact about
                // the same kind of run, and the intent settles that error codes
                // rename in phase 7. The MESSAGE is function-worded.
                throw JsBaoError(
                    code: .workflowWaitTimeout,
                    message: "functions.waitFor timed out after \(timeoutMs)ms waiting for function run \(runId)"
                )
            }
            // The stale-read grace is clamped the way the deadline is, and for
            // the same reason: a run id that resolves to nothing is refused at
            // the end of the grace rather than at the end of whichever backoff
            // interval straddles it.
            var graceLeft: TimeInterval? = nil
            if let notFound, notFound.details?["reason"]?.stringValue != "instance-unseen" {
                graceLeft = Swift.max(0, notFoundDeadline.timeIntervalSince(now()))
            }
            let sleepFor = [remaining, graceLeft].compactMap { $0 }.reduce(delay, Swift.min)
            try await sleep(sleepFor)
            delay = Swift.min(delay * 2, Self.waitMaxInterval)
        }
    }

    /// Typed `waitFor`: `output` decoded into `Output`, nil when absent.
    public func waitFor<Output: Decodable & Sendable>(
        runId: String,
        as outputType: Output.Type,
        options: FunctionWaitOptions? = nil
    ) async throws -> FunctionRunResult<Output> {
        let base = try await waitFor(runId: runId, options: options)
        return try Self.typed(base)
    }

    // MARK: - terminate

    /// Terminate a running function run.
    ///
    /// POSTs the instance route itself rather than delegating: the workflow
    /// method mints `workflowKey is required for workflows.terminate` for an
    /// empty key and rewords nothing, so a function caller met the workflow
    /// vocabulary on every refusal.
    ///
    /// A 404 from this route means THREE different things — no row, no
    /// instance id, and any exception out of the engine's own `terminate()`.
    /// The body is how they are told apart (D3565-013): the first two are a
    /// function-worded `.notFound`; the third is `.unavailable` carrying the
    /// engine's diagnostic verbatim, because a live run the engine could not
    /// stop is not a run that does not exist, and discarding what the engine
    /// said would leave a caller with nothing to act on.
    @discardableResult
    public func terminate(_ ref: FunctionRunRef) async throws -> FunctionRunStatus {
        guard !ref.functionKey.isEmpty else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "functionKey is required for functions.terminate"
            )
        }
        guard !ref.runKey.isEmpty else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "runKey is required for functions.terminate"
            )
        }
        let encodedKey = URLEncoding.encodeComponent(ref.functionKey)
        let encodedRunKey = URLEncoding.encodeComponent(ref.runKey)
        var query = URLQuery()
        query.appendIfPresent("contextDocId", ref.contextDocId)
        let path =
            "/workflows/\(encodedKey)/instances/\(encodedRunKey)/terminate\(query.queryString)"
        do {
            return try await transport.request(method: .post, path: path)
        } catch {
            guard FunctionRunStatus.isNotFound(error) else { throw error }
            let body = (error as? HttpError)?.body
            switch FunctionTerminateClassifier.classify(body: body) {
            case .engineFailure(let diagnostic):
                throw JsBaoError(
                    code: .unavailable,
                    message: "Function run \(ref.runKey) of function \(ref.functionKey) "
                        + "could not be terminated: \(diagnostic)"
                )
            case .notFound:
                throw JsBaoError(
                    code: .notFound,
                    message: "Function run \(ref.runKey) of function \(ref.functionKey) not found"
                )
            }
        }
    }

    /// Typed `terminate`: a terminated run can carry partial output, decoded
    /// into `Output`.
    public func terminate<Output: Decodable & Sendable>(
        _ ref: FunctionRunRef
    ) async throws -> FunctionRunResult<Output> {
        let untyped: FunctionRunStatus = try await terminate(ref)
        return try Self.typed(untyped)
    }

    // MARK: - The one route, and the mode check

    /// The one place an invoke body is composed and its answer classified.
    private func invokeRequest(
        functionKey: String,
        rootInput: Any?,
        contextDocId: String?,
        meta: [String: Any]?,
        timeout: TimeInterval?
    ) async throws -> FunctionInvokeResult {
        // #3482 — no `mode`. The ROUTE is the runtime selector: this one runs
        // the function inside the request. The body field it replaced is
        // deprecated compatibility for clients published before the change.
        var payload: [String: Any] = [:]
        if let rootInput { payload["rootInput"] = rootInput }
        if let contextDocId { payload["contextDocId"] = contextDocId }
        if let meta { payload["meta"] = meta }
        // Seconds on this side (the #2367 convention), `timeoutMs` on the wire.
        if let timeout, timeout > 0 {
            payload["timeoutMs"] = timeout.wholeMilliseconds
        }
        let envelope = try await post(functionKey: functionKey, payload: payload, runtime: .request)

        // The BACKSTOP, for a server that predates the route (#3482,
        // D3482-008). Against such a deployment this path is one route whose
        // body field decides what it answers, so it can still hand back the
        // start envelope — which has no `output` and no terminal `status`,
        // everything this method's return type promises. Say so.
        if let runId = envelope.runId, envelope.runKey != nil {
            throw JsBaoError(
                code: .functionModeMismatch,
                message: "Function '\(functionKey)' is a task function: it starts a RUN rather than returning a result. "
                    + "Call functions.start(key, …) and poll with functions.getStatus / functions.waitFor.",
                details: ["functionKey": .string(functionKey), "runId": .string(runId)]
            )
        }
        return FunctionInvokeResult(
            status: envelope.status ?? "",
            output: envelope.output,
            error: envelope.error,
            errorCode: envelope.errorCode,
            limits: envelope.limits,
            invocationId: envelope.invocationId
        )
    }

    /// The one place a start body is composed and its answer classified.
    private func startRequest(
        functionKey: String,
        rootInput: Any?,
        runKey: String?,
        contextDocId: String?,
        meta: [String: Any]?
    ) async throws -> FunctionStartResult {
        // #3482 — the mirror of `invoke`: the ROUTE says this call means the
        // task runtime, so the body names nothing.
        var payload: [String: Any] = [:]
        if let rootInput { payload["rootInput"] = rootInput }
        if let runKey { payload["runKey"] = runKey }
        if let contextDocId { payload["contextDocId"] = contextDocId }
        if let meta { payload["meta"] = meta }
        let envelope = try await post(functionKey: functionKey, payload: payload, runtime: .task)

        // The mirror of `invoke`'s backstop, and the same reason (#3482):
        // against a server that predates this route the call would have run
        // the function inside the request and answered with its RESULT, so
        // there is no run id to poll.
        guard let runId = envelope.runId, let runKey = envelope.runKey else {
            throw JsBaoError(
                code: .functionModeMismatch,
                message: "Function '\(functionKey)' is a request function: it returns a result rather than starting a run. "
                    + "Call functions.invoke(key, …) instead.",
                details: [
                    "functionKey": .string(functionKey),
                    "status": envelope.status.map(JSONValue.string) ?? .null,
                ]
            )
        }
        return FunctionStartResult(
            runId: runId,
            runKey: runKey,
            instanceId: envelope.instanceId,
            status: envelope.status ?? "",
            existing: envelope.existing,
            output: envelope.output,
            error: envelope.error
        )
    }

    /// Which runtime a call means — #3482. The ROUTE says it: `invoke` posts
    /// to `functions/{key}` and runs the function inside the request, `start`
    /// posts to `functions/{key}/start` and runs it as a task. There is no
    /// body field for it on a current server.
    private enum CallRuntime {
        case request
        case task

        var pathSuffix: String { self == .task ? "/start" : "" }
    }

    /// The function route, the body serialized directly from the `Any` graph
    /// so opaque caller data (`rootInput`, `meta`) reaches the wire as
    /// spelled. The answer is decoded into the union of both envelopes; the
    /// callers above decide which one they were handed.
    private func post(
        functionKey: String,
        payload: [String: Any],
        runtime: CallRuntime
    ) async throws -> FunctionRouteEnvelope {
        let encodedKey = URLEncoding.encodeComponent(functionKey)
        let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [])
        return try await transport.request(
            method: .post,
            path: "/functions/\(encodedKey)\(runtime.pathSuffix)",
            bodyData: bodyData
        )
    }

    /// Encode a typed input into the JSON value it produces — any JSON type,
    /// not just an object — for the `rootInput` slot. `nil` means "no
    /// input", which omits the field. An input that fails to encode is the
    /// caller's mistake, reported before any request goes out.
    private static func encodeInput<Input: Encodable>(_ input: Input?) throws -> Any? {
        guard let input else { return nil }
        do {
            return try JSONCoding.jsonObject(from: input)
        } catch {
            throw JsBaoError(
                code: .invalidArgument,
                message: "functions: input could not be encoded as JSON: \(error)"
            )
        }
    }

    /// Decode the opaque `output` blob into the typed `Output`. An absent or
    /// `.null` output maps to `nil`.
    private static func decodeTypedOutput<Output: Decodable>(_ value: JSONValue?) throws -> Output? {
        guard let value, !value.isNull else { return nil }
        let any = try JSONCoding.jsonObject(from: value)
        return try JSONCoding.decode(Output.self, from: any)
    }

    /// The typed twin of an untyped read — one place, so the three typed
    /// overloads cannot disagree about what typing an output costs a caller.
    private static func typed<Output: Decodable & Sendable>(
        _ untyped: FunctionRunStatus
    ) throws -> FunctionRunResult<Output> {
        FunctionRunResult(
            status: untyped.status,
            output: try Self.decodeTypedOutput(untyped.output),
            outputTruncated: untyped.outputTruncated,
            error: untyped.error,
            run: untyped.run,
            slice: untyped.slice
        )
    }

    /// How long the finalization re-check waits between fetches, and how many
    /// times it retries before settling from the run record (#2348). The same
    /// window the workflow wait uses; spelled here because this class names no
    /// workflow type.
    static let finalizeRecheckIntervalMs: UInt64 = 1000
    static let finalizeMaxRechecks = 30

    /// Is this read inside the finalization window — the run RECORD already
    /// terminal while the status block still reports the execution, because
    /// the server withholds `completed` until the output is published?
    /// Answers the record's terminal status, or `nil` when it is not.
    static func finalizingTerminalStatus(_ res: FunctionRunStatus) -> String? {
        guard !res.isTerminal else { return nil }
        guard let stored = res.run?.status else { return nil }
        return FunctionRunStatus.terminalStatuses.contains(stored) ? stored : nil
    }

    /// The finalization window: re-check on the short timer, and settle from
    /// the record after the bounded re-check rather than polling on. Returns
    /// `nil` when the first response is not in the window.
    private func recheckFinalizationWindow(
        runId: String,
        first: FunctionRunStatus,
        deadline: Date?,
        timeoutMs: Int
    ) async throws -> FunctionRunStatus? {
        var res = first
        var attempts = 0
        while let stored = Self.finalizingTerminalStatus(res) {
            if attempts >= Self.finalizeMaxRechecks {
                return FunctionRunStatus(
                    status: stored,
                    output: res.output,
                    outputTruncated: res.outputTruncated,
                    error: res.error,
                    run: res.run,
                    slice: res.slice
                )
            }
            attempts += 1
            if let deadline, deadline.timeIntervalSince(now()) <= 0 {
                throw JsBaoError(
                    code: .workflowWaitTimeout,
                    message: "functions.waitFor timed out after \(timeoutMs)ms waiting for function run \(runId)"
                )
            }
            try await sleep(TimeInterval(Self.finalizeRecheckIntervalMs) / 1000)
            do {
                res = try await getStatus(runId: runId)
            } catch {
                if let jsBao = error as? JsBaoError, jsBao.code == .notFound { throw jsBao }
                if error is CancellationError { throw error }
                continue
            }
            if res.isTerminal { return res }
        }
        return nil
    }
}

// MARK: - Route envelope

/// The union of what `POST /functions/{key}` can answer: the invoke envelope
/// (`status` / `output` / `error` / `errorCode` / `limits`) or the workflow
/// start envelope (`runId` / `runKey` / `instanceId` / `status` /
/// `existing`). `runId` + `runKey` is the discriminator: the request path
/// writes no run row precisely so that there is nothing to poll, so a run id
/// on this route means a task start and nothing else.
private struct FunctionRouteEnvelope: Decodable, Sendable {
    let status: String?
    let output: JSONValue?
    let error: String?
    let errorCode: String?
    let limits: FunctionInvokeLimits?
    let runId: String?
    let runKey: String?
    let instanceId: String?
    let existing: Bool?
    /// #3448 — the invocation-log record's id. Decoded HERE, because this is
    /// what the wire is read into: a field added only to the public structs
    /// would be published in the type and `nil` on every real call.
    let invocationId: String?

    private enum CodingKeys: String, CodingKey {
        case status, output, error, errorCode, limits, runId, runKey, instanceId, existing
        case invocationId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        // A present-but-null `output` is `.null`, not absent: `decodeIfPresent`
        // would fold the two together, and the untyped envelope keeps them
        // apart (the typed overloads map both to `nil`).
        // Spelled as a statement, not a `?:` with a `nil` arm: `JSONValue` is
        // `ExpressibleByNilLiteral`, so that arm would have been `.null`.
        if c.contains(.output) {
            output = try c.decode(JSONValue.self, forKey: .output)
        } else {
            output = nil
        }
        error = try c.decodeIfPresent(String.self, forKey: .error)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        limits = try c.decodeIfPresent(FunctionInvokeLimits.self, forKey: .limits)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        runKey = try c.decodeIfPresent(String.self, forKey: .runKey)
        instanceId = try c.decodeIfPresent(String.self, forKey: .instanceId)
        existing = try c.decodeIfPresent(Bool.self, forKey: .existing)
        invocationId = try c.decodeIfPresent(String.self, forKey: .invocationId)
    }
}
