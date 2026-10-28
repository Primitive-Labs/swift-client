import Foundation

// MARK: - AgentsAPI

/// Agents, available as `client.agents`. Mirrors the JS client's
/// `client.agents` (#3810).
public final class AgentsAPI: @unchecked Sendable {
    /// Agent sessions: list, get, open, send, answer, cancel, events, mark
    /// read, rename, delete and members.
    public let sessions: AgentSessionsAPI

    /// Designated initializer — the typed transport spine. A sessions API
    /// built this way has no client, so its `open` throws `.unavailable`.
    public convenience init(transport: any Transport) {
        self.init(transport: transport, client: nil)
    }

    init(transport: any Transport, client: JsBaoClient?) {
        self.sessions = AgentSessionsAPI(transport: transport, client: client)
    }
}

// MARK: - AgentSessionsAPI

/// Agent sessions, available as `client.agents.sessions`. Mirrors the JS
/// client's `AgentSessionsAPI` operation for operation.
///
/// A session is created by a server function (`ctx.agents.createSession`);
/// from a client you list the sessions you own or belong to, open one as a
/// live view, send messages, answer calls, record events, cancel a turn and
/// mark a session read, and — as its owner — rename it, delete it and manage its members. App
/// owners and admins may also list any user's sessions and get or delete any
/// session.
///
/// A refusal throws `HttpError` whose `serverCode` is the server's code
/// (`AGENT_SESSION_NOT_FOUND`, `AGENT_SESSION_OWNER_ONLY`,
/// `AGENT_SESSION_PARTICIPANT_ONLY`, `AGENT_TURN_STALE`, …) and `status` the
/// HTTP status; branch on `serverCode`. An empty id or title throws
/// `JsBaoError(.invalidArgument)` before any request is made.
///
/// Once a session call answers `AGENT_SESSION_NOT_FOUND`, or this client's
/// `delete` of the session returns, the session's queued uploads and the
/// messages waiting on them fail with that not-found error.
public final class AgentSessionsAPI: @unchecked Sendable {
    private let transport: any Transport
    weak var client: JsBaoClient?

    /// Diagnostics for a session: `inspect.storage(_:)`.
    public let inspect: AgentSessionInspectAPI

    /// Designated initializer — the typed transport spine. Without a client,
    /// `open` throws `.unavailable`.
    public convenience init(transport: any Transport) {
        self.init(transport: transport, client: nil)
    }

    init(transport: any Transport, client: JsBaoClient?) {
        self.transport = transport
        self.client = client
        self.inspect = AgentSessionInspectAPI()
        inspect.attach(self)
    }

    // MARK: - Sessions

    /// List one user's sessions — your own by default — newest first. Pages
    /// may be shorter than `limit` when `scope` filters entries out; follow
    /// `nextCursor` while `hasMore` is true.
    public func list(options: ListAgentSessionsOptions? = nil) async throws -> PaginatedResult<AgentSessionListItem> {
        var query = URLQuery()
        query.appendIfPresent("userId", options?.userId)
        query.appendIfPresent("agent", options?.agent)
        query.appendIfPresent("scope", options?.scope)
        if let limit = options?.limit { query.append("limit", limit) }
        if let cursor = options?.cursor, !cursor.isEmpty { query.append("cursor", cursor) }
        let envelope: PaginatedPageEnvelope<AgentSessionListItem> = try await transport.request(
            method: .get, path: "/agent-sessions\(query.queryString)"
        )
        return envelope.page
    }

    /// Get one session. Members, the owner, app owners and admins may; anyone
    /// else is answered `AGENT_SESSION_NOT_FOUND`. App owners and admins also
    /// receive `object`, `turnContexts` and `lastTurn`.
    public func get(sessionId: String) async throws -> AgentSessionInfo {
        try await observed(sessionId) {
            try await transport.request(method: .get, path: try Self.sessionPath(sessionId))
        }
    }

    /// Rename a session (owner only). The title changes on the session, in
    /// every member's list, and on the document.
    public func rename(sessionId: String, title: String) async throws -> AgentSessionRenameResult {
        try Self.require(title, "title")
        return try await observed(sessionId) {
            try await transport.request(
                method: .patch, path: try Self.sessionPath(sessionId), body: ["title": title]
            )
        }
    }

    /// Delete a session and its document (the owner, an app owner or an
    /// admin). Deleting a session that is already deleted succeeds again.
    /// Once it returns, this client's queued uploads to the session, and the
    /// messages waiting on them, fail with `AGENT_SESSION_NOT_FOUND`.
    public func delete(sessionId: String) async throws -> AgentSessionDeleteResult {
        let blobs = client?.blobManager
        let identity = await blobs?.captureIdentity()
        let result: AgentSessionDeleteResult = try await observed(sessionId) {
            try await transport.request(method: .delete, path: try Self.sessionPath(sessionId))
        }
        if let blobs, let identity {
            await blobs.failAgentSessionUploads(sessionId: sessionId, error: Self.sessionGoneError(), identity: identity)
        }
        return result
    }

    // MARK: - Members

    /// Add a member, or change an existing member's role (owner only). The
    /// user must be an existing user of this app; a session holds at most 50
    /// members.
    public func addMember(
        sessionId: String, userId: String, role: AgentSessionMemberRole
    ) async throws -> AgentSessionMembersResult {
        try Self.require(userId, "userId")
        return try await observed(sessionId) {
            try await transport.request(
                method: .post,
                path: try Self.sessionPath(sessionId) + "/members",
                body: ["userId": userId, "role": role.rawValue]
            )
        }
    }

    /// Remove a member (owner only): their grant on the document is revoked
    /// and the session leaves their list. Removing someone who is not a
    /// member succeeds with the members unchanged.
    public func removeMember(sessionId: String, userId: String) async throws -> AgentSessionMembersResult {
        try Self.require(userId, "userId")
        return try await observed(sessionId) {
            try await transport.request(
                method: .delete,
                path: try Self.sessionPath(sessionId) + "/members/\(URLEncoding.encodeComponent(userId))"
            )
        }
    }

    // MARK: - Turns

    /// Send a message (the owner and participants). On an idle session it
    /// starts a turn; while a turn runs it waits in the queue. Refused with
    /// `AGENT_SESSION_PARTICIPANT_ONLY` for a viewer and
    /// `AGENT_SESSION_RATE_LIMITED` past the send limit. A `context` that is
    /// not a JSON object throws `.invalidArgument` before any request.
    public func send(sessionId: String, body: AgentSessionSendBody) async throws -> AgentSessionSendResult {
        let path = try Self.sessionPath(sessionId) + "/messages"
        if let context = body.context, context.objectValue == nil {
            throw JsBaoError(
                code: .invalidArgument,
                message: "context must be a JSON object",
                details: ["field": .string("context")]
            )
        }
        return try await observed(sessionId) {
            try await transport.request(method: .post, path: path, body: body)
        }
    }

    /// Answer a call the active turn waits on: approve or deny it, or give a
    /// client tool's output or error. The first valid answer wins; a repeat
    /// is refused `AGENT_CALL_ANSWERED`.
    public func answer(
        sessionId: String, callId: String, _ answer: AgentCallAnswer
    ) async throws -> AgentCallAnswerResult {
        try Self.require(callId, "callId")
        return try await observed(sessionId) {
            try await transport.request(
                method: .post,
                path: try Self.sessionPath(sessionId) + "/calls/\(URLEncoding.encodeComponent(callId))/answer",
                body: answer
            )
        }
    }

    /// Cancel the active turn, naming it; a turn that is no longer active is
    /// refused with `AGENT_TURN_STALE`. A view's `cancel()` fills the turn in.
    public func cancel(sessionId: String, turnId: String) async throws -> AgentSessionCancelResult {
        try Self.require(turnId, "turnId")
        return try await observed(sessionId) {
            try await transport.request(
                method: .post,
                path: try Self.sessionPath(sessionId) + "/cancel",
                body: ["turnId": turnId]
            )
        }
    }

    /// Mark a session read for the signed-in user (the owner, a participant
    /// or a viewer): its `hasUnread` is `false` in `list` and `get`, on every
    /// device, until the next activity. Call it when the user opens the
    /// session; an open view's `markRead()` does the same and updates its
    /// `info`. An app owner or admin who is not in the session is refused
    /// with `AGENT_SESSION_MEMBER_ONLY`.
    @discardableResult
    public func markRead(sessionId: String) async throws -> AgentSessionReadResult {
        try await observed(sessionId) {
            try await transport.request(
                method: .post, path: try Self.sessionPath(sessionId) + "/read", body: [String: String]()
            )
        }
    }

    /// Record an event (the owner and participants): a message of one event
    /// part, read by the agent on its next turn. Never starts a turn.
    public func recordEvent(sessionId: String, event: AgentSessionEvent) async throws -> AgentSessionEventResult {
        try await observed(sessionId) {
            try await transport.request(
                method: .post, path: try Self.sessionPath(sessionId) + "/events", body: event
            )
        }
    }

    // MARK: - Attachments

    /// Upload a file to a session under an id you choose (the owner and
    /// participants). A repeat with the same bytes answers the stored file and
    /// transfers nothing; with other bytes it is refused. A refusal throws
    /// `HttpError` with the server's code: `AGENT_SESSION_PARTICIPANT_ONLY`
    /// for a viewer, `AGENT_SESSION_NOT_FOUND` without standing,
    /// `AGENT_SESSION_ATTACHMENT_NOT_FOUND` for an id another document holds.
    /// `view.attachments.upload` queues and retries for you; this is the one
    /// request.
    public func uploadAttachment(
        sessionId: String, blobId: String, _ upload: AgentSessionAttachmentUpload
    ) async throws -> AgentSessionAttachmentUploadResult {
        let path = try Self.attachmentPath(sessionId, blobId)
        let headers = BlobManager.uploadHeaders(
            byteCount: upload.data.count, filename: upload.filename,
            contentType: upload.contentType ?? "application/octet-stream",
            sha256: BlobManager.sha256Base64(upload.data), disposition: upload.disposition
        )
        return try await observed(sessionId) {
            let (body, status) = try await transport.requestData(
                method: .put, path: path, body: upload.data, options: RequestOptions(customHeaders: headers)
            )
            guard (200..<300).contains(status) else {
                throw HttpError.fromBytes(status: status, message: "Attachment upload failed", body: body)
            }
            return try JSONCoding.decodeData(AgentSessionAttachmentUploadResult.self, from: body)
        }
    }

    /// Download a session's file (members, the owner, app owners and admins).
    /// A refusal throws `HttpError` with the server's code:
    /// `AGENT_SESSION_ATTACHMENT_NOT_FOUND` for an id the session does not
    /// hold, `AGENT_SESSION_NOT_FOUND` without standing.
    ///
    /// - Parameter disposition: the disposition to serve it with.
    public func downloadAttachment(
        sessionId: String, blobId: String, disposition: BlobDisposition? = nil
    ) async throws -> Data {
        let path = try Self.attachmentPath(sessionId, blobId) + Self.downloadSuffix(disposition)
        return try await observed(sessionId) {
            let (body, status) = try await transport.requestData(method: .get, path: path)
            guard (200..<300).contains(status) else {
                throw HttpError.fromBytes(status: status, message: "Attachment download failed", body: body)
            }
            return body
        }
    }

    /// Read a session file's download headers without its bytes. A refusal
    /// has no body, so it throws `HttpError` with the `status` (404, 403,
    /// 410) and no `serverCode`; call `get` to tell a missing session from a
    /// missing file.
    ///
    /// - Parameter disposition: the disposition the headers describe.
    public func attachmentHeaders(
        sessionId: String, blobId: String, disposition: BlobDisposition? = nil
    ) async throws -> AgentSessionAttachmentHeaders {
        let path = try Self.attachmentPath(sessionId, blobId) + Self.downloadSuffix(disposition)
        let response = try await transport.execute(method: .head, path: path, body: nil, options: nil)
        guard (200..<300).contains(response.status) || response.status == 304 else {
            throw HttpError(status: response.status, message: "HTTP \(response.status)")
        }
        var headers: [String: String] = [:]
        for (name, value) in response.headers { headers[name.lowercased()] = value }
        return AgentSessionAttachmentHeaders(status: response.status, headers: headers)
    }

    // MARK: - Session gone

    /// A session call that, when the session answers it is gone, fails the
    /// session's queued uploads (and the messages waiting on them) with that
    /// answer, under the identity the call was made by. The call's own result
    /// or error is unchanged. A sessions API with no client observes nothing.
    private func observed<T>(_ sessionId: String, _ call: () async throws -> T) async throws -> T {
        let blobs = client?.blobManager
        let identity = await blobs?.captureIdentity()
        do {
            return try await call()
        } catch {
            if let blobs, let identity, BlobManager.isSessionGone(error) {
                await blobs.failAgentSessionUploads(sessionId: sessionId, error: error, identity: identity)
            }
            throw error
        }
    }

    /// The error a session route answers once the session is gone, built here
    /// for `delete` so the failure has one shape whatever observed it.
    static func sessionGoneError() -> HttpError {
        let message = "No such agent session in this app"
        return HttpError(
            status: 404, message: "HTTP 404",
            body: #"{"error":"\#(message)","code":"AGENT_SESSION_NOT_FOUND"}"#,
            serverCode: "AGENT_SESSION_NOT_FOUND", serverMessage: message
        )
    }

    // MARK: - Paths

    static func sessionPath(_ sessionId: String) throws -> String {
        try require(sessionId, "sessionId")
        return "/agent-sessions/\(URLEncoding.encodeComponent(sessionId))"
    }

    static func attachmentPath(_ sessionId: String, _ blobId: String) throws -> String {
        try require(sessionId, "sessionId")
        try require(blobId, "blobId")
        return BlobManager.sessionAttachmentPath(sessionId: sessionId, blobId: blobId)
    }

    static func downloadSuffix(_ disposition: BlobDisposition?) -> String {
        "/download" + (disposition.map { "?disposition=\($0.rawValue)" } ?? "")
    }

    static func require(_ value: String, _ name: String) throws {
        guard !value.isEmpty else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "\(name) must not be empty",
                details: ["field": .string(name)]
            )
        }
    }
}

// MARK: - AgentSessionInspectAPI

/// Diagnostics for a session, available as `client.agents.sessions.inspect`.
/// Each call reads what the session calls already answer and grants nothing.
public final class AgentSessionInspectAPI: @unchecked Sendable {
    /// Set once, by the sessions API that owns this one, before either is
    /// published; only read after.
    private weak var sessions: AgentSessionsAPI?

    init() {}

    func attach(_ sessions: AgentSessionsAPI) {
        self.sessions = sessions
    }

    /// The document that backs the session, from `get`: for support and
    /// diagnostics, not for driving the session. Throws as `get` does,
    /// `AGENT_SESSION_DOCUMENT_MISSING` once the document is gone (nothing is
    /// recreated).
    public func storage(_ sessionId: String) async throws -> AgentSessionStorage {
        guard let sessions else {
            throw JsBaoError(code: .unavailable, message: "inspect.storage needs its sessions API")
        }
        let info = try await sessions.get(sessionId: sessionId)
        return AgentSessionStorage(documentId: info.storageDocumentId)
    }
}
