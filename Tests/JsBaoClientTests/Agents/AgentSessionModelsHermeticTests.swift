import XCTest
@testable import JsBaoClient

/// #4884 behaviors 2 and 3 — the records of a session's db3 in the Swift
/// client (project `agent-sessions-db3` phase 3; design doc §The proposed
/// models), rendered from the agent session IR into
/// `AgentSessionModels.generated.swift`.
///
/// Rows are flat: scalar columns read as they are, a list of ids is a
/// stringset (`Set<String>`), and JSON text holds only opaque values. Every
/// decode claim is made against the shared fixtures the JS unit suite also
/// reads and holds to the JS decoders (`Fixtures/AgentSessionRows/*.json`,
/// each `{ model, row, expect }` or `{ model, row, invalid }`, `model` one of
/// the db3's seven), so the two clients are held to one set of rows. In
/// `expect`, `{"$absent": true}` means "no value" — distinct from JSON
/// `null`, which is a value an `any` column can hold. A stringset is spelled
/// as its members, sorted; an absent one as `[]`.
final class AgentSessionModelsHermeticTests: XCTestCase {

    // MARK: - Fixtures

    private struct Fixture: Decodable {
        let model: String
        let row: [String: JSONValue]
        let expect: [String: JSONValue]?
        let invalid: String?
        var name: String = ""

        enum CodingKeys: String, CodingKey { case model, row, expect, invalid }
    }

    private static var fixtureDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        // .../Tests/JsBaoClientTests/Agents/<this file>
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        return url.appendingPathComponent("Fixtures/AgentSessionRows")
    }

    private static let fixtures: [Fixture] = {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: fixtureDirectory, includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      var fixture = try? JSONDecoder().decode(Fixture.self, from: data)
                else { return nil }
                fixture.name = url.deletingPathExtension().lastPathComponent
                return fixture
            }
    }()

    private func fixture(_ name: String) throws -> Fixture {
        try XCTUnwrap(Self.fixtures.first { $0.name == name }, "no fixture \(name)")
    }

    private func row(_ name: String) throws -> [String: JSONValue] { try fixture(name).row }

    // MARK: - The generated file

    func testTheGeneratedFileNamesTheSevenModelsAndTheVersion() {
        XCTAssertEqual(AgentSessionModels.schemaVersion, 3)
        XCTAssertEqual(AgentSessionModels.modelNames, ["Session", "Member", "Turn", "Message", "Part", "ToolCall", "Step"])
        XCTAssertEqual(AgentSessionStatus.known.count, 7)
        XCTAssertEqual(AgentSessionToolCallState.known.map(\.rawValue), [
            "input-streaming", "input-available", "approval-requested", "approval-responded",
            "output-available", "output-error", "output-denied",
        ])
        XCTAssertEqual(AgentSessionPartKind.known.map(\.rawValue), ["text", "reasoning", "file", "event"])
        XCTAssertEqual(AgentSessionTurnStatus.known.map(\.rawValue), ["running", "completed", "failed", "cancelled", "expired"])
    }

    // MARK: - Behavior 2: every fixture decodes to the projection the JS decoders give

    func testEveryFixtureDecodesToItsExpectationAndNoInvalidOneDecodes() throws {
        XCTAssertGreaterThan(Self.fixtures.count, 50, "fixtures not found at \(Self.fixtureDirectory.path)")
        XCTAssertEqual(Set(Self.fixtures.map(\.model)), Set(AgentSessionModels.modelNames))
        var invalid = 0
        for fixture in Self.fixtures {
            if fixture.invalid != nil {
                invalid += 1
                XCTAssertNil(AgentSessionProjection.decode(model: fixture.model, row: fixture.row), fixture.name)
                continue
            }
            let projection = try XCTUnwrap(
                AgentSessionProjection.decode(model: fixture.model, row: fixture.row), "\(fixture.name) did not decode"
            )
            for (key, expected) in fixture.expect ?? [:] {
                let actual = try XCTUnwrap(projection[key], "\(fixture.name): no projection for \(key)")
                XCTAssertEqual(actual, expected, "\(fixture.name).\(key)")
            }
        }
        XCTAssertGreaterThanOrEqual(invalid, 7)
    }

    // MARK: - Behavior 3: open values, kinds, calls, roles, stringsets, JSON

    func testEnumsDecodeOpenAndRoundTripTheirRawValue() throws {
        let session = try XCTUnwrap(AgentSessionRecord(row: try row("session-unknown-status")))
        XCTAssertEqual(session.status, .unknown("hibernating"))
        XCTAssertEqual(session.status.rawValue, "hibernating")
        XCTAssertEqual(AgentSessionStatus(rawValue: session.status.rawValue), session.status)

        let call = try XCTUnwrap(AgentSessionToolCallRecord(row: try row("tool-call-unknown-state")))
        XCTAssertEqual(call.state, .unknown("input-queued"))
        let step = try XCTUnwrap(AgentSessionStepRecord(row: try row("step-unknown-kind-and-status")))
        XCTAssertEqual(step.kind.rawValue, "sandbox_call")
        XCTAssertEqual(step.status, .unknown("paused"))
        let message = try XCTUnwrap(AgentSessionMessageRecord(row: try row("message-author-unknown-kind")))
        XCTAssertEqual(message.authorKind, .unknown("robot"))
        let turn = try XCTUnwrap(AgentSessionTurnRecord(row: try row("turn-failed-unknown-status")))
        XCTAssertEqual(turn.status, .unknown("paused"))
        let text = try XCTUnwrap(AgentSessionPartRecord(row: try row("part-text-tool-state")))
        guard case let .text(content) = text.content else { return XCTFail("\(text.content)") }
        XCTAssertEqual(content.textState, .unknown("output-available"))

        for status in AgentSessionStatus.known { XCTAssertEqual(AgentSessionStatus(rawValue: status.rawValue), status) }
        for state in AgentSessionToolCallState.known { XCTAssertEqual(AgentSessionToolCallState(rawValue: state.rawValue), state) }
        XCTAssertEqual(AgentSessionStepKind(rawValue: "client_call"), .clientCall)
        XCTAssertEqual(AgentSessionStatus(rawValue: "running_tool"), .runningTool)
        XCTAssertEqual(AgentSessionAuthorKind(rawValue: "app"), .app)
        XCTAssertEqual(AgentSessionTextState(rawValue: "done"), .done)
    }

    func testAPartOfAnUnknownKindDecodesWithItsWholeRow() throws {
        let source = try row("part-unknown-kind")
        let part = try XCTUnwrap(AgentSessionPartRecord(row: source))
        XCTAssertEqual(part.content, .unknown(kind: "citation"))
        XCTAssertEqual(part.kind, .unknown("citation"))
        XCTAssertEqual(part.messageId, "01K6MESSAGE0000000000000000")
        XCTAssertEqual(part.row, source)
        XCTAssertEqual(part.row["citationUrl"], "https://example.com")
    }

    func testEachKnownPartKindCarriesItsColumnsTyped() throws {
        let text = try XCTUnwrap(AgentSessionPartRecord(row: try row("part-text")))
        guard case let .text(t) = text.content else { return XCTFail("\(text.content)") }
        XCTAssertEqual(t.text, "Here is your refund.")
        XCTAssertEqual(t.textState, .done)
        XCTAssertEqual(t.providerMetadata?["google"], ["thoughtSignature": "c2lnbmF0dXJl"])
        let reasoning = try XCTUnwrap(AgentSessionPartRecord(row: try row("part-reasoning-streaming")))
        XCTAssertEqual(reasoning.content, .reasoning(AgentSessionTextPart(row: try row("part-reasoning-streaming"))))
        guard case let .reasoning(r) = reasoning.content else { return XCTFail("\(reasoning.content)") }
        XCTAssertEqual(r.textState, .streaming)
        let file = try XCTUnwrap(AgentSessionPartRecord(row: try row("part-file")))
        guard case let .file(f) = file.content else { return XCTFail("\(file.content)") }
        XCTAssertEqual(f.blobId, "blob_1")
        XCTAssertEqual(f.mediaType, "application/pdf")
        XCTAssertEqual(f.filename, "invoice.pdf")
        XCTAssertEqual(f.sizeBytes, 20480)
        let event = try XCTUnwrap(AgentSessionPartRecord(row: try row("part-event")))
        guard case let .event(e) = event.content else { return XCTFail("\(event.content)") }
        XCTAssertEqual(e.eventKind, "order_selected")
        XCTAssertEqual(e.data, ["orderId": "o_1", "lines": [1, 2]])
        // A column of another kind is not read: a text part has no file columns.
        var stray = try row("part-text")
        stray["blobId"] = "stray"
        XCTAssertEqual(AgentSessionPartRecord(row: stray)?.content, text.content)
    }

    func testAToolCallRowDecodesItsJsonColumnsOutputBlobNumberAndState() throws {
        let call = try XCTUnwrap(AgentSessionToolCallRecord(row: try row("tool-call-output-blob")))
        XCTAssertEqual(call.id, "call_01K6CALL0000000000000000001")
        XCTAssertEqual(call.turnId, "turn_1")
        XCTAssertEqual(call.state, .outputAvailable)
        XCTAssertEqual(call.input, ["topic": "rent"])
        XCTAssertNil(call.output)
        XCTAssertEqual(call.outputBlobId, "01K6BLOB00000000000000000000")
        XCTAssertEqual(call.callNumber, 2)

        let output = try XCTUnwrap(AgentSessionToolCallRecord(row: try row("tool-call-output")))
        XCTAssertEqual(output.output, ["recorded": true, "id": "exp_1", "tags": ["travel", nil]])
        XCTAssertEqual(output.artifact, ["rows": [["a": 1]]])
        XCTAssertEqual(output.approvalApproved, true)
        XCTAssertEqual(output.providerMetadata?["google"], ["thoughtSignature": "sig"])

        let cases: [(String, JSONValue)] = [
            ("tool-call-input-raw-string", .string(#"{"amount": 12.5,"#)),
            ("tool-call-input-null", .null),
            ("tool-call-input-invalid-object", ["amount": -5, "currency": "USD"]),
        ]
        for (name, input) in cases {
            let record = try XCTUnwrap(AgentSessionToolCallRecord(row: try row(name)), name)
            XCTAssertEqual(record.state, .outputError, name)
            XCTAssertEqual(record.input, input, name)
        }
        let nulls = try XCTUnwrap(AgentSessionToolCallRecord(row: try row("tool-call-null-payloads")))
        let absent = try XCTUnwrap(AgentSessionToolCallRecord(row: try row("tool-call-absent-payloads")))
        XCTAssertEqual(nulls.output, .null)
        XCTAssertEqual(nulls.artifact, .null)
        XCTAssertNil(absent.output)
        XCTAssertNil(absent.artifact)
        XCTAssertNil(absent.input)
        XCTAssertNil(AgentSessionToolCallRecord(row: try row("tool-call-missing-state")))
        XCTAssertNil(AgentSessionToolCallRecord(row: try row("tool-call-output-malformed"))?.output)
    }

    func testApprovalApprovedReadsBooleansAndZeroOneAsJavaScriptDoes() throws {
        let cases: [(String, Bool?)] = [
            ("tool-call-output", true),
            ("tool-call-approval-denied", false),
            ("tool-call-approval-numeric-1", true),
            ("tool-call-approval-numeric-0", false),
            ("tool-call-approval-string", nil),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(try XCTUnwrap(AgentSessionToolCallRecord(row: try row(name)), name).approvalApproved, expected, name)
        }
    }

    func testAMemberRoleDecodesIntoTheClientsSessionRole() throws {
        XCTAssertEqual(AgentSessionMemberRecord(row: try row("member-owner"))?.role, .owner)
        XCTAssertEqual(AgentSessionMemberRecord(row: try row("member-viewer"))?.role, .viewer)
        XCTAssertEqual(AgentSessionMemberRecord(row: ["id": "u_2", "role": "participant", "addedAt": "x"])?.role, .participant)
        // No member row holds `admin`: a role outside the IR's three reads `.unknown`.
        let outside = try XCTUnwrap(AgentSessionMemberRecord(row: try row("member-role-outside-vocabulary")))
        XCTAssertEqual(outside.role, .unknown("admin"))
        XCTAssertEqual(outside.addedAt, "2026-09-28T12:00:00.000Z")
        XCTAssertNil(AgentSessionMemberRecord(row: try row("member-missing-added-at")))
    }

    func testAStepsHistoryIsASetOfItsStringMembers() throws {
        let step = try XCTUnwrap(AgentSessionStepRecord(row: try row("step-model-call")))
        XCTAssertEqual(step.historyMessageIds, ["m_1", "m_2", "m_3"])
        XCTAssertEqual(AgentSessionStepRecord(row: try row("step-history-non-string-member"))?.historyMessageIds, ["m_2", "m_3"])
        XCTAssertEqual(AgentSessionStepRecord(row: try row("step-history-empty"))?.historyMessageIds, [])
        XCTAssertEqual(AgentSessionStepRecord(row: try row("step-context-call"))?.historyMessageIds, [])
        let hook = try XCTUnwrap(AgentSessionStepRecord(row: try row("step-history-hook")))
        XCTAssertEqual(hook.historyMode, "hook")
        XCTAssertEqual(hook.providerDurationMs, 812)
        XCTAssertEqual(hook.historySelection, [
            ["messageId": "m_2"], ["text": "summary"], ["messageId": "m_1"], ["messageId": "m_2"],
        ])
        let answered = try XCTUnwrap(AgentSessionStepRecord(row: try row("step-client-call-completed")))
        XCTAssertEqual(answered.kind, .clientCall)
        XCTAssertEqual(answered.resolvedByUserId, "u_participant_1")
        XCTAssertNil(AgentSessionStepRecord(row: try row("step-usage-non-numeric-cost"))?.cost)
    }

    func testTheSessionsJsonColumnsFallBackByTheirRule() throws {
        let wrong = try XCTUnwrap(AgentSessionRecord(row: try row("session-json-wrong-types")))
        XCTAssertEqual(wrong.variables, [:], "variables of the wrong JSON type read as an empty object")
        XCTAssertNil(AgentSessionRecord(row: try row("session-json-absent"))?.variables)
        XCTAssertNil(AgentSessionRecord(row: try row("session-json-malformed"))?.variables)
        let full = try XCTUnwrap(AgentSessionRecord(row: try row("session-full")))
        XCTAssertEqual(full.variables?["account"], ["id": "acct_1", "flags": ["beta": true]])
        XCTAssertEqual(full.status, .awaitingAnswer)
        XCTAssertEqual(full.activeTurnId, "turn_1")
        // providerMetadata is an object column without the fallback: the wrong type reads as no value.
        let wrongMetadata = try XCTUnwrap(AgentSessionPartRecord(row: try row("part-provider-metadata-wrong-type")))
        XCTAssertEqual(wrongMetadata.textContent?.text, "hi")
        XCTAssertNil(wrongMetadata.textContent?.providerMetadata)
    }

    func testAMessageCarriesItsQueuePositionAndANumericStringSeqDropsTheRow() throws {
        let queued = try XCTUnwrap(AgentSessionMessageRecord(row: try row("message-queued")))
        XCTAssertEqual(queued.queueSeq, 2)
        XCTAssertNil(AgentSessionMessageRecord(row: try row("message-user"))?.queueSeq)
        XCTAssertNil(AgentSessionMessageRecord(row: try row("message-seq-numeric-string")))
    }

    func testUndeclaredColumnsAreNotReadButStayOnTheRow() throws {
        let extra = try row("part-text-undeclared-column")
        var plain = extra
        plain["sources"] = nil
        XCTAssertEqual(AgentSessionPartRecord(row: extra)?.content, AgentSessionPartRecord(row: plain)?.content)
        XCTAssertEqual(AgentSessionPartRecord(row: extra)?.row["sources"], extra["sources"])
        let session = try row("session-undeclared-column")
        XCTAssertNotNil(AgentSessionRecord(row: session))
        XCTAssertEqual(AgentSessionRecord(row: session)?.row, session)
    }
}

private extension AgentSessionPartRecord {
    var textContent: AgentSessionTextPart? {
        if case let .text(content) = content { return content }
        return nil
    }
}
