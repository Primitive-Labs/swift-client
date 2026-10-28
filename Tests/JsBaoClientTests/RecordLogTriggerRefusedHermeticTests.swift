import XCTest
@testable import JsBaoClient

/// #4798 behavior 19 — a db3 trigger's refusal in the Swift client: the twin
/// of js-bao's `record-log-client-trigger-refused-4798` suite.
///
/// `JsBaoErrorCode.db3TriggerRefused` is the JS client's `DB3_TRIGGER_REFUSED`
/// verbatim, and a write is handed back under it; `RecordLogRefusal` parses
/// the refusal's `reason` (the refusing trigger's own code), which the
/// handed-back error and the refused event's details carry.
final class RecordLogTriggerRefusedHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func opened() async throws -> H.Fixture {
        let directory = NSTemporaryDirectory() + "/record-log-trigger-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let h = try await H.Fixture(provider: provider, clientId: "client-a", fetches: false, timings: H.timings)
        await h.session.start()
        await h.feed(H.opened(lsn: 0))
        await until("open") { h.synced.value == 1 }
        return h
    }

    private func until(
        _ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for: \(what)", file: file, line: line)
    }

    func testTheCodeIsTheJsClientsStringAndAHandBackCode() {
        XCTAssertEqual(JsBaoErrorCode.db3TriggerRefused.rawValue, "DB3_TRIGGER_REFUSED")
        XCTAssertTrue(RecordLogHandBackCode.all.contains("DB3_TRIGGER_REFUSED"))
    }

    func testARefusalParsesItsReason() {
        let refusal = RecordLogRefusal(json: .object([
            "seq": 3, "code": "DB3_TRIGGER_REFUSED", "scope": "record", "from": 3,
            "records": [.object(["model": "Note", "id": "r1", "from": 3])], "reason": "NOTE_BLOCKED",
        ]))
        XCTAssertEqual(refusal?.reason, "NOTE_BLOCKED")
        XCTAssertNil(RecordLogRefusal(json: .object(["seq": 3, "code": "DOCUMENT_ENTRY_INVALID", "scope": "entry"]))?.reason)
    }

    func testATriggerRefusalHandsBackUnderItsOwnCodeWithItsReason() async throws {
        let h = try await opened()
        let heard = LockedBox<[DocumentWriteRefusedEvent]>([])
        h.binding.setRefusalReporter { event in heard.withValue { $0.append(event) } }
        let mutation = RecordLogMutation(model: "Note", id: "r1", kind: .create, fields: ["status": "blocked"])
        let seq = try h.binding.commit([RecordLogWrite(mutations: [mutation])])[0].seq
        async let acknowledged: Void = h.binding.whenAcknowledged(seq)
        await h.feed([
            "type": "record.refused", "seq": .number(Double(seq)), "code": "DB3_TRIGGER_REFUSED", "scope": "record",
            "from": .number(Double(seq)), "records": [.object(["model": "Note", "id": "r1", "from": .number(Double(seq))])],
            "reason": "NOTE_BLOCKED", "message": "blocked notes are read-only",
        ])
        do {
            try await acknowledged
            XCTFail("the acknowledgement should throw")
        } catch let error as JsBaoError {
            XCTAssertEqual(error.code, .db3TriggerRefused)
            XCTAssertEqual(error.message, "blocked notes are read-only")
            XCTAssertEqual(error.details?["reason"], "NOTE_BLOCKED")
        }
        await until("the refusal event") { !heard.value.isEmpty }
        XCTAssertEqual(heard.value.first?.error.code, .db3TriggerRefused)
        XCTAssertEqual(heard.value.first?.error.details?["reason"], "NOTE_BLOCKED")
        XCTAssertNil(try h.read("r1"))
    }
}
