import XCTest
@testable import JsBaoClient

/// `view.artifact(of:)` reads a blob-stored artifact once for every caller
/// asking while that read is in flight (#4588, plan behavior 15, edge 39;
/// #4884: through the session's attachment route, the calls `ToolCall` rows
/// of the session's db3): each caller decodes its own value, a refused read
/// refuses every sharer, and a settled read is forgotten. The loopback holds
/// each download until the test answers it, so "concurrent" is a fact of the
/// test, not a race.
final class AgentSessionArtifactDedupeHermeticTests: XCTestCase {
    private static let created = "2026-10-20T00:00:00.000Z"

    private static func isDownload(_ request: LoopbackAPIServer.Request) -> Bool {
        request.method == "GET" && request.apiPathOnly.contains("/attachments/") && request.apiPathOnly.hasSuffix("/download")
    }

    /// One agent message with one call per `(callId, blobId, inline)`, each
    /// `blobId` (when given) naming the artifact's blob, and a text part.
    private func seed(_ db3: SessionDb3, _ calls: [(String, String?, String?)]) throws {
        var rows: [(model: String, row: [String: JSONValue])] = [
            ("Message", SessionRows.message("m1", seq: 1, turnId: "t1", authorKind: "agent")),
        ]
        for (index, (callId, blobId, inline)) in calls.enumerated() {
            rows.append(("ToolCall", SessionRows.call(
                callId, messageId: "m1", seq: Double(index + 1), turnId: "t1", toolName: "chart",
                state: "output-available", artifact: inline, artifactBlobId: blobId
            )))
        }
        rows.append(("Part", SessionRows.text("p-text", messageId: "m1", seq: 99, text: "hi")))
        try db3.write(rows)
    }

    func testConcurrentReadsOfOneArtifactShareOneDownloadAndEachDecodesItsOwnValue() async throws {
        let server = try SessionUploadServer()
        defer { server.stop() }
        server.hold(Self.isDownload)
        let client = makeSessionUploadClient(server)
        defer { Task { await client.destroy() } }
        let (view, db3) = try await openLocalSessionView(client, server)
        defer { db3.cleanup() }
        try seed(db3, [
            ("p1", "blob-1", nil), ("p2", "blob-2", nil), ("p3", "blob-shared", nil), ("p4", "blob-shared", nil),
            ("p5", "blob-text", nil), ("p-inline", nil, #"{"rows":3}"#),
        ])
        try await eventually(timeout: 5, description: "the parts reach the window") { view.toolCalls.count == 6 }
        let parts = Dictionary(uniqueKeysWithValues: view.toolCalls.map { ($0.id, $0) })
        let p1 = try XCTUnwrap(parts["p1"]), p2 = try XCTUnwrap(parts["p2"]), p3 = try XCTUnwrap(parts["p3"])
        let p4 = try XCTUnwrap(parts["p4"]), p5 = try XCTUnwrap(parts["p5"]), pInline = try XCTUnwrap(parts["p-inline"])
        let downloads = { server.requests.filter(Self.isDownload).map(\.apiPathOnly) }

        // Two callers, one download.
        let first = Task { try await view.artifact(of: p1) }
        let second = Task { try await view.artifact(of: p1) }
        try await eventually(timeout: 5, description: "the download is held") { !server.heldRequests.isEmpty }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(downloads(), ["/agent-sessions/s1/attachments/blob-1/download"], "one download for both")
        server.release(.json(#"{"series":[1,2,3]}"#))
        let a = try await within(5, "the first caller") { try await first.value }
        let b = try await within(5, "the second caller") { try await second.value }
        XCTAssertEqual(a, .object(["series": .array([.number(1), .number(2), .number(3)])]))
        XCTAssertEqual(a, b)

        // A refused download refuses every sharer, and is not kept.
        let refusedA = Task { try await view.artifact(of: p2) }
        let refusedB = Task { try await view.artifact(of: p2) }
        try await eventually(timeout: 5, description: "the second download is held") { !server.heldRequests.isEmpty }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(downloads().filter { $0.contains("blob-2") }.count, 1)
        server.release(.status(500, "refused"))
        for refused in [refusedA, refusedB] {
            let error = await thrown { _ = try await within(5, "a refused caller") { try await refused.value } }
            XCTAssertEqual((error as? HttpError)?.status, 500)
        }
        let again = Task { try await view.artifact(of: p2) }
        try await eventually(timeout: 5, description: "a later call reads again") {
            downloads().filter { $0.contains("blob-2") }.count == 2
        }
        server.release(.json(#"{"ok":true}"#))
        let afterRefusal = try await within(5, "the later call") { try await again.value }
        XCTAssertEqual(afterRefusal, .object(["ok": .bool(true)]))

        // Two parts naming one blob share its read.
        let sharedA = Task { try await view.artifact(of: p3) }
        let sharedB = Task { try await view.artifact(of: p4) }
        try await eventually(timeout: 5, description: "the shared download is held") { !server.heldRequests.isEmpty }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(downloads().filter { $0.contains("blob-shared") }.count, 1)
        server.release(.json("[1]"))
        let sharedValueA = try await within(5, "p3") { try await sharedA.value }
        let sharedValueB = try await within(5, "p4") { try await sharedB.value }
        XCTAssertEqual(sharedValueA, .array([.number(1)]))
        XCTAssertEqual(sharedValueB, sharedValueA)

        // Edge 39: a blob that is not JSON throws DecodingError to each caller.
        let textA = Task { try await view.artifact(of: p5) }
        let textB = Task { try await view.artifact(of: p5) }
        try await eventually(timeout: 5, description: "the text download is held") { !server.heldRequests.isEmpty }
        try await Task.sleep(nanoseconds: 200_000_000)
        server.release(LoopbackAPIServer.Response(status: 200, body: "not json", headers: ["Content-Type": "text/plain"]))
        for caller in [textA, textB] {
            let error = await thrown { _ = try await within(5, "a text caller") { try await caller.value } }
            XCTAssertTrue(error is DecodingError, "\(String(describing: error))")
        }
        XCTAssertEqual(downloads().filter { $0.contains("blob-text") }.count, 1)

        // An inline artifact reads nothing.
        let before = downloads().count
        let inline = try await view.artifact(of: pInline)
        XCTAssertEqual(inline, .object(["rows": .number(3)]))
        XCTAssertEqual(downloads().count, before)
        XCTAssertNil(view.toolCall("p-text"), "a text part is no call")

        // A closed view throws and reads nothing.
        await view.close()
        let closed = await thrown { _ = try await view.artifact(of: p1) }
        XCTAssertEqual((closed as? JsBaoError)?.code, .invalidArgument)
        XCTAssertEqual(downloads().count, before)
    }
}
