import XCTest
@testable import JsBaoClient

/// The Swift session surface names a session by its id alone and matches the
/// JS one (#4588 plan behaviors 24 and 47's structural half; #4884 behavior 4
/// and edge E11): the session answers decode with no document id and carry
/// none; the document-shaped members are gone; every other public member
/// keeps or takes its db3-era signature; the session code makes no call on the
/// public `client.documents`, opens no document and registers no model; the
/// attachments facade has the JS interface's members; and the upload queue's
/// selection and both timer predicates read one runnability rule.
final class AgentSessionSurfaceParityHermeticTests: XCTestCase {
    /// `get`'s answer from the phase-2 server: no `documentId`.
    private static let info = #"""
    {"sessionId":"s1","agentKey":"helper","ownerUserId":"u1",
     "createdAt":"2026-10-01T00:00:00.000Z","title":"T","scope":null,"lastActivityAt":null,
     "members":{"viewers":[],"participants":[]},"role":"owner","status":"idle","turn":null}
    """#
    private static let item = #"""
    {"sessionId":"s1","agentKey":"helper","scope":null,"ownerUserId":"u1",
     "role":"owner","title":"T","lastActivityAt":"2026-10-02T00:00:00.000Z","createdAt":null,"status":"thinking"}
    """#

    // MARK: - Behavior 4: answers by id alone

    func testTheSessionAnswersDecodeWithNoDocumentIdAndCarryNone() throws {
        let info = try JSONCoding.decodeData(AgentSessionInfo.self, from: Data(Self.info.utf8))
        XCTAssertEqual(info.sessionId, "s1")
        XCTAssertEqual(info.status, .idle)
        let item = try JSONCoding.decodeData(AgentSessionListItem.self, from: Data(Self.item.utf8))
        XCTAssertEqual(item.status, .thinking)
        let encoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONCoding.encodeData(item)) as? [String: Any])
        XCTAssertNil(encoded["documentId"], "the list item encodes no documentId")
        XCTAssertEqual(try JSONCoding.decodeData(AgentSessionListItem.self, from: JSONCoding.encodeData(item)), item)
        let deleted = try JSONCoding.decodeData(
            AgentSessionDeleteResult.self, from: Data(#"{"deleted":true,"sessionId":"s1"}"#.utf8)
        )
        XCTAssertEqual(deleted.sessionId, "s1")
        XCTAssertTrue(deleted.deleted)
        for value in [Mirror(reflecting: info), Mirror(reflecting: item), Mirror(reflecting: deleted)] {
            let labels = value.children.compactMap(\.label)
            XCTAssertFalse(labels.contains { $0.lowercased().contains("documentid") }, "\(value.subjectType): \(labels)")
        }
    }

    func testTheDocumentShapedMembersAreGone() throws {
        let types = try ClientSourceText.code("Types/AgentSessionsTypes.swift")
        let api = try ClientSourceText.code("API/AgentSessionsAPI.swift")
        let view = try ClientSourceText.code("Agents/AgentSessionView.swift")
        let models = try ClientSourceText.code("Agents/AgentSessionModels.generated.swift")
        let errors = try ClientSourceText.code("Types/Errors.swift")
        XCTAssertFalse(types.contains("documentId"), "no session type names a document id")
        XCTAssertFalse(types.contains("struct AgentSessionStorage"))
        XCTAssertFalse(api.contains("inspect"), "client.agents.sessions has no inspect")
        XCTAssertFalse(api.contains("AgentSessionInspectAPI"))
        XCTAssertFalse(view.contains("documentId"), "the view names no document id")
        XCTAssertFalse(view.contains("OpenDocumentOptions"), "OpenAgentSessionOptions has no open")
        XCTAssertFalse(models.contains("schemas"), "AgentSessionModels exports no schemas")
        XCTAssertFalse(errors.contains("agentSessionModelNameTaken"))
        XCTAssertFalse(errors.contains("AGENT_SESSION_MODEL_NAME_TAKEN"))
        let sources = ClientSourceText.packageRoot.appendingPathComponent("Sources/JsBaoClient")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: sources.path))
        for case let file as String in enumerator where file.hasSuffix(".swift") {
            let code = try ClientSourceText.code(file)
            XCTAssertFalse(code.contains("PrimitiveSession"), "\(file) names a format-1 session model")
            XCTAssertFalse(code.contains("PrimitivePart"), "\(file) names a format-1 session model")
        }
    }

    func testTheSessionsApiKeepsEveryMethodButInspect() {
        let sessions = AgentSessionsAPI(transport: RecordingTransport(json: "{}"))
        let _: (ListAgentSessionsOptions?) async throws -> PaginatedResult<AgentSessionListItem> = sessions.list
        let _: (String) async throws -> AgentSessionInfo = sessions.get
        let _: (String, String) async throws -> AgentSessionRenameResult = sessions.rename
        let _: (String) async throws -> AgentSessionDeleteResult = sessions.delete
        let _: (String, String, AgentSessionMemberRole) async throws -> AgentSessionMembersResult = sessions.addMember
        let _: (String, String) async throws -> AgentSessionMembersResult = sessions.removeMember
        let _: (String, AgentSessionSendBody) async throws -> AgentSessionSendResult = sessions.send
        let _: (String, String, AgentCallAnswer) async throws -> AgentCallAnswerResult = sessions.answer
        let _: (String, String) async throws -> AgentSessionCancelResult = sessions.cancel
        let _: (String) async throws -> AgentSessionReadResult = sessions.markRead
        let _: (String, AgentSessionEvent) async throws -> AgentSessionEventResult = sessions.recordEvent
        let _: (String, String, AgentSessionAttachmentUpload) async throws -> AgentSessionAttachmentUploadResult =
            sessions.uploadAttachment
        let _: (String, String, BlobDisposition?) async throws -> Data = sessions.downloadAttachment
        let _: (String, OpenAgentSessionOptions) async throws -> AgentSessionView = sessions.open
        XCTAssertEqual(Mirror(reflecting: sessions).children.compactMap(\.label).filter { $0 == "inspect" }, [])
    }

    func testOpenOptionsArePageSizeAndMarkRead() {
        let options = OpenAgentSessionOptions(pageSize: 20, markRead: .whileOpen)
        XCTAssertEqual(options.pageSize, 20)
        XCTAssertEqual(options.markRead, .whileOpen)
        XCTAssertEqual(Mirror(reflecting: options).children.compactMap(\.label).sorted(), ["markRead", "pageSize"])
    }

    /// Compiles only while every public member has its db3-era type.
    private func signatures(
        _ info: AgentSessionInfo, _ item: AgentSessionListItem, _ view: AgentSessionView,
        _ synced: AgentSessionSyncedMessage, _ part: AgentSessionViewPart, _ presentation: AgentPresentation,
        _ answered: AgentCallAnswerResult
    ) {
        let _: (String, String, String, String) = (info.sessionId, info.agentKey, info.ownerUserId, info.createdAt)
        let _: (String?, String?, String?, Bool, String?) =
            (info.title, info.scope, info.lastActivityAt, info.hasUnread, info.lastReadAt)
        let _: (AgentSessionMembers, AgentSessionRole, AgentSessionStatus, AgentSessionTurnSummary?) =
            (info.members, info.role, info.status, info.turn)
        let _: (JSONValue?, JSONValue?, JSONValue?) = (info.object, info.turnContexts, info.lastTurn)
        let _: (String, String, String?, String, AgentSessionRole, String?) =
            (item.sessionId, item.agentKey, item.scope, item.ownerUserId, item.role, item.title)
        let _: (String, String?, Bool, String?, AgentSessionStatus?) =
            (item.lastActivityAt, item.createdAt, item.hasUnread, item.lastReadAt, item.status)
        let _: AgentSessionToolCallState = answered.state
        let _: (AgentSessionInfo, String, AgentSessionRecord?, AgentSessionStatus?, String?) =
            (view.info, view.sessionId, view.session, view.status, view.activeTurnId)
        let _: ([PrimitiveQueueEntry], [AgentSessionMemberRecord], Db3GoneEvent?) = (view.queue, view.members, view.gone)
        let _: ([AgentSessionViewMessage], Bool, [String], AgentSessionAttachments) =
            (view.messages, view.hasOlder, view.runningClientToolCalls, view.attachments)
        let _: (String, Double, String?, AgentSessionMessageRecord) = (synced.messageId, synced.seq, synced.clientMessageId, synced.message)
        let _: ([AgentSessionViewPart], [AgentSessionStepRecord], AgentSessionTurnRecord?, AgentSessionSyncedMessage.State) =
            (synced.parts, synced.steps, synced.turn, synced.state)
        let _: (String, String, Double) = (part.id, part.messageId, part.seq)
        switch part {
        case let .part(record): let _: AgentSessionPartRecord = record
        case let .toolCall(record): let _: AgentSessionToolCallRecord = record
        }
        let _: (String, JSONValue, AgentSessionToolCallRecord) = (presentation.name, presentation.input, presentation.part)
        let _: (Int) -> AgentSessionToolCallRecord? = presentation.call
        let _: (@escaping @Sendable () -> Void) -> @Sendable () -> Void = view.onChange
        let _: (String, [AgentSessionFileRef], String?, JSONValue?, String?, String?) async throws -> AgentSessionSendResult =
            view.send
        let _: (String) async throws -> AgentSessionSendResult = view.retry
        let _: (String) -> Bool = view.dismiss
        let _: () async throws -> AgentSessionLoadOlderResult = view.loadOlder
        let _: (String, AgentCallAnswer) async throws -> AgentCallAnswerResult = view.answer
        let _: (AgentSessionToolCallRecord) async throws -> JSONValue? = view.artifact
        let _: (AgentSessionSyncedMessage, [String]) -> [AgentPresentation] = view.presentations
        let _: (AgentSessionEvent) async throws -> AgentSessionEventResult = view.recordEvent
        let _: (String?) async throws -> AgentSessionCancelResult = view.cancel
        let _: () async throws -> AgentSessionReadResult = view.markRead
        let _: ([String: AgentClientToolHandler], HandleClientToolsOptions) throws -> @Sendable () -> Void = view.handleClientTools
        let _: () async throws -> AgentSessionInfo = view.refreshInfo
        let _: () async -> Void = view.close
    }

    func testTheSignatureFixtureCompiles() {
        _ = signatures
    }

    // MARK: - Behavior 4: no document calls

    func testTheSessionCodeMakesNoDocumentCallAndRegistersNoModel() throws {
        let agents = ClientSourceText.packageRoot.appendingPathComponent("Sources/JsBaoClient/Agents")
        let files = try FileManager.default.contentsOfDirectory(atPath: agents.path).filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertTrue(files.contains("AgentSessionView.swift"))
        XCTAssertTrue(files.contains("AgentSessionAttachments.swift"))
        for file in files.map({ "Agents/\($0)" }) + ["API/AgentSessionsAPI.swift"] {
            let code = try ClientSourceText.code(file)
            XCTAssertFalse(code.contains("documents."), "\(file) calls the public documents API")
            XCTAssertFalse(code.contains("openDocument("), "\(file) opens a document")
            XCTAssertFalse(code.contains("closeDocument("), "\(file) closes a document")
            XCTAssertFalse(code.contains("registerModels("), "\(file) registers a model")
        }
        let view = try ClientSourceText.code("Agents/AgentSessionView.swift")
        XCTAssertTrue(view.contains("db3.subscribe("), "the view subscribes to the session's db3")
    }

    // MARK: - Edge E11: the attachments facade

    func testTheAttachmentsFacadeHasTheJsInterfacesMembers() throws {
        guard ClientSourceText.isMonorepoCheckout else {
            throw XCTSkip("the JS client is not in the published mirror")
        }
        let js = ClientSourceText.stripComments(try ClientSourceText.repoFile("src/client/agents/sessionAttachments.ts"))
        let interface = try ClientSourceText.slice(js, from: "export interface AgentSessionAttachments {", to: "\n}")
        let jsMembers = Set(interface.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let paren = trimmed.firstIndex(of: "("), trimmed.first?.isLetter == true else { return nil }
            return String(trimmed[..<paren])
        })
        let swift = try ClientSourceText.slice(
            try ClientSourceText.code("Agents/AgentSessionAttachments.swift"),
            from: "public final class AgentSessionAttachments", to: "private func requireOpen"
        )
        let regex = try NSRegularExpression(pattern: #"public func (\w+)"#)
        let swiftMembers = Set(regex.matches(in: swift, range: NSRange(swift.startIndex..., in: swift)).compactMap {
            Range($0.range(at: 1), in: swift).map { String(swift[$0]) }
        })
        XCTAssertEqual(jsMembers, ["upload", "uploads", "pause", "resume", "cancel", "waitUntilUploaded", "read"])
        XCTAssertEqual(swiftMembers, jsMembers)
    }

    // MARK: - #4588 behavior 47: one runnability rule

    func testSelectionAndBothTimerPredicatesReadTheOneRunnableRule() throws {
        let manager = try ClientSourceText.code("Internal/BlobManager.swift")
        XCTAssertEqual(manager.components(separatedBy: "func isRunnable(").count - 1, 1, "one rule")
        let regions = [
            try ClientSourceText.slice(manager, from: "func scheduleQueueProcessing(", to: "private nonisolated func makeQueueTimer"),
            try ClientSourceText.slice(manager, from: "private func nextQueueDelayMs", to: "private func rearmQueueTimer"),
            try ClientSourceText.slice(manager, from: "private func selectDueTasks", to: "private nonisolated func runUploadTask"),
        ]
        for region in regions {
            XCTAssertTrue(region.contains("isRunnable("), String(region.prefix(60)))
            XCTAssertFalse(region.contains("!$0.paused && !$0.uploading"), "no second rule")
            XCTAssertFalse(region.contains("!task.paused && !task.uploading"), "no second rule")
        }
    }
}
