import XCTest
@testable import JsBaoClient

/// Live session rows decode the same in Swift and in the JS client (#3810,
/// plan behavior 26; intent criterion 23, "decoding checked against the JS
/// client's").
///
/// The suite provisions its own corpus through `AgentSessionScenarioHarness`
/// — it runs under its own checkpoint filter, so it cannot lean on the live
/// suite having run — then reads every raw row of the four models from its
/// own store, as document sync delivered them, and holds the Swift decode and
/// the JS client's decode (`CrossPlatform/harness/agent-session-decode.mjs`)
/// to one projection (`AgentSessionProjection`, the #3802 fixture rules).
final class AgentSessionDecodeParityLiveTests: XCTestCase {

    func testLiveRowsDecodeTheSameInSwiftAndInTheJsClient() async throws {
        guard ClientSourceText.isMonorepoCheckout else {
            throw XCTSkip("the JS client's source is not beside the published Swift mirror")
        }
        let node: String
        do {
            node = try CrossPlatformHarness.nodePath()
        } catch {
            return XCTFail("node is required in the monorepo: \(error)")
        }
        let h = try await AgentSessionScenarioHarness.make("agent-session-parity-3810")
        do {
            try await compare(h, node: node)
        } catch {
            await h.cleanup()
            throw error
        }
        await h.cleanup()
    }

    private func compare(_ h: AgentSessionScenarioHarness, node: String) async throws {
        let (client, documents) = try await provision(h)

        // Every raw row of the four models, from this client's store.
        var rows: [(model: String, row: [String: JSONValue])] = []
        try await h.poll(timeout: 60, "the corpus syncs with its coverage") {
            rows = try AgentSessionModels.schemas.flatMap { schema in
                try client.codegen.query(schema, filter: nil, options: QueryOptions(documents: documents))
                    .map { (model: schema.name, row: $0) }
            }
            return Coverage(rows).missing.isEmpty
        }
        let coverage = Coverage(rows)
        XCTAssertEqual(coverage.missing, [], "the corpus covers every case")

        let swift = rows.map { AgentSessionProjection.decode(model: $0.model, row: $0.row).map(JSONValue.object) ?? .null }
        let js = try runHarness(node: node, rows: rows)
        XCTAssertEqual(js.count, rows.count)
        var differing = 0
        for (index, row) in rows.enumerated() where index < js.count && swift[index] != js[index] {
            differing += 1
            XCTFail("""
            \(row.model) \(row.row["id"]?.stringValue ?? "?") decodes differently
              swift: \(Self.text(swift[index]))
              js:    \(Self.text(js[index]))
            """)
        }
        XCTAssertGreaterThan(rows.count, 20, "a corpus worth comparing")
        print("[#3810] decode parity: \(rows.count) rows compared, \(differing) differing")
    }

    // MARK: - The corpus

    /// One TOOLS session (approved, denied and superseded calls, a Swift event
    /// and a `note` function event) and one SERVER session (request and task
    /// tools, a file). Answers the reading client and the two documents.
    private func provision(_ h: AgentSessionScenarioHarness) async throws -> (JsBaoClient, [String]) {
        let partC = try await h.client(h.part)
        let part2C = try await h.client(h.part2)

        let tools = try await h.createSession(h.tools, participants: [h.part, h.part2], viewers: [h.viewer], title: "Parity")
        let view = try await h.open(partC, tools)
        func callIds(_ turn: AgentSessionTurnSummary) async throws -> (sign: String, pick: String) {
            let ids = try XCTUnwrap(turn.pause?.callIds)
            try await h.poll(timeout: 30, "the paused calls sync") { ids.allSatisfy { view.toolCall($0) != nil } }
            return (
                try XCTUnwrap(ids.first { view.toolCall($0)?.toolName == "sign" }),
                try XCTUnwrap(ids.first { view.toolCall($0)?.toolName == "pick" })
            )
        }
        // An approval and two outputs.
        let (_, approvedTurn) = try await h.pausedTurn(tools, sender: partC, toolNames: ["sign", "pick"])
        let approved = try await callIds(approvedTurn)
        _ = try await view.answer(callId: approved.pick, .output(["count": 2]))
        _ = try await view.answer(callId: approved.sign, .approval(approved: true, reason: "Fine"))
        _ = try await view.answer(callId: approved.sign, .output(["signed": true]))
        try await h.settled(tools)
        // A denial and a client tool's error.
        let (_, deniedTurn) = try await h.pausedTurn(tools, sender: partC, toolNames: ["sign", "pick"])
        let denied = try await callIds(deniedTurn)
        _ = try await view.answer(callId: denied.sign, .approval(approved: false, reason: "Not now"))
        _ = try await view.answer(callId: denied.pick, .error(message: "No camera"))
        try await h.settled(tools)
        // Superseded calls.
        _ = try await h.pausedTurn(tools, sender: partC, toolNames: ["sign", "pick"])
        _ = try await part2C.agents.sessions.send(sessionId: tools.sessionId, body: AgentSessionSendBody(text: "Never mind."))
        try await h.settled(tools)
        // A Swift event (user-authored) and a function's (app-authored).
        _ = try await view.recordEvent(AgentSessionEvent(
            kind: "viewed", data: ["item": "lease"], eventId: "ev-\(h.stamp)", refersTo: approved.sign
        ))
        _ = try await h.invokeNote(tools, as: h.part, data: ["item": "note"])

        let server = try await h.createSession(h.server, participants: [h.part])
        let serverView = try await h.open(partC, server)
        for _ in 0..<2 {
            let sent = try await serverView.send(text: "Go.")
            try await h.settled(server)
            try await h.poll(timeout: 30, "the turn's rows sync") {
                serverView.syncedMessages.contains { $0.message.turnId == sent.turnId && $0.message.authorKind == .agent }
            }
            if serverView.allSteps.contains(where: { $0.turnId == sent.turnId && $0.kind == .toolCall }) { break }
        }
        let blobId = try await h.uploadPng(partC, server)
        _ = try await serverView.send(text: "", files: [AgentSessionFileRef(blobId: blobId)])
        try await h.settled(server)
        return (partC, [tools.documentId, server.documentId])
    }

    /// What the corpus must hold before the comparison means anything.
    private struct Coverage {
        let missing: [String]

        init(_ rows: [(model: String, row: [String: JSONValue])]) {
            func column(_ model: String, _ name: String) -> Set<String> {
                Set(rows.filter { $0.model == model }.compactMap { $0.row[name]?.stringValue })
            }
            var missing: [String] = []
            let sessions = rows.filter { $0.model == "PrimitiveSession" }.compactMap { PrimitiveSession(row: $0.row) }
            if !sessions.contains(where: { $0.title != nil && ($0.participantUserIds?.count ?? 0) > 1 && $0.viewerUserIds != nil }) {
                missing.append("a session with members and a title")
            }
            for author in ["user", "agent", "app"] where !column("PrimitiveMessage", "authorKind").contains(author) {
                missing.append("a \(author) message")
            }
            for kind in ["text", "file", "event", "tool_call"] where !column("PrimitivePart", "kind").contains(kind) {
                missing.append("a \(kind) part")
            }
            let toolStates = Set(rows.filter { $0.model == "PrimitivePart" && $0.row["kind"]?.stringValue == "tool_call" }
                .compactMap { $0.row["state"]?.stringValue })
            for state in ["output-available", "output-denied", "output-error"] where !toolStates.contains(state) {
                missing.append("a tool_call part \(state)")
            }
            for kind in ["model_call", "tool_call"] where !column("PrimitiveStep", "kind").contains(kind) {
                missing.append("a \(kind) step")
            }
            self.missing = missing
        }
    }

    // MARK: - The JS side

    private func runHarness(node: String, rows: [(model: String, row: [String: JSONValue])]) throws -> [JSONValue] {
        let repoRoot = ClientSourceText.repoRoot
        let script = CrossPlatformHarness.harnessDir.appendingPathComponent("agent-session-decode.mjs")
        let input: JSONValue = ["rows": .array(rows.map { ["model": .string($0.model), "row": .object($0.row)] })]
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agent-session-decode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let inputFile = temp.appendingPathComponent("rows.json")
        let errorFile = temp.appendingPathComponent("stderr.txt")
        try JSONEncoder().encode(input).write(to: inputFile)
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["--import", "tsx", script.path, repoRoot.path]
        process.currentDirectoryURL = repoRoot
        process.standardInput = try FileHandle(forReadingFrom: inputFile)
        process.standardError = try FileHandle(forWritingTo: errorFile)
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
            throw TestSetupError("agent-session-decode.mjs exited \(process.terminationStatus): \(stderr)")
        }
        return try JSONDecoder().decode([JSONValue].self, from: data)
    }

    private static func text(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
    }
}
