import Foundation
import XCTest
@testable import JsBaoClient

/// The live setup the agent session suites share (#3810): one app with an
/// owner, two participants, a viewer, a stranger and a tenant admin; a second
/// app with a user of its own; the pushed functions (`create`, `note`,
/// `lookup`, `sweep`); and seven agents steered at temperature 0 — PLAIN,
/// TOOLS, INITIATOR, EXPIRES, CONTEXT, SERVER and PRESENT (#4549: a server
/// tool, then a presentation referencing its result by call number).
///
/// Each live class builds its own through `make`, because a filtered
/// checkpoint runs one class alone. Assertions built on it are on shapes and
/// codes, never on the model's words; a turn whose model answered without the
/// calls it was told to make is sent once more (the #3807/#3809 pattern).
///
/// #4884: a session is its own db3, named by the session's id. Clients store
/// on SQLite (a db3 needs a persistent store), uploads go through the session
/// attachment route, and rows only the session writes are seeded through the
/// session object's local probe (`seed`), since no client writes a
/// resource-held db3.
final class AgentSessionScenarioHarness: @unchecked Sendable {
    static let model = "anthropic/claude-sonnet-4.5"
    /// A 1×1 PNG.
    static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    )!

    let ctx: TestContext
    let appId: String
    let otherAppId: String
    let owner: TestUser
    let part: TestUser
    let part2: TestUser
    let viewer: TestUser
    let stranger: TestUser
    let admin: TestUser
    let outsider: TestUser

    let stamp: String
    var createKey: String { "create-\(stamp)" }
    var noteKey: String { "note-\(stamp)" }
    var lookupKey: String { "lookup-\(stamp)" }
    var sweepKey: String { "sweep-\(stamp)" }

    var plain: String { "swift-plain-\(stamp)" }
    var tools: String { "swift-tools-\(stamp)" }
    var initiator: String { "swift-initiator-\(stamp)" }
    var expires: String { "swift-expires-\(stamp)" }
    var context: String { "swift-context-\(stamp)" }
    var server: String { "swift-server-\(stamp)" }
    var present: String { "swift-present-\(stamp)" }

    private let clientsBox = LockedBox([JsBaoClient]())
    private let viewsBox = LockedBox([AgentSessionView]())
    /// Where the clients' stores live; removed by `cleanup`.
    private let storeDirectory = NSTemporaryDirectory() + "agent-session-harness-\(UUID().uuidString)"
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    private init(
        ctx: TestContext, appId: String, otherAppId: String, owner: TestUser, part: TestUser,
        part2: TestUser, viewer: TestUser, stranger: TestUser, admin: TestUser, outsider: TestUser,
        stamp: String
    ) {
        self.ctx = ctx
        self.appId = appId
        self.otherAppId = otherAppId
        self.owner = owner
        self.part = part
        self.part2 = part2
        self.viewer = viewer
        self.stranger = stranger
        self.admin = admin
        self.outsider = outsider
        self.stamp = stamp
    }

    // MARK: - Setup

    static func make(_ name: String) async throws -> AgentSessionScenarioHarness {
        let ctx = TestContext()
        try await ctx.initialize()
        let appId = try await ctx.createTestApp(name: name).appId
        let otherAppId = try await ctx.createTestApp(name: "\(name)-other").appId
        let h = AgentSessionScenarioHarness(
            ctx: ctx, appId: appId, otherAppId: otherAppId,
            owner: try await ctx.createTestUser(appId: appId, name: "Olive Owner"),
            part: try await ctx.createTestUser(appId: appId, name: "Pat Participant"),
            part2: try await ctx.createTestUser(appId: appId, name: "Quinn Participant"),
            viewer: try await ctx.createTestUser(appId: appId, name: "Val Viewer"),
            stranger: try await ctx.createTestUser(appId: appId, name: "Sam Stranger"),
            admin: try await ctx.createTestUser(appId: appId, role: "admin", name: "Ada Admin"),
            outsider: try await ctx.createTestUser(appId: otherAppId, name: "Oscar Outsider"),
            stamp: "\(Int(Date().timeIntervalSince1970 * 1000) % 1_000_000_000)-\(UUID().uuidString.prefix(4).lowercased())"
        )
        try await h.pushFunctions()
        try await h.createAgents()
        return h
    }

    private func pushFunctions() async throws {
        try await ctx.pushFunction(
            appId: appId, functionKey: createKey,
            bundle: "export default async function (input, ctx) { return await ctx.agents.createSession(input); }",
            mode: "any"
        )
        try await ctx.pushFunction(
            appId: appId, functionKey: noteKey,
            bundle: """
            export default async function (input, ctx) {
              return await ctx.agents.recordEvent(input.sessionId, { kind: input.kind, data: input.data });
            }
            """,
            mode: "any"
        )
        try await ctx.pushFunction(
            appId: appId, functionKey: lookupKey,
            bundle: """
            export default async function (input, ctx) {
              await new Promise((resolve) => setTimeout(resolve, 1500));
              return { topic: input.topic, trigger: ctx.trigger.kind };
            }
            """,
            mode: "any",
            inputSchema: ["type": "object", "properties": ["topic": ["type": "string"]], "required": ["topic"]],
            outputSchema: ["type": "object", "properties": ["topic": ["type": "string"], "trigger": ["type": "string"]]]
        )
        try await ctx.pushFunction(
            appId: appId, functionKey: sweepKey,
            bundle: """
            export default async function (input, ctx) {
              return { month: input.month, trigger: ctx.trigger.kind };
            }
            """,
            mode: "any",
            inputSchema: ["type": "object", "properties": ["month": ["type": "string"]], "required": ["month"]],
            outputSchema: ["type": "object", "properties": ["month": ["type": "string"], "trigger": ["type": "string"]]]
        )
    }

    static var pickTool: [String: Any] { [
        "name": "pick",
        "description": "Ask the member to pick a number.",
        "runs": "client",
        "inputSchema": ["type": "object", "properties": ["question": ["type": "string"]], "required": ["question"]],
        "outputSchema": [
            "type": "object", "properties": ["count": ["type": "integer", "minimum": 1]], "required": ["count"],
        ],
    ] }
    static var signTool: [String: Any] { [
        "name": "sign",
        "description": "Ask the member to sign, once they approve.",
        "runs": "client",
        "approval": true,
        "inputSchema": ["type": "object", "properties": ["what": ["type": "string"]], "required": ["what"]],
        "outputSchema": ["type": "object", "properties": ["signed": ["type": "boolean"]], "required": ["signed"]],
    ] }

    /// Steer a model to call `calls` when the latest message is exactly `Go.`.
    private static func steer(_ calls: String) -> String {
        "You are a test harness, not an assistant. If the user's latest message is exactly `Go.` and you have " +
            "not yet called a tool in this turn, \(calls) and write no text. Once every result is back, whatever " +
            "it says, reply with the single word: done. To any other message, reply with the single word: ok."
    }

    private func createAgents() async throws {
        try await createAgent(plain, "Reply with the single word: ok.")
        try await createAgent(
            tools,
            Self.steer("call BOTH tools in one response, in parallel: `sign` with {\"what\":\"lease\"} and `pick` " +
                "with {\"question\":\"How many?\"}"),
            [
                "answeredBy": "participants",
                "tools": [Self.signTool, Self.pickTool],
                "events": [["name": "viewed", "schema": ["type": "object", "properties": ["item": ["type": "string"]]]]],
            ]
        )
        try await createAgent(
            initiator, Self.steer("call the tool `pick` with {\"question\":\"How many?\"}"),
            ["answeredBy": "initiator", "tools": [Self.pickTool]]
        )
        try await createAgent(
            expires, Self.steer("call the tool `pick` with {\"question\":\"How many?\"}"),
            ["waitLimitSeconds": 3, "tools": [Self.pickTool]]
        )
        try await createAgent(
            context, "Reply with the single word: ok. Plan {{ turn.plan }}.",
            ["turnContext": ["schema": [
                "type": "object",
                "properties": ["plan": ["type": "string", "enum": ["gold", "silver"]]],
                "required": ["plan"],
            ]]]
        )
        try await createAgent(
            server,
            Self.steer("call BOTH tools in one response, in parallel: `lookup` with {\"topic\":\"rent\"} and " +
                "`sweep` with {\"month\":\"2026-09\"}"),
            ["tools": [
                ["name": "lookup", "description": "Look a topic up.", "function": lookupKey],
                ["name": "sweep", "description": "Sweep the month.", "function": sweepKey, "invoke": "task"],
            ]]
        )
        try await createAgent(
            present,
            "You are a test harness, not an assistant. If the user's latest message is exactly `Go.` and you have " +
                "not yet called a tool in this turn, call the tool `lookup` with {\"topic\":\"rent\"} and write no " +
                "text. Once its result is back, in ONE response write the text `Here.` and call the tool `present` " +
                "with {\"show\":[N]} where N is the \"call\" number the lookup result was sent with. To any other " +
                "message, reply with the single word: ok.",
            ["tools": [
                ["name": "lookup", "description": "Look a topic up.", "function": lookupKey],
                [
                    "name": "present", "description": "Show the chosen results as cards beside your reply.",
                    "runs": "presentation", "references": ["show"],
                    "inputSchema": [
                        "type": "object", "required": ["show"],
                        "properties": ["show": ["type": "array", "items": ["type": "integer"]]],
                    ],
                ],
            ]]
        )
    }

    private func createAgent(_ key: String, _ systemPrompt: String, _ agent: [String: Any] = [:]) async throws {
        var body: [String: Any] = [
            "accessRule": "true", "promptKey": key, "displayName": key, "kind": "agent",
            "provider": "openrouter", "model": Self.model, "temperature": 0, "maxTokens": 400,
            "systemPrompt": systemPrompt,
        ]
        if !agent.isEmpty { body["agent"] = agent }
        try await ctx.adminPost("/admin/api/apps/\(appId)/prompts", body: body)
    }

    func cleanup() async {
        for view in viewsBox.withValue({ views -> [AgentSessionView] in defer { views.removeAll() }; return views }) {
            await view.close()
        }
        for client in clientsBox.withValue({ clients -> [JsBaoClient] in defer { clients.removeAll() }; return clients }) {
            await client.destroy()
        }
        await ctx.cleanup()
        try? FileManager.default.removeItem(atPath: storeDirectory)
    }

    // MARK: - Sessions

    /// A session: its id names its db3 too.
    struct Session: Sendable {
        let sessionId: String
    }

    /// A session created by the pushed `create` function, as the owner.
    func createSession(
        _ agent: String, participants: [TestUser] = [], viewers: [TestUser] = [], title: String? = nil,
        scope: String? = nil
    ) async throws -> Session {
        var input: [String: Any] = [
            "agent": agent, "variables": [String: Any](),
            "participants": participants.map(\.userId), "viewers": viewers.map(\.userId),
        ]
        if let title { input["title"] = title }
        if let scope { input["scope"] = scope }
        let result = try await ctx.appRequest(
            method: "POST", appId: appId, path: "/functions/\(createKey)",
            body: ["timeoutMs": 25_000, "rootInput": input], jwt: owner.jwt
        )
        guard result["status"] as? String == "completed",
              let output = result["output"] as? [String: Any],
              let sessionId = output["sessionId"] as? String
        else { throw TestSetupError("createSession failed: \(result)") }
        return Session(sessionId: sessionId)
    }

    /// The pushed `note` function, invoked over HTTP by `user`: an event the
    /// platform authors as `app`.
    func invokeNote(_ s: Session, as user: TestUser, kind: String = "viewed", data: [String: Any]) async throws -> [String: Any] {
        let result = try await ctx.appRequest(
            method: "POST", appId: appId, path: "/functions/\(noteKey)",
            body: ["timeoutMs": 25_000, "rootInput": ["sessionId": s.sessionId, "kind": kind, "data": data]],
            jwt: user.jwt
        )
        guard result["status"] as? String == "completed", let output = result["output"] as? [String: Any] else {
            throw TestSetupError("note failed: \(result)")
        }
        return output
    }

    // MARK: - Clients and views

    /// A connected client for `user` in `app` (this harness's app by default),
    /// storing on its own SQLite file.
    func client(_ user: TestUser, app: String? = nil) async throws -> JsBaoClient {
        try FileManager.default.createDirectory(atPath: storeDirectory, withIntermediateDirectories: true)
        let client = createTestClient(
            appId: app ?? appId, token: user.jwt,
            storageConfig: .sqlite(directory: storeDirectory + "/\(UUID().uuidString.prefix(8)).sqlite")
        )
        clientsBox.withValue { $0.append(client) }
        _ = await client.waitForStorageReady()
        try await client.connect()
        try await waitForConnection(client: client, timeout: 15)
        return client
    }

    func open(_ client: JsBaoClient, _ s: Session, pageSize: Int = 50) async throws -> AgentSessionView {
        let view = try await client.agents.sessions.open(
            sessionId: s.sessionId, options: OpenAgentSessionOptions(pageSize: pageSize)
        )
        viewsBox.withValue { $0.append(view) }
        return view
    }

    /// Upload the PNG to the session through its attachment route, as `client`'s user.
    func uploadPng(_ client: JsBaoClient, _ s: Session) async throws -> String {
        let blobId = ULID.generate()
        return try await client.agents.sessions.uploadAttachment(
            sessionId: s.sessionId, blobId: blobId,
            AgentSessionAttachmentUpload(data: Self.png, filename: "dot.png", contentType: "image/png")
        ).blobId
    }

    /// Rows only the session writes, written through its object's local probe
    /// (`write`): each `{ model, action: "create" | "patch", id, data }`.
    func seed(_ s: Session, operations: [[String: Any]]) async throws {
        try await probe(s, "write", body: ["operations": operations])
    }

    /// Calls `client` makes to the documents API for a document's info or
    /// format, counted at the client's two hooks; each call still answers.
    final class DocumentsCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        var all: [String] { lock.withLock { calls } }
        func note(_ call: String) { lock.withLock { calls.append(call) } }
    }

    func documentsCalls(of client: JsBaoClient) -> DocumentsCalls {
        let counted = DocumentsCalls()
        let fetch = client.documentManager.fetchDocumentInfo
        client.documentManager.fetchDocumentInfo = { [weak client] documentId in
            counted.note("info \(documentId)")
            if let fetch { return try await fetch(documentId) }
            guard let client else { throw JsBaoError(code: .unavailable) }
            return try await client.documents.get(documentId: documentId)
        }
        let lookup = client.documentFormatLookupForTest
        client.documentFormatLookupForTest = { [weak client] documentId in
            counted.note("format \(documentId)")
            if let lookup { return try await lookup(documentId) }
            guard let client else { throw JsBaoError(code: .unavailable) }
            return try await client.documents.get(documentId: documentId).documentFormat
        }
        return counted
    }

    // MARK: - The local probe

    /// `/test/agent-sessions/{app}/{session}/{action}` — local only.
    @discardableResult
    func probe(_ s: Session, _ action: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "\(TestConfig.httpUrl)/test/agent-sessions/\(appId)/\(s.sessionId)/\(action)")!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(TestConfig.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw TestSetupError("probe \(action) answered \(status): \(String(decoding: data, as: UTF8.self))")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Hold the next model round for `ms` (the probe's `slow-round-ms` fault).
    func slowRound(_ s: Session, ms: Int) async throws {
        try await probe(s, "fault", body: ["point": "slow-round-ms", "ms": ms])
    }

    /// The object's stored turn, or `nil` when none runs.
    func objectTurn(_ s: Session) async throws -> [String: Any]? {
        try await probe(s, "turn")["turn"] as? [String: Any]
    }

    /// Until the object has no turn left to run.
    func settled(_ s: Session, timeout: TimeInterval = 180) async throws {
        try await poll(timeout: timeout, interval: 1, "session \(s.sessionId) settles") {
            let turn = try await self.probe(s, "state")["turn"]
            return turn == nil || turn is NSNull
        }
    }

    /// Poll `check` until true; throws on the deadline (a hard failure, unlike
    /// `eventually`, so a scenario stops where it went wrong).
    func poll(
        timeout: TimeInterval, interval: TimeInterval = 0.25, _ what: String,
        _ check: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                if try await check() { return }
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        throw TestSetupError("timed out waiting for \(what)\(lastError.map { ": \($0)" } ?? "")")
    }

    /// A turn paused on exactly the calls named, from `sender`'s send of
    /// `Go.` — sent once more when the model called something else or nothing.
    /// Answers the paused turn's summary from `get` and the send's answer.
    func pausedTurn(
        _ s: Session, sender: JsBaoClient, toolNames: [String]
    ) async throws -> (sent: AgentSessionSendResult, turn: AgentSessionTurnSummary) {
        let sessions = sender.agents.sessions
        var last = "nothing"
        for _ in 0..<2 {
            let sent = try await sessions.send(sessionId: s.sessionId, body: AgentSessionSendBody(text: "Go."))
            var summary: AgentSessionTurnSummary?
            try await poll(timeout: 120, interval: 0.5, "the turn pauses or ends") {
                let info = try await sessions.get(sessionId: s.sessionId)
                summary = info.turn
                return info.turn == nil || info.turn?.phase == .paused
            }
            if let summary, summary.turnId == sent.turnId, summary.pause?.callIds.count == toolNames.count {
                return (sent, summary)
            }
            last = String(describing: summary)
            if let summary, let callIds = summary.pause?.callIds {
                for callId in callIds {
                    _ = try? await sessions.answer(sessionId: s.sessionId, callId: callId, .approval(approved: false))
                    _ = try? await sessions.answer(sessionId: s.sessionId, callId: callId, .error(message: "skipped"))
                }
            }
            try await settled(s)
        }
        throw TestSetupError("the model did not pause on \(toolNames): \(last)")
    }
}

// MARK: - View reading helpers

extension AgentSessionView {
    var syncedMessages: [AgentSessionSyncedMessage] {
        messages.compactMap { if case let .synced(m) = $0 { return m } else { return nil } }
    }

    var pendingMessages: [AgentSessionPendingMessage] {
        messages.compactMap { if case let .pending(m) = $0 { return m } else { return nil } }
    }

    /// Every tool call in the window: its `ToolCall` records.
    var toolCalls: [AgentSessionToolCallRecord] {
        syncedMessages.flatMap(\.parts).compactMap { if case let .toolCall(call) = $0 { return call } else { return nil } }
    }

    func toolCall(_ callId: String) -> AgentSessionToolCallRecord? {
        toolCalls.first { $0.id == callId }
    }

    /// Every step of the window's turns, once each.
    var allSteps: [AgentSessionStepRecord] {
        var seen = Set<String>()
        return syncedMessages.flatMap(\.steps).filter { seen.insert($0.id).inserted }
    }
}

extension AgentSessionViewPart {
    /// The text or reasoning columns of a `Part`, or `nil`.
    var textPart: AgentSessionTextPart? {
        guard case let .part(part) = self else { return nil }
        switch part.content {
        case let .text(text), let .reasoning(text): return text
        default: return nil
        }
    }

    /// The file columns of a `Part`, or `nil`.
    var filePart: AgentSessionFilePart? {
        guard case let .part(part) = self, case let .file(file) = part.content else { return nil }
        return file
    }

    /// The event columns of a `Part`, or `nil`.
    var eventPart: AgentSessionEventPart? {
        guard case let .part(part) = self, case let .event(event) = part.content else { return nil }
        return event
    }
}

/// A thread-safe list a listener appends to.
final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}
