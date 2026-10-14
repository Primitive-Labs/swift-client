import XCTest
@testable import JsBaoClient

/// `client.agents.sessions.open` and the `AgentSessionView` it answers, over
/// local-only documents and a recording transport (#3810, plan behaviors
/// 10–18 and edge cases 33–34). The JS client's `sessionView.ts` is the
/// reference.
final class AgentSessionViewHermeticTests: XCTestCase {
    private var clients: [JsBaoClient] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
    }

    // MARK: - Fixture

    /// Scripted answers by route; the transport records every call.
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: [(Int, String)]] = [:]

        /// Answer `method path` with each body in turn; the last one repeats.
        func on(_ method: HTTPMethod, _ path: String, status: Int = 200, _ body: String) {
            lock.withLock { answers["\(method.rawValue) \(path)", default: []].append((status, body)) }
        }

        /// Answer `method path` with `body` from now on.
        func set(_ method: HTTPMethod, _ path: String, status: Int = 200, _ body: String) {
            lock.withLock { answers["\(method.rawValue) \(path)"] = [(status, body)] }
        }

        func answer(_ request: RecordedRequest) -> TransportResponse {
            let key = "\(request.method.rawValue) \(request.path)"
            let (status, body): (Int, String) = lock.withLock {
                guard var queue = answers[key], let first = queue.first else {
                    return (404, #"{"code":"NOT_SCRIPTED","error":"\#(key)"}"#)
                }
                if queue.count > 1 { queue.removeFirst(); answers[key] = queue }
                return first
            }
            return TransportResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        }
    }

    private struct Harness {
        let client: JsBaoClient
        let sessions: AgentSessionsAPI
        let transport: RecordingTransport
        let script: Script
    }

    private static let localOpen = OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)

    private func harness(_ name: String) -> Harness {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "agent-session-view-\(name)",
            token: "test-token", offline: false, logLevel: .none,
            storageConfig: .memory, autoNetwork: false
        ))
        clients.append(client)
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        let script = Script()
        let transport = RecordingTransport { script.answer($0) }
        return Harness(
            client: client,
            sessions: AgentSessionsAPI(transport: transport, client: client),
            transport: transport,
            script: script
        )
    }

    private static func info(_ sessionId: String, documentId: String, turnId: String? = nil) -> String {
        let turn = turnId.map {
            #"{"turnId":"\#($0)","initiatorUserId":"u1","startedAt":null,"phase":"model","rounds":1,"leaseUntil":null,"answeredBy":null,"pause":null,"pending":null}"#
        } ?? "null"
        return #"""
        {"sessionId":"\#(sessionId)","agentKey":"helper","documentId":"\#(documentId)","ownerUserId":"u1",
         "createdAt":"2026-10-01T00:00:00.000Z","title":null,"scope":null,"lastActivityAt":null,
         "members":{"viewers":[],"participants":["u2"]},"role":"owner","status":"idle","turn":\#(turn)}
        """#
    }

    /// A local-only document with the platform models registered, open, and
    /// `get` scripted to name it.
    private func session(_ h: Harness, _ sessionId: String, turnId: String? = nil) async throws -> String {
        let created = try await h.client.createDocument(options: CreateDocumentOptions(localOnly: true))
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        h.client.registerModels(AgentSessionModels.schemas)
        _ = try await h.client.documents.open(documentId, options: Self.localOpen)
        h.script.on(.get, "/agent-sessions/\(sessionId)", Self.info(sessionId, documentId: documentId, turnId: turnId))
        return documentId
    }

    private func open(_ h: Harness, _ sessionId: String, pageSize: Int = 50) async throws -> AgentSessionView {
        try await h.sessions.open(
            sessionId: sessionId, options: OpenAgentSessionOptions(pageSize: pageSize, open: Self.localOpen)
        )
    }

    private static let created = "2026-10-01T00:00:00.000Z"

    private func saveSession(
        _ h: Harness, in documentId: String, id: String = "session",
        status: String = "idle", activeTurnId: String? = nil, queue: String? = nil, unreadable: Bool = false
    ) throws {
        // The store refuses a missing required column, so an undecodable row
        // carries one that does not read: a schema version that is no finite
        // number.
        var values: [String: PrimitiveValue] = [
            "schemaVersion": .number(unreadable ? .infinity : 1), "agentKey": .string("helper"),
            "status": .string(status), "createdAt": .date(Self.created),
        ]
        if let activeTurnId { values["activeTurnId"] = .string(activeTurnId) }
        if let queue { values["queue"] = .string(queue) }
        try h.client.codegen.save(PrimitiveSession.primitiveSchema, id: id, values: values, in: documentId)
    }

    private func saveMessage(
        _ h: Harness, in documentId: String, id: String, seq: Double,
        turnId: String? = nil, clientMessageId: String? = nil, authorKind: String = "user"
    ) throws {
        var values: [String: PrimitiveValue] = [
            "seq": .number(seq), "authorKind": .string(authorKind), "createdAt": .date(Self.created),
        ]
        if let turnId { values["turnId"] = .string(turnId) }
        if let clientMessageId { values["clientMessageId"] = .string(clientMessageId) }
        try h.client.codegen.save(PrimitiveMessage.primitiveSchema, id: id, values: values, in: documentId)
    }

    private func savePart(
        _ h: Harness, in documentId: String, id: String, messageId: String, seq: Double,
        kind: String = "text", text: String? = "hello"
    ) throws {
        var values: [String: PrimitiveValue] = [
            "messageId": .string(messageId), "seq": .number(seq), "kind": .string(kind),
            "createdAt": .date(Self.created),
        ]
        if let text { values["text"] = .string(text) }
        try h.client.codegen.save(PrimitivePart.primitiveSchema, id: id, values: values, in: documentId)
    }

    private func saveStep(_ h: Harness, in documentId: String, id: String, turnId: String, seq: Double) throws {
        try h.client.codegen.save(PrimitiveStep.primitiveSchema, id: id, values: [
            "turnId": .string(turnId), "seq": .number(seq), "kind": .string("model_call"),
            "status": .string("completed"), "startedAt": .date(Self.created),
        ], in: documentId)
    }

    /// Seed `count` messages with seq 1…count; each has one part, and message
    /// n belongs to turn `t<n>` with one step.
    private func seed(_ h: Harness, in documentId: String, count: Int, prefix: String = "m") throws {
        for n in 1...count {
            let id = "\(prefix)\(String(format: "%03d", n))"
            try saveMessage(h, in: documentId, id: id, seq: Double(n), turnId: "\(prefix)t\(n)")
            try savePart(h, in: documentId, id: "\(id)-p", messageId: id, seq: Double(n))
            try saveStep(h, in: documentId, id: "\(id)-s", turnId: "\(prefix)t\(n)", seq: Double(n))
        }
    }

    private func synced(_ view: AgentSessionView) -> [AgentSessionSyncedMessage] {
        view.messages.compactMap { if case let .synced(m) = $0 { return m } else { return nil } }
    }

    private func pending(_ view: AgentSessionView) -> [AgentSessionPendingMessage] {
        view.messages.compactMap { if case let .pending(m) = $0 { return m } else { return nil } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private func assertCode(
        _ expected: JsBaoErrorCode, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, expected, file: file, line: line)
        } catch {
            XCTFail("expected JsBaoError(\(expected)), got \(error)", file: file, line: line)
        }
    }

    // MARK: - Behavior 10: open order and close

    func testARefusedGetThrowsBeforeAnythingIsRegisteredOrOpened() async throws {
        let h = harness("refused")
        h.script.on(.get, "/agent-sessions/gone", status: 404, #"{"code":"AGENT_SESSION_NOT_FOUND","error":"no"}"#)
        do {
            _ = try await open(h, "gone")
            XCTFail("open should throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, "AGENT_SESSION_NOT_FOUND")
        }
        for schema in AgentSessionModels.schemas {
            XCTAssertNil(h.client.sharedModel(schema.name), "\(schema.name) must not be registered")
        }
        XCTAssertEqual(h.transport.calls.map(\.path), ["/agent-sessions/gone"])
    }

    func testOpenRegistersTheModelsOpensTheDocumentAndLoadsTheWindow() async throws {
        let h = harness("opens")
        let created = try await h.client.createDocument(options: CreateDocumentOptions(localOnly: true))
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        h.script.on(.get, "/agent-sessions/s1", Self.info("s1", documentId: documentId))

        let view = try await open(h, "s1")
        XCTAssertTrue(h.client.isDocumentOpen(documentId), "the session's document is open")
        for schema in AgentSessionModels.schemas {
            XCTAssertEqual(h.client.sharedModel(schema.name)?.schema, schema, "\(schema.name) is registered")
        }
        XCTAssertEqual(view.sessionId, "s1")
        XCTAssertEqual(view.documentId, documentId)
        XCTAssertEqual(view.info.role, .owner)
        XCTAssertTrue(view.messages.isEmpty)

        try saveMessage(h, in: documentId, id: "m1", seq: 1)
        try await eventually(description: "the first message reaches the window") { self.synced(view).count == 1 }

        await view.close()
        XCTAssertFalse(h.client.isDocumentOpen(documentId), "close closes the document")
        await view.close()
        XCTAssertFalse(h.client.isDocumentOpen(documentId), "a second close is harmless")
    }

    func testDefaultOpenWaitsForTheNetworkWithSyncOn() async throws {
        // Offline, a `.network` open with sync on cannot be satisfied: the
        // error shows the default was used rather than a local open.
        let h = harness("default-open")
        let created = try await h.client.createDocument(options: CreateDocumentOptions(localOnly: false))
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        h.script.on(.get, "/agent-sessions/s1", Self.info("s1", documentId: documentId))
        h.client.setNetworkMode(.offline)
        do {
            _ = try await h.sessions.open(sessionId: "s1")
            XCTFail("a network open while offline should throw")
        } catch let error as JsBaoError {
            XCTAssertNotEqual(error.code, .invalidArgument)
        }
        let local = try await h.sessions.open(
            sessionId: "s1", options: OpenAgentSessionOptions(open: Self.localOpen)
        )
        await local.close()
    }

    // MARK: - Behavior 11: the platform names

    func testADifferentSchemaUnderAPlatformNameIsRefusedBeforeAnythingOpens() async throws {
        let h = harness("name-taken")
        let created = try await h.client.createDocument(options: CreateDocumentOptions(localOnly: true))
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        h.script.on(.get, "/agent-sessions/s1", Self.info("s1", documentId: documentId))
        h.client.registerModels([PrimitiveSchema(
            name: "PrimitiveMessage",
            fields: ["id": FieldDescriptor(type: .id, autoAssign: true), "body": FieldDescriptor(type: .string)]
        )])

        do {
            _ = try await open(h, "s1")
            XCTFail("open should throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .agentSessionModelNameTaken)
            XCTAssertEqual(error.details?["model"], .string("PrimitiveMessage"))
        }
        XCTAssertNil(h.client.sharedModel("PrimitiveSession"), "nothing was registered")
        XCTAssertFalse(h.client.isDocumentOpen(documentId), "nothing was opened")
    }

    func testThePlatformSchemasRegisteredBeforehandAreAccepted() async throws {
        let h = harness("name-ours")
        _ = try await session(h, "s1")
        let view = try await open(h, "s1")
        XCTAssertEqual(view.sessionId, "s1")
        await view.close()
    }

    // MARK: - Behavior 12: the window

    func testTheWindowIsTheLatestPageWithPartsAndStepsAndStaysInItsDocument() async throws {
        let h = harness("window")
        let first = try await session(h, "s1")
        try seed(h, in: first, count: 120)
        try savePart(h, in: first, id: "m120-a", messageId: "m120", seq: 0)
        try savePart(h, in: first, id: "m120-b", messageId: "m120", seq: 0)
        try saveStep(h, in: first, id: "m120-s0", turnId: "mt120", seq: 0)
        let second = try await session(h, "s2")
        try seed(h, in: second, count: 30, prefix: "x")

        let view = try await open(h, "s1")
        let window = synced(view)
        XCTAssertEqual(window.count, 50)
        XCTAssertEqual(window.map(\.seq), (71...120).map(Double.init), "the latest 50 by seq, oldest first")
        XCTAssertTrue(view.hasOlder)
        XCTAssertTrue(window.allSatisfy { $0.messageId.hasPrefix("m") }, "only this session's rows")
        let last = try XCTUnwrap(window.last)
        XCTAssertEqual(last.parts.map(\.id), ["m120-a", "m120-b", "m120-p"], "parts by seq then id")
        XCTAssertEqual(last.steps.map(\.id), ["m120-s0", "m120-s"], "the turn's steps by seq")
        XCTAssertEqual(window.first?.parts.map(\.id), ["m071-p"])

        let other = try await open(h, "s2")
        XCTAssertEqual(synced(other).count, 30)
        XCTAssertTrue(synced(other).allSatisfy { $0.messageId.hasPrefix("x") }, "the second session shows only its own rows")
        XCTAssertFalse(other.hasOlder)
        await view.close()
        await other.close()
    }

    // MARK: - Behavior 13: paging

    func testLoadOlderPagesBackToTheStartThenAnswersNothing() async throws {
        let h = harness("older")
        let documentId = try await session(h, "s1")
        try seed(h, in: documentId, count: 120)
        let view = try await open(h, "s1")

        async let a = view.loadOlder()
        async let b = view.loadOlder()
        let (pageA, pageB) = try await (a, b)
        XCTAssertEqual(pageA, AgentSessionLoadOlderResult(loaded: 50, hasOlder: true))
        XCTAssertEqual(pageB, pageA, "concurrent calls share one page")
        XCTAssertEqual(synced(view).count, 100)
        XCTAssertEqual(synced(view).first?.seq, 21)

        let last = try await view.loadOlder()
        XCTAssertEqual(last, AgentSessionLoadOlderResult(loaded: 20, hasOlder: false))
        XCTAssertEqual(synced(view).map(\.seq), (1...120).map(Double.init))
        XCTAssertFalse(view.hasOlder)
        XCTAssertEqual(synced(view).first?.parts.map(\.id), ["m001-p"])
        XCTAssertEqual(synced(view).first?.steps.map(\.id), ["m001-s"])

        let none = try await view.loadOlder()
        XCTAssertEqual(none, AgentSessionLoadOlderResult(loaded: 0, hasOlder: false))

        let again = try await open(h, "s1")
        await again.close()
        let closed = try await view.loadOlder()
        XCTAssertEqual(closed, AgentSessionLoadOlderResult(loaded: 0, hasOlder: false), "after close")
    }

    // MARK: - Behavior 14: pending entries

    func testSendShowsAPendingEntryThatLeavesWhenItsRowArrives() async throws {
        let h = harness("pending")
        let documentId = try await session(h, "s1")
        h.script.on(.post, "/agent-sessions/s1/messages", #"{"messageId":"m-accepted","seq":5,"turnId":"t1","queued":false}"#)
        let view = try await open(h, "s1")

        let result = try await view.send(
            text: "hello", files: [AgentSessionFileRef(blobId: "b1")],
            context: ["plan": "pro"], timezone: "Europe/Paris", locale: "fr-FR"
        )
        XCTAssertEqual(result.messageId, "m-accepted")
        let entry = try XCTUnwrap(pending(view).first)
        XCTAssertEqual(entry.state, .sending)
        XCTAssertEqual(entry.text, "hello")
        XCTAssertEqual(entry.files, [AgentSessionFileRef(blobId: "b1")])
        XCTAssertEqual(entry.context, ["plan": "pro"])
        XCTAssertEqual(entry.timezone, "Europe/Paris")
        XCTAssertEqual(entry.locale, "fr-FR")
        XCTAssertEqual(entry.messageId, "m-accepted")
        XCTAssertEqual(entry.clientMessageId.count, 26, "a generated ULID")
        XCTAssertEqual(h.transport.lastCall?.jsonBody, [
            "text": "hello", "files": [["blobId": "b1"]], "clientMessageId": .string(entry.clientMessageId),
            "context": ["plan": "pro"], "timezone": "Europe/Paris", "locale": "fr-FR",
        ])

        try saveMessage(h, in: documentId, id: "m-accepted", seq: 5, clientMessageId: entry.clientMessageId)
        try await eventually(description: "the pending entry gives way to its row") {
            self.pending(view).isEmpty && self.synced(view).map(\.messageId) == ["m-accepted"]
        }
        XCTAssertEqual(synced(view).first?.clientMessageId, entry.clientMessageId)
        await view.close()
    }

    func testAPendingEntryIsVisibleWhileTheSendIsInFlight() async throws {
        let h = harness("pending-in-flight")
        let documentId = try await session(h, "s1")
        let gate = AsyncGate()
        let client = h.client
        let transport = RecordingTransport { request in
            if request.path == "/agent-sessions/s1/messages" {
                await gate.wait()
                return TransportResponse(status: 200, headers: [:], body: Data(#"{"messageId":"m9","seq":9,"turnId":null,"queued":true}"#.utf8))
            }
            return TransportResponse(status: 200, headers: [:], body: Data(Self.info("s1", documentId: documentId).utf8))
        }
        let sessions = AgentSessionsAPI(transport: transport, client: client)
        let view = try await sessions.open(sessionId: "s1", options: OpenAgentSessionOptions(open: Self.localOpen))

        let sending = Task { try await view.send(text: "first", clientMessageId: "cm-1") }
        try await eventually(description: "the entry appears before the answer") { self.pending(view).count == 1 }
        XCTAssertEqual(pending(view).first?.state, .sending)
        XCTAssertNil(pending(view).first?.messageId)
        await gate.open()
        _ = try await sending.value
        XCTAssertEqual(pending(view).first?.messageId, "m9")
        await view.close()
    }

    func testARefusedSendFailsTheEntryAndRetryResendsTheSameBody() async throws {
        let h = harness("failed")
        _ = try await session(h, "s1")
        h.script.on(.post, "/agent-sessions/s1/messages", status: 429,
                    #"{"code":"AGENT_SESSION_RATE_LIMITED","error":"Slow down","details":{"retryAfter":12}}"#)
        h.script.on(.post, "/agent-sessions/s1/messages", #"{"messageId":"m2","seq":2,"turnId":"t2","queued":false}"#)
        let view = try await open(h, "s1")

        do {
            try await view.send(text: "hi", files: [AgentSessionFileRef(blobId: "b")], clientMessageId: "cm-x",
                                context: ["k": 1], timezone: "UTC", locale: "en")
            XCTFail("the send should rethrow")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, "AGENT_SESSION_RATE_LIMITED")
        }
        let failed = try XCTUnwrap(pending(view).first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.error, AgentSessionSendError(code: "AGENT_SESSION_RATE_LIMITED", message: "Slow down", retryAfter: 12))
        let firstBody = h.transport.lastCall?.jsonBody

        let retried = try await view.retry(clientMessageId: "cm-x")
        XCTAssertEqual(retried.messageId, "m2")
        XCTAssertEqual(h.transport.lastCall?.jsonBody, firstBody, "retry resends an identical body")
        XCTAssertEqual(pending(view).first?.state, .sending)
        XCTAssertNil(pending(view).first?.error)

        await assertCode(.invalidArgument) { _ = try await view.retry(clientMessageId: "cm-unknown") }
        await view.close()
    }

    func testDismissRemovesOnlyAFailedEntryAndASecondSendReplacesTheFirst() async throws {
        let h = harness("dismiss")
        _ = try await session(h, "s1")
        h.script.on(.post, "/agent-sessions/s1/messages", status: 409, #"{"code":"AGENT_CLIENT_ID_CONFLICT","error":"conflict"}"#)
        let view = try await open(h, "s1")

        _ = try? await view.send(text: "one", clientMessageId: "cm-1")
        _ = try? await view.send(text: "two", clientMessageId: "cm-1")
        XCTAssertEqual(pending(view).map(\.text), ["two"], "an earlier entry under the same id gives way")
        XCTAssertEqual(pending(view).first?.error?.code, "AGENT_CLIENT_ID_CONFLICT")

        XCTAssertFalse(view.dismiss(clientMessageId: "cm-unknown"))
        XCTAssertTrue(view.dismiss(clientMessageId: "cm-1"))
        XCTAssertTrue(pending(view).isEmpty)
        XCTAssertFalse(view.dismiss(clientMessageId: "cm-1"))
        await view.close()
    }

    // MARK: - Behavior 15: the session row

    func testQueuedStateStatusAndActiveTurnComeFromTheSessionRow() async throws {
        let h = harness("queued")
        let documentId = try await session(h, "s1")
        try saveMessage(h, in: documentId, id: "m1", seq: 1, turnId: "t1")
        try saveMessage(h, in: documentId, id: "m2", seq: 2)
        let view = try await open(h, "s1")
        XCTAssertNil(view.session)
        XCTAssertNil(view.status, "nil until the row has synced")
        XCTAssertNil(view.activeTurnId)
        XCTAssertEqual(view.queue, [])
        XCTAssertEqual(synced(view).map(\.state), [.synced, .synced])

        try saveSession(h, in: documentId, status: "thinking", activeTurnId: "t1",
                        queue: #"[{"userId":"u2","messageIds":["m2"]}]"#)
        try await eventually(description: "the row is read") { view.status == .thinking }
        XCTAssertEqual(view.activeTurnId, "t1")
        XCTAssertEqual(view.queue, [PrimitiveQueueEntry(userId: "u2", messageIds: ["m2"])])
        try await eventually(description: "m2 is queued") { self.synced(view).map(\.state) == [.synced, .queued] }

        try saveSession(h, in: documentId, status: "musing", queue: "[]")
        try await eventually(description: "the queue empties") { self.synced(view).map(\.state) == [.synced, .synced] }
        XCTAssertEqual(view.status, .unknown("musing"))
        await view.close()
    }

    // MARK: - Behavior 16: onChange

    func testOnChangeFiresOncePerChangeOutsideTheLockAndStopsWhenRemovedOrClosed() async throws {
        let h = harness("on-change")
        let documentId = try await session(h, "s1")
        try saveMessage(h, in: documentId, id: "m1", seq: 1)
        let view = try await open(h, "s1")
        let counter = Counter()
        let removedCounter = Counter()
        let remove = view.onChange { [view] in
            // Reading state from a listener would deadlock if it ran under the lock.
            _ = view.messages
            counter.increment()
        }
        let removeOther = view.onChange { removedCounter.increment() }
        removeOther()
        let before = synced(view)

        try saveSession(h, in: documentId, status: "thinking")
        try await eventually(description: "one notification") { counter.count >= 1 }
        await settle()
        XCTAssertEqual(counter.count, 1, "a session-row-only write notifies once")
        XCTAssertEqual(synced(view), before, "the messages are unchanged")
        XCTAssertEqual(removedCounter.count, 0, "a removed listener is not called")

        let burst = 40
        for n in 0..<burst {
            try saveSession(h, in: documentId, status: n.isMultiple(of: 2) ? "idle" : "thinking", activeTurnId: "t\(n)")
        }
        try await eventually(description: "the burst is read") { view.activeTurnId == "t\(burst - 1)" }
        await settle()
        XCTAssertLessThan(counter.count - 1, burst, "a burst of writes notifies fewer times than it writes")

        remove()
        let afterRemove = counter.count
        try saveMessage(h, in: documentId, id: "m2", seq: 2)
        try await eventually(description: "m2 arrives") { self.synced(view).count == 2 }
        XCTAssertEqual(counter.count, afterRemove)

        let late = Counter()
        view.onChange { late.increment() }
        await view.close()
        // Close closed the document; open it again directly so a write lands.
        _ = try await h.client.documents.open(documentId, options: Self.localOpen)
        try saveMessage(h, in: documentId, id: "m3", seq: 3)
        await settle()
        XCTAssertEqual(late.count, 0, "nothing fires after close")
    }

    // MARK: - Behavior 17: cancel and refreshInfo

    func testCancelResolvesItsTurnFromTheArgumentTheRowOrGet() async throws {
        let h = harness("cancel")
        let documentId = try await session(h, "s1")
        h.script.on(.post, "/agent-sessions/s1/cancel", #"{"turnId":"x","cancelled":true,"nextTurnId":null}"#)
        let view = try await open(h, "s1")

        // Neither an argument, a row nor a turn from get: nothing is sent.
        await assertCode(.agentSessionNoActiveTurn) { _ = try await view.cancel() }
        XCTAssertFalse(h.transport.calls.contains { $0.path.hasSuffix("/cancel") })

        _ = try await view.cancel(turnId: "t-given")
        XCTAssertEqual(h.transport.lastCall?.jsonBody, ["turnId": "t-given"])

        h.script.set(.get, "/agent-sessions/s1", Self.info("s1", documentId: documentId, turnId: "t-from-get"))
        _ = try await view.cancel()
        XCTAssertEqual(h.transport.lastCall?.jsonBody, ["turnId": "t-from-get"])
        XCTAssertEqual(h.transport.calls.suffix(2).map(\.method), [.get, .post])

        try saveSession(h, in: documentId, status: "thinking", activeTurnId: "t-row")
        try await eventually(description: "the row names a turn") { view.activeTurnId == "t-row" }
        _ = try await view.cancel()
        XCTAssertEqual(h.transport.lastCall?.jsonBody, ["turnId": "t-row"])
        await view.close()
    }

    func testRefreshInfoReReadsGetAndNotifies() async throws {
        let h = harness("refresh-info")
        let documentId = try await session(h, "s1")
        let view = try await open(h, "s1")
        let counter = Counter()
        view.onChange { counter.increment() }
        XCTAssertNil(view.info.turn)
        h.script.set(.get, "/agent-sessions/s1", Self.info("s1", documentId: documentId, turnId: "t9"))
        let info = try await view.refreshInfo()
        XCTAssertEqual(info.turn?.turnId, "t9")
        XCTAssertEqual(view.info.turn?.turnId, "t9")
        XCTAssertEqual(counter.count, 1)

        h.script.on(.post, "/agent-sessions/s1/calls/c1/answer", #"{"callId":"c1","state":"output-available"}"#)
        let answered = try await view.answer(callId: "c1", .output(["ok": true]))
        XCTAssertEqual(answered.state, .outputAvailable)
        h.script.on(.post, "/agent-sessions/s1/events", #"{"messageId":"e1","seq":3}"#)
        let event = try await view.recordEvent(AgentSessionEvent(kind: "viewed", data: ["at": 1]))
        XCTAssertEqual(event.messageId, "e1")
        await view.close()
    }

    func testMarkReadMarksTheSessionClearsTheDotAndNotifies() async throws {
        let h = harness("mark-read")
        let documentId = try await session(h, "s1")
        h.script.set(.get, "/agent-sessions/s1", Self.info("s1", documentId: documentId).replacingOccurrences(
            of: #""role":"owner","#, with: #""role":"owner","hasUnread":true,"lastReadAt":null,"#
        ))
        let view = try await open(h, "s1")
        XCTAssertTrue(view.info.hasUnread)
        let counter = Counter()
        view.onChange { counter.increment() }
        h.script.on(.post, "/agent-sessions/s1/read", #"{"sessionId":"s1","lastReadAt":"2026-10-02T00:00:09.000Z"}"#)
        let marked = try await view.markRead()
        XCTAssertEqual(marked.lastReadAt, "2026-10-02T00:00:09.000Z")
        XCTAssertEqual(h.transport.lastCall?.path, "/agent-sessions/s1/read")
        XCTAssertEqual(h.transport.lastCall?.jsonBody, [:])
        XCTAssertFalse(view.info.hasUnread)
        XCTAssertEqual(view.info.lastReadAt, "2026-10-02T00:00:09.000Z")
        XCTAssertEqual(view.info.sessionId, "s1", "the rest of info is kept")
        XCTAssertEqual(counter.count, 1)
        await view.close()
    }

    // MARK: - Behavior 18: rows that do not decode, page size

    func testAnUndecodableSessionRowLeavesSessionNilAndUnknownPartsAreListed() async throws {
        let h = harness("undecodable")
        let documentId = try await session(h, "s1")
        try saveSession(h, in: documentId, status: "thinking", unreadable: true)
        try saveMessage(h, in: documentId, id: "m1", seq: 1)
        try savePart(h, in: documentId, id: "m1-p", messageId: "m1", seq: 1, kind: "hologram", text: nil)
        let view = try await open(h, "s1")
        XCTAssertNil(view.session, "a session row whose required column does not read does not decode")
        XCTAssertNil(view.status)
        XCTAssertEqual(synced(view).count, 1, "messages still load")
        XCTAssertEqual(synced(view).first?.parts.first?.content, .unknown(kind: "hologram"))
        await view.close()
    }

    func testAPageSizeOutsideTheRangeThrowsBeforeAnyRequest() async throws {
        let h = harness("page-size")
        for size in [0, 501] {
            await assertCode(.invalidArgument) { _ = try await self.open(h, "s1", pageSize: size) }
        }
        XCTAssertTrue(h.transport.calls.isEmpty)
    }

    // MARK: - Edge 33: the same session twice

    func testTheSameSessionOpenedTwiceSharesOneDocument() async throws {
        let h = harness("twice")
        let documentId = try await session(h, "s1")
        try saveMessage(h, in: documentId, id: "m1", seq: 1)
        let first = try await open(h, "s1")
        let second = try await open(h, "s1")
        XCTAssertEqual(synced(first).map(\.messageId), ["m1"])
        XCTAssertEqual(synced(second).map(\.messageId), ["m1"])
        await first.close()
        XCTAssertFalse(h.client.isDocumentOpen(documentId), "closing one closes the document for both")
        await second.close()
    }

    // MARK: - Edge 34: an open that fails after get

    func testAFailedDocumentOpenLeavesNoSubscriptionBehind() async throws {
        let h = harness("open-fails")
        h.script.on(.get, "/agent-sessions/s1", Self.info("s1", documentId: "never-created"))
        h.client.registerModels(AgentSessionModels.schemas)
        let before = AgentSessionModels.schemas.map { h.client.sharedModel($0.name)?.activeSubscriptionCount ?? -1 }
        do {
            _ = try await h.sessions.open(sessionId: "s1", options: OpenAgentSessionOptions(
                open: OpenDocumentOptions(waitForLoad: .network, enableNetworkSync: true, availabilityWait: 0)
            ))
            XCTFail("the document open should fail")
        } catch {
            XCTAssertFalse(error is HttpError, "the failure is the open's, after get: \(error)")
        }
        let after = AgentSessionModels.schemas.map { h.client.sharedModel($0.name)?.activeSubscriptionCount ?? -1 }
        XCTAssertEqual(after, before, "no subscription was left behind")
        XCTAssertFalse(h.client.isDocumentOpen("never-created"))
    }

    // MARK: - #4466: a call's artifact, view-local rules

    private func saveToolCall(
        _ h: Harness, in documentId: String, id: String, messageId: String, seq: Double,
        artifact: String? = nil, artifactBlobId: String? = nil
    ) throws {
        var values: [String: PrimitiveValue] = [
            "messageId": .string(messageId), "seq": .number(seq), "kind": .string("tool_call"),
            "state": .string("output-available"), "toolCallId": .string("call-\(id)"),
            "toolName": .string("chart"), "createdAt": .date(Self.created),
        ]
        if let artifact { values["artifact"] = .string(artifact) }
        if let artifactBlobId { values["artifactBlobId"] = .string(artifactBlobId) }
        try h.client.codegen.save(PrimitivePart.primitiveSchema, id: id, values: values, in: documentId)
    }

    /// No blob content is scripted: a read would go to the client's
    /// unreachable API and throw, so an answer proves none was made.
    func testArtifactAnswersTheInlineValueNullAndNilWithoutReadingABlob() async throws {
        let h = harness("artifact-inline")
        let documentId = try await session(h, "s1")
        try saveMessage(h, in: documentId, id: "m1", seq: 1, authorKind: "agent")
        try saveToolCall(h, in: documentId, id: "inline", messageId: "m1", seq: 1, artifact: #"{"rows":[1,2,3]}"#)
        try saveToolCall(h, in: documentId, id: "null", messageId: "m1", seq: 2, artifact: "null")
        try saveToolCall(h, in: documentId, id: "none", messageId: "m1", seq: 3)
        try saveToolCall(
            h, in: documentId, id: "empty-id", messageId: "m1", seq: 4, artifact: #"{"a":1}"#, artifactBlobId: ""
        )
        try savePart(h, in: documentId, id: "text", messageId: "m1", seq: 5)
        let view = try await open(h, "s1")
        try await eventually(description: "the five parts reach the window") {
            self.synced(view).first?.parts.count == 5
        }
        let parts = try XCTUnwrap(synced(view).first?.parts)
        func part(_ id: String) throws -> PrimitivePart { try XCTUnwrap(parts.first { $0.id == id }) }

        let inline = try await view.artifact(of: part("inline"))
        XCTAssertEqual(inline, ["rows": [1, 2, 3]])
        let null = try await view.artifact(of: part("null"))
        XCTAssertEqual(null, .null, "a stored JSON null answers .null, not nil")
        let none = try await view.artifact(of: part("none"))
        XCTAssertNil(none)
        let emptyId = try await view.artifact(of: part("empty-id"))
        XCTAssertEqual(emptyId, ["a": 1], "an empty blob id is no blob id")
        let text = try await view.artifact(of: part("text"))
        XCTAssertNil(text, "a part that is no tool call has no artifact")
        XCTAssertEqual(h.transport.calls.map(\.path), ["/agent-sessions/s1"])
        await view.close()
    }

    func testArtifactOnAClosedViewThrowsInvalidArgumentWithoutReading() async throws {
        let h = harness("artifact-closed")
        let documentId = try await session(h, "s1")
        try saveMessage(h, in: documentId, id: "m1", seq: 1, authorKind: "agent")
        try saveToolCall(h, in: documentId, id: "blob", messageId: "m1", seq: 1, artifactBlobId: "blob-1")
        try saveToolCall(h, in: documentId, id: "inline", messageId: "m1", seq: 2, artifact: #"{"a":1}"#)
        let view = try await open(h, "s1")
        try await eventually(description: "the parts reach the window") { self.synced(view).first?.parts.count == 2 }
        let parts = try XCTUnwrap(synced(view).first?.parts)
        await view.close()
        for part in parts {
            await assertCode(.invalidArgument) { _ = try await view.artifact(of: part) }
        }
        XCTAssertEqual(h.transport.calls.map(\.path), ["/agent-sessions/s1"])
    }
}

/// A one-shot gate an async test opens to let a scripted answer through.
private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
