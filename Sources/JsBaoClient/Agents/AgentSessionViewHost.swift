import Foundation

// What a session view needs of the client (#4884) — the Swift half of the JS
// client's `AgentSessionViewHost`: the session calls, the session's db3 (its
// subscription, its records by model name from the local copy, its
// eviction), a blob of that db3 read through the session's attachment route,
// the session's attachments, the signed-in user, and the client's change
// events and connection states. `client.agents.sessions.open` builds it from
// the client's internals; a view makes no call on the public `client.documents`.

/// The session's db3 on this device; its id is the session's.
struct AgentSessionDb3Door: Sendable {
    /// Subscribe to it, as `client.db3.subscribe` does.
    var subscribe: @Sendable (_ db3Id: String) throws -> Db3Subscription
    /// Its records by model name, from the local copy.
    var records: @Sendable (_ db3Id: String) -> DocumentRecords
    /// Remove its local copy, unjudged writes and all, as
    /// `client.db3.evict(_:options:)` with `force` does.
    var evict: @Sendable (_ db3Id: String) async throws -> Void
}

/// What `AgentSessionView` reaches the client through.
struct AgentSessionViewHost: Sendable {
    /// The session calls: `client.agents.sessions`.
    var sessions: AgentSessionsAPI
    var db3: AgentSessionDb3Door
    /// A blob of the session's db3, as bytes, through the session attachment
    /// route (an artifact's JSON).
    var readBlob: @Sendable (_ sessionId: String, _ blobId: String) async throws -> Data
    /// The signed-in user; with none, client tools run nothing.
    var currentUserId: @Sendable () -> String?
    /// Whether the client is connected now.
    var isConnected: @Sendable () -> Bool
    /// The session's attachments, for `view.attachments`.
    var attachments: @Sendable (_ sessionId: String, _ isClosed: @escaping @Sendable () -> Bool) -> AgentSessionAttachments
    /// The client's change events and connection states, heard from now.
    var signals: @Sendable () -> AgentSessionViewSignals
    /// Where a failure nothing awaits is told: an eviction after a loss.
    var logger: Logger?

    init(client: JsBaoClient, sessions: AgentSessionsAPI) {
        self.sessions = sessions
        self.db3 = AgentSessionDb3Door(
            subscribe: { [weak client] id in
                guard let client else {
                    throw db3DisposedError(id, .destroyed, message: "The client was destroyed")
                }
                client.noteResourceHeldDb3(id)
                return try client.db3.subscribe(id)
            },
            records: { [weak client] id in
                DocumentRecords(
                    documentId: id, logger: client?.logger,
                    readable: { [weak client] in
                        guard let client else { throw JsBaoClient.documentNotOpenForRecords(id) }
                        return try client.readableModelFreeBinding(id)
                    }
                ) { [weak client] in
                    guard let client else { throw JsBaoClient.documentNotOpenForRecords(id) }
                    return try client.modelFreeBinding(id)
                }
            },
            evict: { [weak client] id in
                try await client?.db3.evict(id, options: Db3EvictOptions(force: true))
            }
        )
        let blobs = client.blobManager
        // The db3's id, the session's, is the blob cache's key.
        self.readBlob = { sessionId, blobId in
            try await blobs.readSessionAttachment(
                sessionId: sessionId, documentId: sessionId, blobId: blobId, force: false, disposition: nil
            )
        }
        self.currentUserId = { [weak client] in client?.userId }
        self.isConnected = { [weak client] in client?.isConnected ?? false }
        self.attachments = { sessionId, isClosed in
            blobs.forAgentSession(sessionId: sessionId, documentId: sessionId, isClosed: isClosed)
        }
        self.signals = { AgentSessionViewSignals(client: client) }
        self.logger = client.logger
    }
}
