import XCTest
import YSwift
@testable import JsBaoClient

/// The refusal event and the error codes a format-3 client adds — additive
/// only — and a format-3 open on a real socket (a loopback server): it says
/// `record.open`, never `syncStep1` or a Yjs update, and a
/// `DOCUMENT_FORMAT_UNSUPPORTED` answer fails the waiting open with the typed code.
final class RecordLogEventShapeHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: - Behavior 30

    func testTheOriginalInitializerIsUnchangedAndTheNewOneCarriesWritesAndTheConflictingRecord() {
        // A compile fixture: the four-parameter initializer, referenced as a
        // function value, still has exactly its old compound name and type.
        let original: (String, String, String, JsBaoError) -> DocumentWriteRefusedEvent =
            DocumentWriteRefusedEvent.init(documentId:model:recordId:error:)
        let formatTwo = original("doc", "Note", "n1", JsBaoError(code: .documentOfflineWindowExpired))
        XCTAssertEqual(formatTwo.documentId, "doc")
        XCTAssertEqual(formatTwo.model, "Note")
        XCTAssertEqual(formatTwo.recordId, "n1")
        XCTAssertEqual(formatTwo.error.code, .documentOfflineWindowExpired)
        XCTAssertNil(formatTwo.writes, "nil for a format-2 refusal")
        XCTAssertNil(formatTwo.conflictingRecord)

        let write = RecordLogRefusedWrite(
            model: "Note", recordId: "n1", kind: .create, fields: ["title": "t"], stringSetDeltas: nil, seq: 3
        )
        let formatThree = DocumentWriteRefusedEvent(
            documentId: "doc", model: "Note", recordId: "n1", error: JsBaoError(code: .documentConstraintViolated),
            writes: [write], conflictingRecord: RecordLogRecordKey(model: "Note", id: "winner")
        )
        XCTAssertEqual(formatThree.writes, [write])
        XCTAssertEqual(formatThree.conflictingRecord, RecordLogRecordKey(model: "Note", id: "winner"))
    }

    func testTheErrorCodeEnumEndsWithTheNineRecordLogCodesInOrderWithTheJSStrings() throws {
        let expected: [(JsBaoErrorCode, String)] = [
            (.documentFormatUnsupported, "DOCUMENT_FORMAT_UNSUPPORTED"),
            (.documentConstraintViolated, "DOCUMENT_CONSTRAINT_VIOLATED"),
            (.documentEpochFrozen, "DOCUMENT_EPOCH_FROZEN"),
            (.documentStorePurged, "DOCUMENT_STORE_PURGED"),
            (.documentEpochBudget, "DOCUMENT_EPOCH_BUDGET"),
            (.documentEntryTooLarge, "DOCUMENT_ENTRY_TOO_LARGE"),
            (.documentEntryInvalid, "DOCUMENT_ENTRY_INVALID"),
            (.documentEpochNotOpen, "DOCUMENT_EPOCH_NOT_OPEN"),
            (.writeAccessDenied, "WRITE_ACCESS_DENIED"),
        ]
        for (code, raw) in expected {
            XCTAssertEqual(code.rawValue, raw)
            XCTAssertEqual(JsBaoErrorCode(rawValue: raw), code)
        }
        // Appended, not inserted: they follow every code that existed before,
        // in this order (an inserted case shifts the ordinals of those after it).
        let source = try ClientSourceText.code("Types/Errors.swift")
        let enumBody = try ClientSourceText.slice(source, from: "public enum JsBaoErrorCode", to: "public struct JsBaoError")
        let cases = enumBody.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
            .compactMap { $0.dropFirst("case ".count).split(separator: " ").first.map(String.init) }
        XCTAssertGreaterThan(cases.count, 40)
        // Codes appended after them later are allowed; these nine stay
        // together, in this order.
        let first = try XCTUnwrap(cases.firstIndex(of: "documentFormatUnsupported"))
        XCTAssertEqual(
            Array(cases[first..<min(first + 9, cases.count)]),
            ["documentFormatUnsupported", "documentConstraintViolated", "documentEpochFrozen", "documentStorePurged",
             "documentEpochBudget", "documentEntryTooLarge", "documentEntryInvalid", "documentEpochNotOpen", "writeAccessDenied"]
        )
        XCTAssertLessThan(
            try XCTUnwrap(cases.firstIndex(of: "agentSessionModelNameTaken")), try XCTUnwrap(cases.firstIndex(of: "documentFormatUnsupported"))
        )
    }

    func testThePayloadTableGainsNoTypeAndKeepsTheRefusalEventOnce() {
        let names = allJsBaoEventPayloadTypes.map { String(describing: $0) }
        XCTAssertEqual(names.filter { $0 == "DocumentWriteRefusedEvent" }.count, 1)
        XCTAssertEqual(names.filter { $0.hasPrefix("RecordLog") }, [], "the refusal event keeps its name; no new event type")
    }

    // MARK: - Behavior 32 (the frame) and edge 53 (on the wire)

    private func client(wsUrl: String) async -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "/rl-wire-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: wsUrl,
            appId: "record-log-wire-test-app",
            token: makeTestJwt(userId: "record-log-wire-user"),
            offline: false,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        client.registerModels([PrimitiveSchema(name: "Note", fields: [
            "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string),
        ])])
        return client
    }

    private func wsBase(_ url: URL) -> String {
        let s = url.absoluteString
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    func testAFormatThreeOpenSaysRecordOpenNeverYjsAndAnUnsupportedAnswerFailsIt() async throws {
        let server = try LoopbackWebSocketServer()
        let url = try server.start()
        defer { server.stop() }
        let client = await client(wsUrl: wsBase(url))
        defer { Task { await client.destroy() } }
        try await client.connect()

        let documentId = "rl-wire-\(UUID().uuidString.prefix(8))"
        client.documentManager.createRemoteDocument = { _ in ["documentId": documentId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "wire", localOnly: false, documentFormat: 3
        )
        let frame = """
        {"type":"error","code":"DOCUMENT_FORMAT_UNSUPPORTED","documentId":"\(documentId)","messageType":"record.open",\
        "message":"Document \(documentId) is not served in this format."}
        """
        let answer: @Sendable () async -> Void = { [server, client, documentId, frame] in
            for _ in 0..<600 {
                if server.receivedFrames.contains(where: { $0.contains("\"record.open\"") && $0.contains(documentId) }) {
                    await client.handleWebSocketMessage(frame)
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        Task { await answer() }
        do {
            _ = try await client.openDocument(documentId, options: OpenDocumentOptions(
                waitForLoad: .network, enableNetworkSync: true, availabilityWait: 20
            ))
            XCTFail("the open was answered DOCUMENT_FORMAT_UNSUPPORTED")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .documentFormatUnsupported)
            XCTAssertEqual(error.details?["documentId"], .string(documentId))
        }
        let frames = server.receivedFrames.filter { $0.contains(documentId) }
        XCTAssertTrue(frames.contains { $0.contains("\"record.open\"") && $0.contains("\"documentFormat\":3") })
        XCTAssertFalse(frames.contains { $0.contains("\"syncStep1\"") }, "no syncStep1: \(frames)")
        XCTAssertFalse(frames.contains { $0.contains("\"type\":\"update\"") }, "no Yjs update: \(frames)")
    }
}
