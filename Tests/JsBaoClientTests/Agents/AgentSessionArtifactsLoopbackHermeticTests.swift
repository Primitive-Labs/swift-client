import XCTest
@testable import JsBaoClient

/// `view.artifact(of:)` downloads a blob-stored artifact only when asked
/// (#4466, plan behavior 7, the download half).
///
/// A real `JsBaoClient` runs against `LoopbackAPIServer`, which records every
/// request on the client's real `BlobManager` download route and refuses each
/// download with a 500; it answers no blob content. The session document is
/// local-only, its rows saved with `codegen.save`.
final class AgentSessionArtifactsLoopbackHermeticTests: XCTestCase {
    private static let localOpen = OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
    private static let created = "2026-10-13T00:00:00.000Z"

    private static func info(_ sessionId: String, documentId: String) -> String {
        #"""
        {"sessionId":"\#(sessionId)","agentKey":"helper","documentId":"\#(documentId)","ownerUserId":"u1",
         "createdAt":"2026-10-13T00:00:00.000Z","title":null,"scope":null,"lastActivityAt":null,
         "members":{"viewers":[],"participants":[]},"role":"owner","status":"idle","turn":null}
        """#
    }

    private static func isDownload(_ request: LoopbackAPIServer.Request) -> Bool {
        request.apiPathOnly.contains("/blobs/") && request.apiPathOnly.hasSuffix("/download")
    }

    /// One agent message at `seq` with one tool-call part naming `blobId`.
    private func seedCall(_ client: JsBaoClient, in documentId: String, seq: Int, blobId: String) throws {
        let messageId = "m\(seq)"
        try client.codegen.save(PrimitiveMessage.primitiveSchema, id: messageId, values: [
            "seq": .number(Double(seq)), "authorKind": .string("agent"), "createdAt": .date(Self.created),
        ], in: documentId)
        try client.codegen.save(PrimitivePart.primitiveSchema, id: "p\(seq)", values: [
            "messageId": .string(messageId), "seq": .number(1), "kind": .string("tool_call"),
            "state": .string("output-available"), "toolCallId": .string("call-\(seq)"),
            "toolName": .string("chart"), "artifactBlobId": .string(blobId), "createdAt": .date(Self.created),
        ], in: documentId)
    }

    func testOpenARefreshAndLoadOlderDownloadNothingAndArtifactDownloadsOnce() async throws {
        let sessionId = "s-artifacts"
        let documentBox = LockedBox<String?>(nil)
        let server = try LoopbackAPIServer { request in
            if Self.isDownload(request) { return .status(500, "downloads are refused in this test") }
            if request.apiPathOnly == "/agent-sessions/\(sessionId)", let documentId = documentBox.value {
                return .json(Self.info(sessionId, documentId: documentId))
            }
            return .status(404, "not here")
        }
        let baseUrl = try server.start()
        defer { server.stop() }
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: baseUrl, wsUrl: "ws://127.0.0.1:1", appId: "agent-artifacts-loopback",
            token: "test-token", offline: false, logLevel: .none,
            storageConfig: .memory, autoNetwork: false
        ))
        client.documentManager.createRemoteDocument = { _ in
            throw JsBaoError(code: .unavailable, message: "no server in this test")
        }
        let created = try await client.createDocument(options: CreateDocumentOptions(localOnly: true))
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        documentBox.value = documentId
        client.registerModels(AgentSessionModels.schemas)
        _ = try await client.documents.open(documentId, options: Self.localOpen)
        for seq in 1...4 { try seedCall(client, in: documentId, seq: seq, blobId: "blob-\(seq)") }
        let downloads = { server.requests.filter(Self.isDownload).map(\.apiPathOnly) }

        let view = try await client.agents.sessions.open(
            sessionId: sessionId, options: OpenAgentSessionOptions(pageSize: 2, open: Self.localOpen)
        )
        XCTAssertEqual(view.toolCalls.map(\.id), ["p3", "p4"])
        XCTAssertTrue(view.hasOlder)

        // A row write refreshes the view.
        try seedCall(client, in: documentId, seq: 5, blobId: "blob-5")
        try await eventually(description: "the new call reaches the window") {
            view.toolCalls.map(\.id) == ["p3", "p4", "p5"]
        }
        let older = try await view.loadOlder()
        XCTAssertEqual(older, AgentSessionLoadOlderResult(loaded: 2, hasOlder: false))
        XCTAssertEqual(view.toolCalls.compactMap(\.artifactBlobId), (1...5).map { "blob-\($0)" })
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(downloads(), [], "nothing was downloaded before artifact(of:)")

        let part = try XCTUnwrap(view.toolCalls.first { $0.id == "p2" })
        do {
            _ = try await view.artifact(of: part)
            XCTFail("the refused download throws")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 500)
        }
        XCTAssertEqual(downloads(), ["/documents/\(documentId)/blobs/blob-2/download"])
        await view.close()
        await client.destroy()
    }
}
