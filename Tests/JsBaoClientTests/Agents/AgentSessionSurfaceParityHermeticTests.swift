import XCTest
@testable import JsBaoClient

/// The Swift session surface needs no document ID and matches the JS one
/// (#4588, plan behaviors 23, 24 and 47's structural half): the three
/// `documentId` members are deprecated toward `sessionId` and still answer;
/// every other public member keeps its signature; the session code makes no
/// call on the public `client.documents`; the attachments facade has the JS
/// interface's members; and the upload queue's selection and both timer
/// predicates read one runnability rule.
final class AgentSessionSurfaceParityHermeticTests: XCTestCase {
    private static let info = #"""
    {"sessionId":"s1","agentKey":"helper","documentId":"d1","ownerUserId":"u1",
     "createdAt":"2026-10-01T00:00:00.000Z","title":"T","scope":null,"lastActivityAt":null,
     "members":{"viewers":[],"participants":[]},"role":"owner","status":"idle","turn":null}
    """#
    private static let item = #"""
    {"sessionId":"s1","agentKey":"helper","scope":null,"documentId":"d1","ownerUserId":"u1",
     "role":"owner","title":"T","lastActivityAt":"2026-10-02T00:00:00.000Z","createdAt":null}
    """#

    /// The deprecation message on `declaration` inside `scope`, or nil when
    /// it carries none.
    private func deprecation(of declaration: String, in scope: String) -> String? {
        let pattern = #"@available\(\*, deprecated, message: "([^"]*)"\)\s*"# + NSRegularExpression.escapedPattern(for: declaration)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: scope, range: NSRange(scope.startIndex..., in: scope)),
              let range = Range(match.range(at: 1), in: scope)
        else { return nil }
        return String(scope[range])
    }

    // MARK: - Behavior 23: the three deprecations

    func testTheThreeDocumentIdMembersAreDeprecatedTowardSessionIdAndTheDeleteResultIsNot() throws {
        let types = try ClientSourceText.code("Types/AgentSessionsTypes.swift")
        let info = try ClientSourceText.slice(types, from: "public struct AgentSessionInfo", to: "public struct AgentSessionListItem")
        let item = try ClientSourceText.slice(types, from: "public struct AgentSessionListItem", to: "public enum AgentSessionChange")
        let deleted = try ClientSourceText.slice(
            types, from: "public struct AgentSessionDeleteResult", to: "public struct AgentSessionMembersResult"
        )
        let view = try ClientSourceText.slice(
            try ClientSourceText.code("Agents/AgentSessionView.swift"),
            from: "public final class AgentSessionView", to: "public var session: PrimitiveSession?"
        )
        for (name, scope) in [("AgentSessionInfo", info), ("AgentSessionListItem", item), ("AgentSessionView", view)] {
            let message = try XCTUnwrap(
                deprecation(of: "public var documentId: String", in: scope), "\(name).documentId is deprecated"
            )
            XCTAssertTrue(message.contains("sessionId"), "\(name): \(message)")
            XCTAssertTrue(message.contains("inspect.storage"), "\(name): \(message)")
        }
        XCTAssertTrue(deleted.contains("public let documentId: String"))
        XCTAssertFalse(deleted.contains("deprecated"), "the delete result's documentId is not deprecated")
    }

    @available(*, deprecated, message: "reads the deprecated documentId members on purpose")
    private func deprecatedDocumentIds(
        _ info: AgentSessionInfo, _ item: AgentSessionListItem, _ view: AgentSessionView
    ) -> [String] {
        [info.documentId, item.documentId, view.documentId]
    }

    @available(*, deprecated, message: "reads the deprecated documentId members on purpose")
    func testTheDeprecatedMembersStillAnswerTheBackingDocument() async throws {
        let info = try JSONCoding.decodeData(AgentSessionInfo.self, from: Data(Self.info.utf8))
        let item = try JSONCoding.decodeData(AgentSessionListItem.self, from: Data(Self.item.utf8))
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "agent-session-parity",
            token: "test-token", offline: false, logLevel: .none, storageConfig: .memory, autoNetwork: false
        ))
        let view = AgentSessionView(api: client.agents.sessions, client: client, info: info, pageSize: 50)
        XCTAssertEqual(deprecatedDocumentIds(info, item, view), ["d1", "d1", "d1"])
        let encoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONCoding.encodeData(item)) as? [String: Any])
        XCTAssertEqual(encoded["documentId"] as? String, "d1", "the list item still encodes its documentId")
        XCTAssertEqual(try JSONCoding.decodeData(AgentSessionListItem.self, from: JSONCoding.encodeData(item)), item)
        await view.close()
        await client.destroy()
    }

    /// Compiles only while every other public member keeps its type.
    private func signatures(_ info: AgentSessionInfo, _ item: AgentSessionListItem, _ view: AgentSessionView) {
        let _: (String, String, String, String) = (info.sessionId, info.agentKey, info.ownerUserId, info.createdAt)
        let _: (String?, String?, String?, Bool, String?) =
            (info.title, info.scope, info.lastActivityAt, info.hasUnread, info.lastReadAt)
        let _: (AgentSessionMembers, AgentSessionRole, PrimitiveSessionStatus, AgentSessionTurnSummary?) =
            (info.members, info.role, info.status, info.turn)
        let _: (JSONValue?, JSONValue?, JSONValue?) = (info.object, info.turnContexts, info.lastTurn)
        let _: (String, String, String?, String, AgentSessionRole, String?) =
            (item.sessionId, item.agentKey, item.scope, item.ownerUserId, item.role, item.title)
        let _: (String, String?, Bool, String?, PrimitiveSessionStatus?) =
            (item.lastActivityAt, item.createdAt, item.hasUnread, item.lastReadAt, item.status)
        let _: (AgentSessionInfo, String, PrimitiveSession?, PrimitiveSessionStatus?, String?) =
            (view.info, view.sessionId, view.session, view.status, view.activeTurnId)
        let _: ([PrimitiveQueueEntry], [AgentSessionViewMessage], Bool, [String], AgentSessionAttachments) =
            (view.queue, view.messages, view.hasOlder, view.runningClientToolCalls, view.attachments)
        let _: (@escaping @Sendable () -> Void) -> @Sendable () -> Void = view.onChange
        let _: (String, [AgentSessionFileRef], String?, JSONValue?, String?, String?) async throws -> AgentSessionSendResult =
            view.send
        let _: (String) async throws -> AgentSessionSendResult = view.retry
        let _: (String) -> Bool = view.dismiss
        let _: () async throws -> AgentSessionLoadOlderResult = view.loadOlder
        let _: (String, AgentCallAnswer) async throws -> AgentCallAnswerResult = view.answer
        let _: (PrimitivePart) async throws -> JSONValue? = view.artifact
        let _: (PrimitiveMessage, [String]) -> [AgentPresentation] = view.presentations
        let _: (AgentSessionEvent) async throws -> AgentSessionEventResult = view.recordEvent
        let _: (String?) async throws -> AgentSessionCancelResult = view.cancel
        let _: () async throws -> AgentSessionReadResult = view.markRead
        let _: () async throws -> AgentSessionInfo = view.refreshInfo
        let _: () async -> Void = view.close
    }

    func testTheSignatureFixtureCompiles() {
        _ = signatures
    }

    // MARK: - Behavior 24: no public document calls

    func testTheSessionCodeMakesNoCallOnThePublicDocumentsAPI() throws {
        let agents = ClientSourceText.packageRoot.appendingPathComponent("Sources/JsBaoClient/Agents")
        let files = try FileManager.default.contentsOfDirectory(atPath: agents.path).filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertTrue(files.contains("AgentSessionView.swift"))
        XCTAssertTrue(files.contains("AgentSessionAttachments.swift"))
        for file in files.map({ "Agents/\($0)" }) + ["API/AgentSessionsAPI.swift"] {
            let code = try ClientSourceText.code(file)
            XCTAssertFalse(code.contains("documents."), "\(file) calls the public documents API")
        }
        let view = try ClientSourceText.code("Agents/AgentSessionView.swift")
        XCTAssertTrue(view.contains("client.openDocument("), "the view opens through the client")
        XCTAssertTrue(view.contains("client.closeDocument("), "the view closes through the client")
    }

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

    // MARK: - Behavior 47: one runnability rule

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
