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
public final class AgentSessionsAPI: @unchecked Sendable {
    private let transport: any Transport
    weak var client: JsBaoClient?

    /// Designated initializer — the typed transport spine. Without a client,
    /// `open` throws `.unavailable`.
    public convenience init(transport: any Transport) {
        self.init(transport: transport, client: nil)
    }

    init(transport: any Transport, client: JsBaoClient?) {
        self.transport = transport
        self.client = client
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
        try await transport.request(method: .get, path: try Self.sessionPath(sessionId))
    }

    /// Rename a session (owner only). The title changes on the session, in
    /// every member's list, and on the document.
    public func rename(sessionId: String, title: String) async throws -> AgentSessionRenameResult {
        try Self.require(title, "title")
        return try await transport.request(
            method: .patch, path: try Self.sessionPath(sessionId), body: ["title": title]
        )
    }

    /// Delete a session and its document (the owner, an app owner or an
    /// admin). Deleting a session that is already deleted succeeds again.
    public func delete(sessionId: String) async throws -> AgentSessionDeleteResult {
        try await transport.request(method: .delete, path: try Self.sessionPath(sessionId))
    }

    // MARK: - Members

    /// Add a member, or change an existing member's role (owner only). The
    /// user must be an existing user of this app; a session holds at most 50
    /// members.
    public func addMember(
        sessionId: String, userId: String, role: AgentSessionMemberRole
    ) async throws -> AgentSessionMembersResult {
        try Self.require(userId, "userId")
        return try await transport.request(
            method: .post,
            path: try Self.sessionPath(sessionId) + "/members",
            body: ["userId": userId, "role": role.rawValue]
        )
    }

    /// Remove a member (owner only): their grant on the document is revoked
    /// and the session leaves their list. Removing someone who is not a
    /// member succeeds with the members unchanged.
    public func removeMember(sessionId: String, userId: String) async throws -> AgentSessionMembersResult {
        try Self.require(userId, "userId")
        return try await transport.request(
            method: .delete,
            path: try Self.sessionPath(sessionId) + "/members/\(URLEncoding.encodeComponent(userId))"
        )
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
        return try await transport.request(method: .post, path: path, body: body)
    }

    /// Answer a call the active turn waits on: approve or deny it, or give a
    /// client tool's output or error. The first valid answer wins; a repeat
    /// is refused `AGENT_CALL_ANSWERED`.
    public func answer(
        sessionId: String, callId: String, _ answer: AgentCallAnswer
    ) async throws -> AgentCallAnswerResult {
        try Self.require(callId, "callId")
        return try await transport.request(
            method: .post,
            path: try Self.sessionPath(sessionId) + "/calls/\(URLEncoding.encodeComponent(callId))/answer",
            body: answer
        )
    }

    /// Cancel the active turn, naming it; a turn that is no longer active is
    /// refused with `AGENT_TURN_STALE`. A view's `cancel()` fills the turn in.
    public func cancel(sessionId: String, turnId: String) async throws -> AgentSessionCancelResult {
        try Self.require(turnId, "turnId")
        return try await transport.request(
            method: .post,
            path: try Self.sessionPath(sessionId) + "/cancel",
            body: ["turnId": turnId]
        )
    }

    /// Mark a session read for the signed-in user (the owner, a participant
    /// or a viewer): its `hasUnread` is `false` in `list` and `get`, on every
    /// device, until the next activity. Call it when the user opens the
    /// session; an open view's `markRead()` does the same and updates its
    /// `info`. An app owner or admin who is not in the session is refused
    /// with `AGENT_SESSION_MEMBER_ONLY`.
    @discardableResult
    public func markRead(sessionId: String) async throws -> AgentSessionReadResult {
        try await transport.request(
            method: .post, path: try Self.sessionPath(sessionId) + "/read", body: [String: String]()
        )
    }

    /// Record an event (the owner and participants): a message of one event
    /// part, read by the agent on its next turn. Never starts a turn.
    public func recordEvent(sessionId: String, event: AgentSessionEvent) async throws -> AgentSessionEventResult {
        try await transport.request(
            method: .post, path: try Self.sessionPath(sessionId) + "/events", body: event
        )
    }

    // MARK: - Paths

    static func sessionPath(_ sessionId: String) throws -> String {
        try require(sessionId, "sessionId")
        return "/agent-sessions/\(URLEncoding.encodeComponent(sessionId))"
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
