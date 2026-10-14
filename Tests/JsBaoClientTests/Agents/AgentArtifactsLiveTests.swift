import Foundation
import XCTest
@testable import JsBaoClient

/// `view.artifact(of:)` on live Swift clients over real blobs (#4466, plan
/// behavior 8; edge cases 11 and 15). A writer uploads blobs to the session's
/// document through the client's blob API and saves tool-call parts that name
/// them; a fresh reader client (an empty blob cache) reads them through its
/// view. The large case is a real client-tool answer, which the server stores
/// as a blob.
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

    private struct Question: Codable, Sendable { let question: String }
    private struct Count: Codable, Sendable { let count: Int }

    private func upload(_ client: JsBaoClient, _ s: AgentSessionScenarioHarness.Session, _ data: Data, _ filename: String) async throws -> String {
        try await client.documents.blobs(documentId: s.documentId).upload(
            data: data, options: BlobUploadSourceOptions(filename: filename, contentType: "application/json")
        ).blobId
    }

    func testAFreshClientReadsBlobStoredInlineAndAbsentArtifactsAndThrowsForBadBlobs() async throws {
        let s = try await h.createSession(h.plain, participants: [h.part])
        let writer = try await h.client(h.owner)
        writer.registerModels(AgentSessionModels.schemas)
        _ = try await writer.documents.open(s.documentId, options: OpenDocumentOptions(waitForLoad: .network))
        let stored: JSONValue = ["rows": .array((0..<50).map { ["i": .number(Double($0)), "label": .string("row \($0)")] })]
        let jsonBlob = try await upload(writer, s, try JSONCoding.encodeData(stored), "artifact.json")
        let badBlob = try await upload(writer, s, Data("{ this is not json".utf8), "bad.json")
        let missing = PrimitiveSchemaRegistry.generateULID()

        let created = "2026-10-13T12:00:00.000Z"
        let calls: [(name: String, columns: [String: PrimitiveValue])] = [
            ("blob", ["artifactBlobId": .string(jsonBlob)]),
            ("inline", ["artifact": .string(#"{"inline":true,"n":7}"#)]),
            ("none", [:]),
            ("both", ["artifact": .string(#"{"from":"inline"}"#), "artifactBlobId": .string(jsonBlob)]),
            ("bad", ["artifactBlobId": .string(badBlob)]),
            ("missing", ["artifactBlobId": .string(missing)]),
        ]
        var partIds: [String: String] = [:]
        for (n, call) in calls.enumerated() {
            let messageId = PrimitiveSchemaRegistry.generateULID()
            let partId = PrimitiveSchemaRegistry.generateULID()
            partIds[call.name] = partId
            try writer.codegen.save(PrimitiveMessage.primitiveSchema, id: messageId, values: [
                "seq": .number(Double(n + 1)), "authorKind": .string("agent"), "createdAt": .date(created),
            ], in: s.documentId)
            var values: [String: PrimitiveValue] = [
                "messageId": .string(messageId), "seq": .number(1), "kind": .string("tool_call"),
                "state": .string("output-available"), "toolCallId": .string("call-\(partId)"),
                "toolName": .string("chart"), "createdAt": .date(created),
            ]
            values.merge(call.columns) { _, new in new }
            try writer.codegen.save(PrimitivePart.primitiveSchema, id: partId, values: values, in: s.documentId)
        }

        // A fresh client: nothing of these blobs is cached.
        let reader = try await h.client(h.part)
        let view = try await h.open(reader, s)
        try await h.poll(timeout: 120, "the seeded parts reach the reader") { view.toolCalls.count == calls.count }
        func part(_ name: String) throws -> PrimitivePart {
            try XCTUnwrap(view.toolCalls.first { $0.id == partIds[name] }, name)
        }

        XCTAssertNil(try part("blob").artifact)
        let blobValue = try await view.artifact(of: part("blob"))
        XCTAssertEqual(blobValue, stored)
        let inline = try await view.artifact(of: part("inline"))
        XCTAssertEqual(inline, ["inline": true, "n": 7])
        let none = try await view.artifact(of: part("none"))
        XCTAssertNil(none)
        // Edge 11: the blob wins over an inline value beside it.
        XCTAssertEqual(try part("both").artifact, ["from": "inline"])
        let both = try await view.artifact(of: part("both"))
        XCTAssertEqual(both, stored)

        // Edge 15: bytes that are not JSON, and a blob that does not exist.
        do {
            _ = try await view.artifact(of: part("bad"))
            XCTFail("a blob that is not JSON throws")
        } catch is DecodingError {}
        do {
            _ = try await view.artifact(of: part("missing"))
            XCTFail("a missing blob throws")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 404)
        }
    }

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
            view.toolCall(callId)?.state == "output-available" && view.toolCall(callId)?.artifactBlobId != nil
        }
        XCTAssertNil(view.toolCall(callId)?.artifact)

        // A fresh client: the blob is not cached.
        let reader = try await h.client(h.part)
        let readerView = try await h.open(reader, s)
        try await h.poll(timeout: 60, "the part reaches the reader") {
            readerView.toolCall(callId)?.artifactBlobId != nil
        }
        let value = try await readerView.artifact(of: XCTUnwrap(readerView.toolCall(callId)))
        XCTAssertEqual(value, big)
        try await h.settled(s)
    }
}
