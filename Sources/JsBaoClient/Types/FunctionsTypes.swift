import Foundation

// MARK: - Server functions (#3278)
//
// The envelopes `client.functions` answers with. They mirror the JS client's
// `src/client/api/functionsApi.ts` field for field: the invoke envelope for a
// request function, the workflow START envelope for a task function, and the
// run reference the control routes take.

/// The resolved platform ceilings an invocation ran under.
///
/// `[function.limits]` clamped element-wise to the platform's own values, so a
/// function may lower a ceiling and never raise one. Reported because the
/// declared value and the enforced value are not always the same number.
/// Present only when the sandbox ran — absent from a `timeout`, and from a
/// refusal, which is an `HttpError` rather than an envelope.
public struct FunctionInvokeLimits: Decodable, Sendable, Equatable {
    public let cpuMs: Int
    public let subRequests: Int
    public let ratePerMinute: Int

    public init(cpuMs: Int, subRequests: Int, ratePerMinute: Int) {
        self.cpuMs = cpuMs
        self.subRequests = subRequests
        self.ratePerMinute = ratePerMinute
    }
}

/// The invoke envelope. Mirrors JS `FunctionInvokeResult`.
///
/// Deliberately without a `runId`: the request path writes no run row, so
/// there is nothing to look up afterwards. A function that throws or times
/// out is a SETTLED invocation with a terminal `status`, not a thrown error —
/// only the platform refusing the call before the code ran (access, disabled,
/// unpushed, rate) throws, as an `HttpError` carrying the server's `errorCode`
/// on `serverCode`.
///
/// `status` stays a plain `String` rather than a closed enum, as every other
/// Swift status field does, so a server-added status can never turn a settled
/// invocation into a decode failure.
public struct FunctionInvokeResult: Decodable, Sendable {
    /// `"completed"`, `"failed"` or `"timeout"`.
    public let status: String
    /// Present when `status` is `"completed"`. Opaque blob; a JSON `null`
    /// output decodes to `.null`.
    public let output: JSONValue?
    /// Present when `status` is `"failed"`.
    public let error: String?
    public let errorCode: String?
    /// The ceilings the sandbox ran under; `nil` when it never reported.
    public let limits: FunctionInvokeLimits?

    public init(
        status: String,
        output: JSONValue? = nil,
        error: String? = nil,
        errorCode: String? = nil,
        limits: FunctionInvokeLimits? = nil
    ) {
        self.status = status
        self.output = output
        self.error = error
        self.errorCode = errorCode
        self.limits = limits
    }
}

/// Typed twin of `FunctionInvokeResult`: the same envelope with `output`
/// decoded into `Output`. `nil` when the output is absent or JSON `null`.
/// Named separately because Swift does not let a generic and a non-generic
/// type share a name — the `RunSyncWorkflowResult` / `RunSyncResult<Output>`
/// split.
public struct FunctionResult<Output: Decodable & Sendable>: Sendable {
    public let status: String
    public let output: Output?
    public let error: String?
    public let errorCode: String?
    public let limits: FunctionInvokeLimits?

    public init(
        status: String,
        output: Output?,
        error: String? = nil,
        errorCode: String? = nil,
        limits: FunctionInvokeLimits? = nil
    ) {
        self.status = status
        self.output = output
        self.error = error
        self.errorCode = errorCode
        self.limits = limits
    }
}

/// The start envelope a task function answers with. Mirrors JS
/// `FunctionStartResult`.
///
/// Identical to the workflow start envelope on purpose: a caller polls a
/// function run exactly as it polls a DSL workflow run, and that is not true
/// if starting one looks different from starting the other. `existing` marks
/// a REPLAY — a repeated `runKey` names the run that already exists, which may
/// carry its outcome in `output` / `error`.
public struct FunctionStartResult: Decodable, Sendable, Equatable {
    public let runId: String
    public let runKey: String
    public let instanceId: String?
    public let status: String
    /// `true` on a replay of a run that already existed for this `runKey`.
    public let existing: Bool?
    public let output: JSONValue?
    public let error: String?

    public init(
        runId: String,
        runKey: String,
        instanceId: String? = nil,
        status: String,
        existing: Bool? = nil,
        output: JSONValue? = nil,
        error: String? = nil
    ) {
        self.runId = runId
        self.runKey = runKey
        self.instanceId = instanceId
        self.status = status
        self.existing = existing
        self.output = output
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case runId, runKey, instanceId, status, existing, output, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decodeIfPresent(String.self, forKey: .runId) ?? ""
        runKey = try c.decodeIfPresent(String.self, forKey: .runKey) ?? ""
        instanceId = try c.decodeIfPresent(String.self, forKey: .instanceId)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        existing = try c.decodeIfPresent(Bool.self, forKey: .existing)
        // Present-but-null stays `.null`, as on the invoke envelope.
        if c.contains(.output) {
            output = try c.decode(JSONValue.self, forKey: .output)
        } else {
            output = nil
        }
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// Addresses one function run for the control routes. Mirrors JS
/// `FunctionRunRef`.
///
/// `functionKey` stands where a workflow's key stands — that IS the aliasing:
/// the instance routes resolve a run by `contextDocId#runKey`, so a function
/// key in the key slot addresses a function run without a second protocol.
public struct FunctionRunRef: Sendable, Equatable {
    public var functionKey: String
    public var runKey: String
    public var contextDocId: String?

    public init(functionKey: String, runKey: String, contextDocId: String? = nil) {
        self.functionKey = functionKey
        self.runKey = runKey
        self.contextDocId = contextDocId
    }
}

// MARK: - Channels

/// A live channel membership, returned by `JsBaoClient.subscribeToChannel`.
/// Mirrors the JS `ChannelSubscription`.
///
/// `expiresAt` is epoch milliseconds and is the membership's whole lifetime:
/// expiry is the only revocation a channel grant has, so past it the server
/// stops delivering even though this socket stays open. Renewing means asking
/// the authorizing function for another grant and subscribing again — which
/// replaces this membership rather than adding one.
public struct ChannelSubscription: Sendable {
    public let channel: String
    public let expiresAt: Int
    /// Leave the channel. Idempotent; the same as
    /// `client.unsubscribeFromChannel(channel)`.
    public let unsubscribe: @Sendable () -> Void

    public init(channel: String, expiresAt: Int, unsubscribe: @escaping @Sendable () -> Void) {
        self.channel = channel
        self.expiresAt = expiresAt
        self.unsubscribe = unsubscribe
    }
}
