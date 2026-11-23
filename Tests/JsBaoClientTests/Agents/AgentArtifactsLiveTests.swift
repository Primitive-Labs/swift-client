import Foundation
import XCTest
@testable import JsBaoClient

/// `view.artifact(of:)` on live Swift clients over real blobs (#4466, plan
/// behavior 8; edge cases 11 and 15; #4884 behavior 14). The owner uploads
/// blobs through the session's attachment route, and calls naming them are
/// written into the session's db3 through the session object's binding (the
/// local probe: only the session writes its db3); a fresh reader client (an
/// empty blob cache) reads them through its view, through the session's
/// attachment route, never a document's.
final class AgentArtifactsLiveTests: XCTestCase {
    private static let harnessTask = LockedBox<Task<AgentSessionScenarioHarness, Error>?>(nil)
    private var h: AgentSessionScenarioHarness!

    override func setUp() async throws {
        let task = Self.harnessTask.withValue { slot -> Task<AgentSessionScenarioHarness, Error> in
            if let slot { return slot }
            let created = Task { try await AgentSessionScenarioHarness.make("agent-artifacts-swift-4466") }
            slot = created
            return created
        }
        h = try await task.value
    }

    override class func tearDown() {
        guard let task = harnessTask.value else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            if let harness = try? await task.value { await harness.cleanup() }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 120)
        super.tearDown()
    }

    /// `data` uploaded to the session through its attachment route, as the owner.
    private func upload(_ client: JsBaoClient, _ s: AgentSessionScenarioHarness.Session, _ data: Data, _ filename: String) async throws -> String {
        try await client.agents.sessions.uploadAttachment(
            sessionId: s.sessionId, blobId: ULID.generate(),
            AgentSessionAttachmentUpload(data: data, filename: filename, contentType: "application/json")
        ).blobId
    }

    func testAFreshClientReadsBlobStoredInlineAndAbsentArtifactsAndThrowsForBadBlobs() async throws {
        let s = try await h.createSession(h.plain, participants: [h.part])
        let writer = try await h.client(h.owner)
        let stored: JSONValue = ["rows": .array((0..<50).map { ["i": .number(Double($0)), "label": .string("row \($0)")] })]
        let jsonBlob = try await upload(writer, s, try JSONCoding.encodeData(stored), "artifact.json")
        let badBlob = try await upload(writer, s, Data("{ this is not json".utf8), "bad.json")
        let missing = ULID.generate()

        let created = "2026-10-13T12:00:00.000Z"
        let calls: [(name: String, columns: [String: Any])] = [
            ("blob", ["artifactBlobId": jsonBlob]),
            ("inline", ["artifact": #"{"inline":true,"n":7}"#]),
            ("none", [:]),
            ("both", ["artifact": #"{"from":"inline"}"#, "artifactBlobId": jsonBlob]),
            ("bad", ["artifactBlobId": badBlob]),
            ("missing", ["artifactBlobId": missing]),
        ]
        var callIds: [String: String] = [:]
        var operations: [[String: Any]] = []
        for (n, call) in calls.enumerated() {
            let messageId = ULID.generate()
            let callId = "call_\(ULID.generate())"
            callIds[call.name] = callId
            operations.append([
                "model": "Message", "action": "create", "id": messageId,
                "data": ["seq": n + 1, "authorKind": "agent", "turnId": "t_seed", "createdAt": created],
            ])
            var data: [String: Any] = [
                "messageId": messageId, "seq": 1, "turnId": "t_seed", "state": "output-available", "toolName": "chart",
                "input": "{}", "output": #"{"ok":true}"#, "createdAt": created,
            ]
            data.merge(call.columns) { _, new in new }
            operations.append(["model": "ToolCall", "action": "create", "id": callId, "data": data])
        }
        try await h.seed(s, operations: operations)

        // A fresh client: nothing of these blobs is cached.
        let reader = try await h.client(h.part)
        let view = try await h.open(reader, s)
        try await h.poll(timeout: 120, "the seeded calls reach the reader") { view.toolCalls.count == calls.count }
        func call(_ name: String) throws -> AgentSessionToolCallRecord {
            try XCTUnwrap(view.toolCall(callIds[name] ?? ""), name)
        }

        XCTAssertNil(try call("blob").artifact)
        let blobValue = try await view.artifact(of: call("blob"))
        XCTAssertEqual(blobValue, stored)
        let inline = try await view.artifact(of: call("inline"))
        XCTAssertEqual(inline, ["inline": true, "n": 7])
        let none = try await view.artifact(of: call("none"))
        XCTAssertNil(none)
        // Edge 11: the blob wins over an inline value beside it.
        XCTAssertEqual(try call("both").artifact, ["from": "inline"])
        let both = try await view.artifact(of: call("both"))
        XCTAssertEqual(both, stored)

        // Edge 15: bytes that are not JSON, and a blob that does not exist.
        do {
            _ = try await view.artifact(of: call("bad"))
            XCTFail("a blob that is not JSON throws")
        } catch is DecodingError {}
        do {
            _ = try await view.artifact(of: call("missing"))
            XCTFail("a missing blob throws")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 404)
        }
        await view.close()
    }

    private struct Question: Codable, Sendable { let question: String }
    private struct Count: Codable, Sendable { let count: Int }

    func testATypedHandlersLargeArtifactReadsBackFromItsBlob() async throws {
        let s = try await h.createSession(h.initiator, participants: [h.part])
        let partC = try await h.client(h.part)
        let view = try await h.open(partC, s)
        let big: JSONValue = ["big": .string(String(repeating: "c", count: 200 * 1024)), "n": 3]
        let calls = Recorder<String>()
        try view.handleClientTools(["pick": .typed { (call: AgentClientToolCall<Question>) in
            calls.append(call.callId)
            return AgentClientToolResult(output: Count(count: 3), artifact: big)
        }])
        for _ in 0..<2 where calls.all.isEmpty {
            _ = try await view.send(text: "Go.")
            try await h.poll(timeout: 120, interval: 0.3, "the handler runs or the turn ends") {
                if !calls.all.isEmpty { return true }
                let turn = try await self.h.probe(s, "state")["turn"]
                return turn == nil || turn is NSNull
            }
        }
        let callId = try XCTUnwrap(calls.all.first, "the model called the tool")
        try await h.poll(timeout: 60, "the answer lands as a blob") {
            view.toolCall(callId)?.state == .outputAvailable && view.toolCall(callId)?.artifactBlobId != nil
        }
        XCTAssertNil(view.toolCall(callId)?.artifact)

        // A fresh client: the blob is not cached.
        let reader = try await h.client(h.part)
        let readerView = try await h.open(reader, s)
        try await h.poll(timeout: 60, "the call reaches the reader") {
            readerView.toolCall(callId)?.artifactBlobId != nil
        }
        let value = try await readerView.artifact(of: XCTUnwrap(readerView.toolCall(callId)))
        XCTAssertEqual(value, big)
        try await h.settled(s)
    }
}
