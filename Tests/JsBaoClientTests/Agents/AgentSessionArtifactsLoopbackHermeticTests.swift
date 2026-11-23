import XCTest
@testable import JsBaoClient

/// `view.artifact(of:)` downloads a blob-stored artifact only when asked
/// (#4466, plan behavior 7, the download half; #4884: through the session's
/// attachment route).
///
/// A real `JsBaoClient` runs against `LoopbackAPIServer`, which records every
/// request on the client's real `BlobManager` download route and refuses each
/// download with a 500; it answers no blob content. The session's db3 is a
/// real binding and lifecycle (`SessionDb3`), its rows written as the room's.
final class AgentSessionArtifactsLoopbackHermeticTests: XCTestCase {
    private static func isDownload(_ request: LoopbackAPIServer.Request) -> Bool {
        request.apiPathOnly.contains("/attachments/") && request.apiPathOnly.hasSuffix("/download")
    }

    /// One agent message at `seq` with one call `p<seq>` naming `blobId`.
    private func seedCall(_ db3: SessionDb3, seq: Int, blobId: String) throws {
        let messageId = "m\(seq)"
        try db3.write([
            ("Message", SessionRows.message(messageId, seq: Double(seq), turnId: "t\(seq)", authorKind: "agent")),
            ("ToolCall", SessionRows.call(
                "p\(seq)", messageId: messageId, seq: 1, turnId: "t\(seq)", toolName: "chart",
                state: "output-available", artifactBlobId: blobId
            )),
        ])
    }

    func testOpenARefreshAndLoadOlderDownloadNothingAndArtifactDownloadsOnce() async throws {
        let sessionId = "s-artifacts"
        let server = try LoopbackAPIServer { request in
            if Self.isDownload(request) { return .status(500, "downloads are refused in this test") }
            if request.apiPathOnly == "/agent-sessions/\(sessionId)" { return .json(agentSessionInfoJSON(sessionId)) }
            return .status(404, "not here")
        }
        let baseUrl = try server.start()
        defer { server.stop() }
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: baseUrl, wsUrl: "ws://127.0.0.1:1", appId: "agent-artifacts-loopback",
            token: "test-token", offline: false, logLevel: .none,
            storageConfig: .memory, autoNetwork: false
        ))
        let db3 = try await SessionDb3.make(id: sessionId)
        defer { db3.cleanup() }
        for seq in 1...4 { try seedCall(db3, seq: seq, blobId: "blob-\(seq)") }
        let downloads = { server.requests.filter(Self.isDownload).map(\.apiPathOnly) }

        let view = try await client.agents.sessions.open(
            sessionId: sessionId, options: OpenAgentSessionOptions(pageSize: 2), db3: db3
        )
        XCTAssertEqual(view.toolCalls.map(\.id), ["p3", "p4"])
        XCTAssertTrue(view.hasOlder)

        // A row write refreshes the view.
        try seedCall(db3, seq: 5, blobId: "blob-5")
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
        XCTAssertEqual(downloads(), ["/agent-sessions/\(sessionId)/attachments/blob-2/download"])
        await view.close()
        await client.destroy()
    }
}
