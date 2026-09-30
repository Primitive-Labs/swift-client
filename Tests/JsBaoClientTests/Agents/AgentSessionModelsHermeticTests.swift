import XCTest
@testable import JsBaoClient
import YSwift

/// #3802 — the platform session models in the Swift client (project `agents`
/// phase 2; design-docs/agents.md §D3, §D7).
///
/// Rows are flat: fixed shapes are scalar columns, lists of ids are
/// stringsets (`Set<String>`), and JSON text holds only the opaque values and
/// the queue. Every decode claim is made against the shared fixtures the JS
/// unit suite also reads (`Fixtures/AgentSessionRows/*.json`, each `{ model,
/// row, expect }` or `{ model, row, invalid }`), so the two clients are held
/// to one set of rows. In `expect`, `{"$absent": true}` means "no value" —
/// distinct from JSON `null`, which is a value an `any` column can hold. A
/// stringset is spelled as its members, sorted; an absent one as `[]`.
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

    private static let absent: JSONValue = ["$absent": true]

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

    // MARK: - Projections (decoded values as the fixtures spell them)

    private func open(_ raw: String?, known: Bool) -> JSONValue {
        guard let raw else { return Self.absent }
        return .string(known ? raw : "unknown")
    }
    private func value(_ v: String?) -> JSONValue { v.map { .string($0) } ?? Self.absent }
    private func value(_ v: Double?) -> JSONValue { v.map { .number($0) } ?? Self.absent }
    private func value(_ v: Bool?) -> JSONValue { v.map { .bool($0) } ?? Self.absent }
    private func value(_ v: JSONValue?) -> JSONValue { v ?? Self.absent }
    private func value(_ v: [String: JSONValue]?) -> JSONValue { v.map { .object($0) } ?? Self.absent }
    private func members(_ v: Set<String>?) -> JSONValue { .array((v ?? []).sorted().map { .string($0) }) }
    private func queue(_ v: [PrimitiveQueueEntry]?) -> JSONValue { v.map { .array($0.map(\.jsonValue)) } ?? Self.absent }

    private func project(_ s: PrimitiveSession) -> [String: JSONValue] {
        [
            "id": .string(s.id),
            "schemaVersion": .number(s.schemaVersion),
            "agentKey": .string(s.agentKey),
            "configId": value(s.configId),
            "status": open(s.status.rawValue, known: s.status.isKnown),
            "activeTurnId": value(s.activeTurnId),
            "activeTurnInitiatorUserId": value(s.activeTurnInitiatorUserId),
            "activeTurnStartedAt": value(s.activeTurnStartedAt),
            "activeTurnMessageIds": members(s.activeTurnMessageIds),
            "queue": queue(s.queue),
            "title": value(s.title),
            "scope": value(s.scope),
            "variables": value(s.variables),
            "viewerUserIds": members(s.viewerUserIds),
            "participantUserIds": members(s.participantUserIds),
            "ownerUserId": value(s.ownerUserId),
            "lastErrorCode": value(s.lastErrorCode),
            "lastErrorMessage": value(s.lastErrorMessage),
            "createdAt": .string(s.createdAt),
            "modifiedAt": value(s.modifiedAt),
        ]
    }

    private func project(_ m: PrimitiveMessage) -> [String: JSONValue] {
        [
            "id": .string(m.id),
            "seq": .number(m.seq),
            "turnId": value(m.turnId),
            "authorKind": open(m.authorKind.rawValue, known: m.authorKind.isKnown),
            "authorUserId": value(m.authorUserId),
            "clientMessageId": value(m.clientMessageId),
            "createdAt": .string(m.createdAt),
        ]
    }

    private func project(_ p: PrimitivePart) -> [String: JSONValue] {
        var out: [String: JSONValue] = [
            "id": .string(p.id),
            "messageId": .string(p.messageId),
            "seq": .number(p.seq),
            "createdAt": .string(p.createdAt),
            "modifiedAt": value(p.modifiedAt),
        ]
        switch p.content {
        case let .text(c), let .reasoning(c):
            out["kind"] = .string(p.kind.rawValue)
            out["state"] = c.state.map { open($0.rawValue, known: $0.isKnown) } ?? Self.absent
            out["text"] = value(c.text)
            out["providerMetadata"] = value(c.providerMetadata)
        case let .toolCall(c):
            out["kind"] = "tool_call"
            out["state"] = c.state.map { open($0.rawValue, known: $0.isKnown) } ?? Self.absent
            out["toolCallId"] = value(c.toolCallId)
            out["toolName"] = value(c.toolName)
            out["input"] = value(c.input)
            out["output"] = value(c.output)
            out["errorText"] = value(c.errorText)
            out["errorCode"] = value(c.errorCode)
            out["statusText"] = value(c.statusText)
            out["approvalApproved"] = value(c.approvalApproved)
            out["approvalReason"] = value(c.approvalReason)
            out["approvalUserId"] = value(c.approvalUserId)
            out["approvalRespondedAt"] = value(c.approvalRespondedAt)
            out["resolvedByUserId"] = value(c.resolvedByUserId)
            out["artifact"] = value(c.artifact)
            out["artifactBlobId"] = value(c.artifactBlobId)
            out["providerMetadata"] = value(c.providerMetadata)
        case let .file(c):
            out["kind"] = "file"
            out["mediaType"] = value(c.mediaType)
            out["filename"] = value(c.filename)
            out["blobId"] = value(c.blobId)
            out["sizeBytes"] = value(c.sizeBytes)
        case let .event(c):
            out["kind"] = "event"
            out["eventKind"] = value(c.eventKind)
            out["eventId"] = value(c.eventId)
            out["refersTo"] = value(c.refersTo)
            out["data"] = value(c.data)
        case let .unknown(kind):
            out["kind"] = "unknown"
            out["rawKind"] = .string(kind)
        }
        return out
    }

    private func project(_ s: PrimitiveStep) -> [String: JSONValue] {
        [
            "id": .string(s.id),
            "turnId": .string(s.turnId),
            "seq": .number(s.seq),
            "kind": open(s.kind.rawValue, known: s.kind.isKnown),
            "status": open(s.status.rawValue, known: s.status.isKnown),
            "startedAt": .string(s.startedAt),
            "endedAt": value(s.endedAt),
            "durationMs": value(s.durationMs),
            "provider": value(s.provider),
            "model": value(s.model),
            "configId": value(s.configId),
            "callId": value(s.callId),
            "toolName": value(s.toolName),
            "functionName": value(s.functionName),
            "functionVersion": value(s.functionVersion),
            "inputTokens": value(s.inputTokens),
            "outputTokens": value(s.outputTokens),
            "totalTokens": value(s.totalTokens),
            "reasoningTokens": value(s.reasoningTokens),
            "cachedInputTokens": value(s.cachedInputTokens),
            "cost": value(s.cost),
            "historyMessageIds": members(s.historyMessageIds),
            "errorCode": value(s.errorCode),
            "errorMessage": value(s.errorMessage),
        ]
    }

    /// Decode `fixture` with its model, as its projection.
    private func decode(_ fixture: Fixture) -> [String: JSONValue]? {
        switch fixture.model {
        case "PrimitiveSession": return PrimitiveSession(row: fixture.row).map(project)
        case "PrimitiveMessage": return PrimitiveMessage(row: fixture.row).map(project)
        case "PrimitivePart": return PrimitivePart(row: fixture.row).map(project)
        case "PrimitiveStep": return PrimitiveStep(row: fixture.row).map(project)
        default:
            XCTFail("\(fixture.name): unknown model \(fixture.model)")
            return nil
        }
    }

    // MARK: - Behavior 14: the generated file

    func testTheGeneratedFileDeclaresTheFourModelsAndTheirSchemas() {
        XCTAssertEqual(AgentSessionModels.schemas.map(\.name), [
            "PrimitiveSession", "PrimitiveMessage", "PrimitivePart", "PrimitiveStep",
        ])
        XCTAssertEqual(AgentSessionModels.schemaVersion, 1)
        XCTAssertEqual(PrimitiveSession.modelName, "PrimitiveSession")
        XCTAssertEqual(PrimitivePart.primitiveSchema.fields["kind"], FieldDescriptor(type: .string, required: true))
        XCTAssertEqual(PrimitivePart.primitiveSchema.fields["toolCallId"], FieldDescriptor(type: .string, indexed: true))
        XCTAssertEqual(PrimitivePart.primitiveSchema.fields["approvalApproved"], FieldDescriptor(type: .boolean))
        XCTAssertEqual(PrimitiveMessage.primitiveSchema.fields["authorKind"], FieldDescriptor(type: .string, required: true))
        for field in ["viewerUserIds", "participantUserIds", "activeTurnMessageIds"] {
            XCTAssertEqual(PrimitiveSession.primitiveSchema.fields[field], FieldDescriptor(type: .stringset), field)
        }
        XCTAssertEqual(PrimitiveStep.primitiveSchema.fields["historyMessageIds"], FieldDescriptor(type: .stringset))
        XCTAssertNil(PrimitiveSession.primitiveSchema.fields["members"])
        XCTAssertNil(PrimitiveMessage.primitiveSchema.fields["author"])
        XCTAssertEqual(PrimitiveSessionStatus.known.count, 7)
        XCTAssertEqual(PrimitiveToolCallState.known.map(\.rawValue), [
            "input-streaming", "input-available", "approval-requested", "approval-responded",
            "output-available", "output-error", "output-denied",
        ])
    }

    // MARK: - Behavior 16: every fixture decodes to its expectation

    func testEveryFixtureDecodesToItsExpectation() throws {
        XCTAssertGreaterThan(Self.fixtures.count, 40, "fixtures not found at \(Self.fixtureDirectory.path)")
        XCTAssertEqual(Set(Self.fixtures.map(\.model)), Set(AgentSessionModels.schemas.map(\.name)))
        for fixture in Self.fixtures {
            guard let expect = fixture.expect else { continue }
            let projection = try XCTUnwrap(decode(fixture), "\(fixture.name) did not decode")
            for (key, expected) in expect {
                let actual = try XCTUnwrap(projection[key], "\(fixture.name): no projection for \(key)")
                XCTAssertEqual(actual, expected, "\(fixture.name).\(key)")
            }
        }
    }

    func testStringsetsDecodeToSetsAndAbsentOnesToNil() throws {
        let full = try XCTUnwrap(PrimitiveSession(row: try fixture("session-full").row))
        XCTAssertEqual(full.viewerUserIds, ["u_3", "u_4"])
        XCTAssertEqual(full.participantUserIds, ["u_2"])
        XCTAssertEqual(full.activeTurnMessageIds, ["m_1", "m_2"])
        // Absent and empty both read as no members: the store's query path
        // hands back every declared stringset as an array, empty when unset.
        let absent = try XCTUnwrap(PrimitiveSession(row: try fixture("session-json-absent").row))
        XCTAssertNil(absent.viewerUserIds)
        let empty = try XCTUnwrap(PrimitiveSession(row: try fixture("session-stringsets-empty").row))
        XCTAssertNil(empty.viewerUserIds)
        let mixed = try XCTUnwrap(PrimitiveSession(row: try fixture("session-stringset-non-string-member").row))
        XCTAssertEqual(mixed.viewerUserIds, ["u_2", "u_3"])
        let step = try XCTUnwrap(PrimitiveStep(row: try fixture("step-model-call").row))
        XCTAssertEqual(step.historyMessageIds, ["m_1", "m_2", "m_3"])
    }

    func testApprovalApprovedReadsBooleansAndZeroOneAsJavaScriptDoes() throws {
        let cases: [(String, Bool?)] = [
            ("part-tool-call-output", true),
            ("part-tool-call-approval-denied", false),
            ("part-tool-call-approval-numeric-1", true),
            ("part-tool-call-approval-numeric-0", false),
            ("part-tool-call-approval-string", nil),
        ]
        for (name, expected) in cases {
            let part = try XCTUnwrap(PrimitivePart(row: try fixture(name).row), name)
            XCTAssertEqual(part.approvalApproved, expected, name)
        }
    }

    func testPartContentCarriesEachKindTyped() throws {
        let part = try XCTUnwrap(PrimitivePart(row: try fixture("part-tool-call-output").row))
        guard case let .toolCall(content) = part.content else {
            return XCTFail("expected a tool call, got \(part.content)")
        }
        XCTAssertEqual(content.state, .outputAvailable)
        XCTAssertEqual(content.approvalApproved, true)
        XCTAssertEqual(content.approvalUserId, "u_owner")
        XCTAssertEqual(content.approvalRespondedAt, "2026-09-28T12:00:00.000Z")
        XCTAssertNil(content.approvalReason)

        let text = try XCTUnwrap(PrimitivePart(row: try fixture("part-text").row))
        XCTAssertEqual(text.content, .text(PrimitiveTextPartContent(
            state: .done, text: "Here is your refund.", providerMetadata: text.providerMetadata
        )))
        let reasoning = try XCTUnwrap(PrimitivePart(row: try fixture("part-reasoning-streaming").row))
        guard case let .reasoning(r) = reasoning.content else { return XCTFail("\(reasoning.content)") }
        XCTAssertEqual(r.state, .streaming)
        let file = try XCTUnwrap(PrimitivePart(row: try fixture("part-file").row))
        XCTAssertEqual(file.content, .file(PrimitiveFilePartContent(
            mediaType: "application/pdf", filename: "invoice.pdf", blobId: "blob_1", sizeBytes: 20480
        )))
        let event = try XCTUnwrap(PrimitivePart(row: try fixture("part-event").row))
        guard case let .event(e) = event.content else { return XCTFail("\(event.content)") }
        XCTAssertEqual(e.data, ["orderId": "o_1", "lines": [1, 2]])
    }

    // MARK: - Behavior 17: open vocabularies, opaque parts, ignored columns, fallbacks

    func testUnknownValuesDecodeToUnknownAndKeepTheirRawValue() throws {
        let session = try XCTUnwrap(PrimitiveSession(row: try fixture("session-unknown-status").row))
        XCTAssertEqual(session.status, .unknown("hibernating"))
        XCTAssertEqual(session.status.rawValue, "hibernating")
        XCTAssertFalse(session.status.isKnown)

        let tool = try XCTUnwrap(PrimitivePart(row: try fixture("part-tool-call-unknown-state").row))
        guard case let .toolCall(content) = tool.content else { return XCTFail("\(tool.content)") }
        XCTAssertEqual(content.state, .unknown("input-queued"))

        let step = try XCTUnwrap(PrimitiveStep(row: try fixture("step-unknown-kind-and-status").row))
        XCTAssertEqual(step.kind.rawValue, "sandbox_call")
        XCTAssertEqual(step.status, .unknown("paused"))

        let message = try XCTUnwrap(PrimitiveMessage(row: try fixture("message-author-unknown-kind").row))
        XCTAssertEqual(message.authorKind, .unknown("robot"))
        XCTAssertEqual(message.authorUserId, "u_9")
    }

    func testAnUnknownPartKindDecodesToTheOpaquePartWithColumnsReadable() throws {
        let part = try XCTUnwrap(PrimitivePart(row: try fixture("part-unknown-kind").row))
        XCTAssertEqual(part.content, .unknown(kind: "citation"))
        XCTAssertEqual(part.kind, .unknown("citation"))
        XCTAssertEqual(part.kind.rawValue, "citation")
        XCTAssertEqual(part.text, "see [1]")
        XCTAssertEqual(part.messageId, "01K6MESSAGE0000000000000000")
    }

    func testUndeclaredColumnsAreIgnored() throws {
        let extra = try fixture("part-text-undeclared-column")
        var plain = extra.row
        plain["sources"] = nil
        XCTAssertEqual(PrimitivePart(row: extra.row), PrimitivePart(row: plain))
        let session = try fixture("session-undeclared-column")
        var bare = session.row
        bare["futureColumn"] = nil
        bare["futureCount"] = nil
        XCTAssertNotNil(PrimitiveSession(row: session.row))
        XCTAssertEqual(PrimitiveSession(row: session.row), PrimitiveSession(row: bare))
    }

    func testANumberColumnHoldingAStringIsNilAndTheRowIsKept() throws {
        let step = try XCTUnwrap(PrimitiveStep(row: try fixture("step-usage-non-numeric-cost").row))
        XCTAssertNil(step.cost)
        XCTAssertEqual(step.inputTokens, 10)
        XCTAssertEqual(step.outputTokens, 2)
    }

    func testJsonColumnsFallBackPerRuleFive() throws {
        let absent = try XCTUnwrap(PrimitiveSession(row: try fixture("session-json-absent").row))
        let malformed = try XCTUnwrap(PrimitiveSession(row: try fixture("session-json-malformed").row))
        for session in [absent, malformed] {
            XCTAssertNil(session.variables)
            XCTAssertNil(session.queue)
        }
        let wrong = try XCTUnwrap(PrimitiveSession(row: try fixture("session-json-wrong-types").row))
        XCTAssertEqual(wrong.variables, [:])
        XCTAssertEqual(wrong.queue, [])

        var text = try fixture("part-text").row
        text["providerMetadata"] = "{nope"
        XCTAssertNil(try XCTUnwrap(PrimitivePart(row: text)).providerMetadata)
        text["providerMetadata"] = nil
        XCTAssertNil(try XCTUnwrap(PrimitivePart(row: text)).providerMetadata)
        let wrongMetadata = try XCTUnwrap(PrimitivePart(row: try fixture("part-provider-metadata-wrong-type").row))
        XCTAssertNil(wrongMetadata.providerMetadata)

        let malformedOutput = try XCTUnwrap(PrimitivePart(row: try fixture("part-tool-call-output-malformed").row))
        XCTAssertNil(malformedOutput.output)
    }

    // MARK: - Behavior 18: required scalar columns

    func testARowMissingARequiredScalarColumnIsReportedNamingTheField() throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var errors: [PrimitiveDecodeError] = []
        }
        let box = Box()
        PrimitiveRowDecoder.onDecodeFailure = { error in box.lock.withLock { box.errors.append(error) } }
        defer { PrimitiveRowDecoder.onDecodeFailure = nil }

        var checked = 0
        for fixture in Self.fixtures {
            guard let invalid = fixture.invalid else { continue }
            checked += 1
            box.lock.withLock { box.errors = [] }
            let decodedCount: Int
            switch fixture.model {
            case "PrimitiveSession":
                XCTAssertNil(PrimitiveSession(row: fixture.row), fixture.name)
                decodedCount = PrimitiveRowDecoder.decodeAll([fixture.row], as: PrimitiveSession.self).count
            case "PrimitiveMessage":
                XCTAssertNil(PrimitiveMessage(row: fixture.row), fixture.name)
                decodedCount = PrimitiveRowDecoder.decodeAll([fixture.row], as: PrimitiveMessage.self).count
            case "PrimitivePart":
                XCTAssertNil(PrimitivePart(row: fixture.row), fixture.name)
                decodedCount = PrimitiveRowDecoder.decodeAll([fixture.row], as: PrimitivePart.self).count
            default:
                XCTAssertNil(PrimitiveStep(row: fixture.row), fixture.name)
                decodedCount = PrimitiveRowDecoder.decodeAll([fixture.row], as: PrimitiveStep.self).count
            }
            XCTAssertEqual(decodedCount, 0, fixture.name)
            let errors = box.lock.withLock { box.errors }
            XCTAssertEqual(errors.count, 1, fixture.name)
            XCTAssertEqual(errors.first?.fields.contains(invalid), true, "\(fixture.name): \(errors)")
        }
        XCTAssertGreaterThanOrEqual(checked, 5)
    }

    func testARowMissingOnlyJsonAndStringsetColumnsDecodes() throws {
        var row = try fixture("session-full").row
        for column in ["queue", "variables", "viewerUserIds", "participantUserIds", "activeTurnMessageIds"] {
            row[column] = nil
        }
        let session = try XCTUnwrap(PrimitiveSession(row: row))
        XCTAssertNil(session.variables)
        XCTAssertNil(session.viewerUserIds)
        XCTAssertEqual(session.status, .awaitingAnswer)
    }

    // MARK: - Behavior 19: the PrimitiveModel conformance round-trips

    func testInitRecordRoundTripsPrimitiveValuesOfEveryFixture() throws {
        for fixture in Self.fixtures where fixture.invalid == nil {
            switch fixture.model {
            case "PrimitiveSession": try roundTrip(PrimitiveSession(row: fixture.row), fixture.name)
            case "PrimitiveMessage": try roundTrip(PrimitiveMessage(row: fixture.row), fixture.name)
            case "PrimitivePart": try roundTrip(PrimitivePart(row: fixture.row), fixture.name)
            default: try roundTrip(PrimitiveStep(row: fixture.row), fixture.name)
            }
        }
        let session = try XCTUnwrap(PrimitiveSession(row: try fixture("session-full").row))
        XCTAssertEqual(session.primitiveValues()["viewerUserIds"], .stringset(["u_3", "u_4"]))
        let output = try XCTUnwrap(PrimitivePart(row: try fixture("part-tool-call-null-payloads").row))
        XCTAssertEqual(output.primitiveValues()["output"], .string("null"))
        let input = try XCTUnwrap(PrimitivePart(row: try fixture("part-tool-call-input-raw-string").row))
        XCTAssertEqual(input.primitiveValues()["input"], .string(#""{\"amount\": 12.5,""#))
        let bare = try XCTUnwrap(PrimitiveSession(row: try fixture("session-json-absent").row))
        XCTAssertNil(bare.primitiveValues()["variables"])
        XCTAssertNil(bare.primitiveValues()["queue"])
        XCTAssertNil(bare.primitiveValues()["viewerUserIds"])
    }

    private func roundTrip<T: PrimitiveModel & PrimitiveRowDecodable & Equatable>(_ value: T?, _ name: String) throws {
        let decoded = try XCTUnwrap(value, "\(name) did not decode")
        SchemaSync.clearCache()
        let model = DynamicModel(doc: YDocument(), schema: T.primitiveSchema)
        let record = try model.create(id: decoded.id, values: decoded.primitiveValues())
        let back = try XCTUnwrap(T(record: record), "\(name): init?(record:) refused its own values")
        XCTAssertEqual(back, decoded, name)
        // Through the SQLite-backed query path too.
        let rows = try model.query(["id": .string(record.id)])
        let queried = PrimitiveRowDecoder.decodeAll(rows, as: T.self)
        XCTAssertEqual(queried, [back], "\(name) via query")
    }

    // MARK: - Behaviors 23-26 (Swift halves)

    func testOpenDictionariesKeepEveryKeyAndNestedValue() throws {
        let session = try XCTUnwrap(PrimitiveSession(row: try fixture("session-full").row))
        let variables = try XCTUnwrap(session.variables)
        XCTAssertEqual(Set(variables.keys), ["plan", "account", "recent"])
        XCTAssertEqual(variables["plan"], "pro")
        XCTAssertEqual(variables["recent"], ["a", nil, 3])
        XCTAssertEqual(variables["account"], ["id": "acct_1", "flags": ["beta": true]])
        let part = try XCTUnwrap(PrimitivePart(row: try fixture("part-text").row))
        let metadata = try XCTUnwrap(part.providerMetadata)
        XCTAssertEqual(Set(metadata.keys), ["openrouter", "google"])
        XCTAssertEqual(metadata["google"], ["thoughtSignature": "c2lnbmF0dXJl"])
        XCTAssertEqual(metadata["openrouter"]?["reasoning_details"]?.arrayValue?.count, 2)
        XCTAssertEqual(metadata["openrouter"]?["reasoning_details"]?.arrayValue?[1]["summary"], .null)
        let fallback = try XCTUnwrap(PrimitiveSession(row: try fixture("session-json-wrong-types").row))
        XCTAssertEqual(fallback.variables, [:])
    }

    func testExplicitNullIsAValueDistinctFromAnAbsentColumn() throws {
        let nulls = try XCTUnwrap(PrimitivePart(row: try fixture("part-tool-call-null-payloads").row))
        let absent = try XCTUnwrap(PrimitivePart(row: try fixture("part-tool-call-absent-payloads").row))
        XCTAssertEqual(nulls.output, .null)
        XCTAssertEqual(nulls.artifact, .null)
        XCTAssertNil(absent.output)
        XCTAssertNil(absent.artifact)
        XCTAssertNil(absent.input)
        XCTAssertNotEqual(nulls.output, absent.output)
        XCTAssertEqual(try XCTUnwrap(PrimitivePart(row: try fixture("part-tool-call-input-null").row)).input, .null)
        XCTAssertEqual(try XCTUnwrap(PrimitivePart(row: try fixture("part-event-null-data").row)).data, .null)
        XCTAssertNil(try XCTUnwrap(PrimitivePart(row: try fixture("part-event-absent-data").row)).data)
    }

    func testToolInputIsKeptAsTheRoundStoredIt() throws {
        let cases: [(String, JSONValue)] = [
            ("part-tool-call-input-raw-string", .string(#"{"amount": 12.5,"#)),
            ("part-tool-call-input-null", .null),
            ("part-tool-call-input-invalid-object", ["amount": -5, "currency": "USD"]),
        ]
        for (name, input) in cases {
            let part = try XCTUnwrap(PrimitivePart(row: try fixture(name).row))
            guard case let .toolCall(content) = part.content else { return XCTFail("\(name): \(part.content)") }
            XCTAssertEqual(content.state, .outputError, name)
            XCTAssertEqual(content.errorCode, "AGENT_TOOL_ARGUMENTS_INVALID", name)
            XCTAssertNotNil(content.errorText, name)
            XCTAssertEqual(content.input, input, name)
        }
    }

    func testTheQueueDecodesInOrderAndDropsMalformedEntries() throws {
        let full = try XCTUnwrap(PrimitiveSession(row: try fixture("session-full").row))
        XCTAssertEqual(full.queue, [
            PrimitiveQueueEntry(userId: "u_2", messageIds: ["m_3"]),
            PrimitiveQueueEntry(userId: "u_3", messageIds: ["m_4", "m_5"]),
        ])
        let entries = try XCTUnwrap(PrimitiveSession(row: try fixture("session-queue-malformed-entry").row))
        XCTAssertEqual(entries.queue, [
            PrimitiveQueueEntry(userId: "u_2", messageIds: ["m_3"]),
            PrimitiveQueueEntry(userId: "u_6", messageIds: ["m_7"]),
        ])
        XCTAssertEqual(try XCTUnwrap(PrimitiveSession(row: try fixture("session-json-wrong-types").row)).queue, [])
        XCTAssertNil(try XCTUnwrap(PrimitiveSession(row: try fixture("session-json-malformed").row)).queue)
    }

    // MARK: - Edge cases

    func testAToolCallWithNoStateHasNoStateAndAToolStateOnTextIsUnknown() throws {
        let part = try XCTUnwrap(PrimitivePart(row: try fixture("part-tool-call-absent-payloads").row))
        guard case let .toolCall(content) = part.content else { return XCTFail("\(part.content)") }
        XCTAssertNil(content.state)
        let text = try XCTUnwrap(PrimitivePart(row: try fixture("part-text-tool-state").row))
        guard case let .text(t) = text.content else { return XCTFail("\(text.content)") }
        XCTAssertEqual(t.state, .unknown("output-available"))
    }

    func testSchemaVersionTwoDecodesUnchanged() throws {
        let session = try XCTUnwrap(PrimitiveSession(row: try fixture("session-schema-version-2").row))
        XCTAssertEqual(session.schemaVersion, 2)
    }

    func testANumericStringSeqDropsTheRow() throws {
        XCTAssertNil(PrimitiveMessage(row: try fixture("message-seq-numeric-string").row))
    }

    func testRawValueInitMapsEveryKnownValueToItsKnownCase() {
        for status in PrimitiveSessionStatus.known {
            XCTAssertEqual(PrimitiveSessionStatus(rawValue: status.rawValue), status)
            XCTAssertTrue(PrimitiveSessionStatus(rawValue: status.rawValue).isKnown)
        }
        for state in PrimitiveToolCallState.known {
            XCTAssertEqual(PrimitiveToolCallState(rawValue: state.rawValue), state)
        }
        for kind in PrimitivePartKind.known {
            XCTAssertTrue(PrimitivePartKind(rawValue: kind.rawValue).isKnown)
        }
        for kind in PrimitiveAuthorKind.known {
            XCTAssertTrue(PrimitiveAuthorKind(rawValue: kind.rawValue).isKnown)
        }
        XCTAssertEqual(PrimitiveAuthorKind(rawValue: "app"), .app)
        XCTAssertEqual(PrimitiveStepKind(rawValue: "model_call"), .modelCall)
        XCTAssertEqual(PrimitiveStepStatus(rawValue: "failed"), .failed)
        XCTAssertEqual(PrimitiveTextState(rawValue: "done"), .done)
        XCTAssertEqual(PrimitiveAuthorKind(rawValue: "robot"), .unknown("robot"))
    }
}

private extension PrimitiveSessionStatus { var isKnown: Bool { Self.known.contains(self) } }
private extension PrimitiveToolCallState { var isKnown: Bool { Self.known.contains(self) } }
private extension PrimitiveTextState { var isKnown: Bool { Self.known.contains(self) } }
private extension PrimitivePartKind { var isKnown: Bool { Self.known.contains(self) } }
private extension PrimitiveAuthorKind { var isKnown: Bool { Self.known.contains(self) } }
private extension PrimitiveStepKind { var isKnown: Bool { Self.known.contains(self) } }
private extension PrimitiveStepStatus { var isKnown: Bool { Self.known.contains(self) } }
