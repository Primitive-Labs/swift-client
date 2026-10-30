import XCTest
@testable import JsBaoClient

/// #5049 behavior 15 — the session treats `DOCUMENT_DELETED` as a terminal
/// refusal that reports its own code, as js-bao's session does.
///
/// A deleted db3's room releases its subscribers with an `error` frame
/// `DOCUMENT_DELETED`, and the room or the connection refuses any later record
/// frame with it. Whatever frame it answers, the conversation stops: the store
/// is marked `refused`, nothing more is sent, the rows stay readable, and the
/// host hears the open failed with `DOCUMENT_DELETED`.
final class RecordLogSessionDeletedHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func harness() async throws -> H.Fixture {
        let directory = NSTemporaryDirectory() + "/record-log-deleted-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        return try await H.Fixture(provider: provider, clientId: "client-a", fetches: false, timings: H.timings)
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

    private static let deleted: [String: JSONValue] = [
        "type": "error", "code": "DOCUMENT_DELETED", "message": "The document was deleted",
    ]

    func testTheCodeIsAnAccessRefusalOfAnyRecordFrame() {
        for messageType in ["record.open", "record.entries", "record.declare", "record.catchUp"] {
            var frame = Self.deleted
            frame["messageType"] = .string(messageType)
            XCTAssertTrue(RecordLogSession.isAccessRefusal(frame), messageType)
        }
        var other = Self.deleted
        other["messageType"] = "channel.subscribe"
        XCTAssertFalse(RecordLogSession.isAccessRefusal(other))
    }

    func testTheRoomsReleaseIsTerminalReportsTheCodeAndKeepsTheRows() async throws {
        let h = try await harness()
        try h.save("r1", ["t": 1])
        await h.session.start()
        await h.feed(H.opened(lsn: 0))
        await until("open") { h.synced.value == 1 }
        var frame = Self.deleted
        frame["messageType"] = "record.open"
        await h.feed(frame)
        XCTAssertEqual(h.failed.value, ["DOCUMENT_DELETED"])
        XCTAssertEqual(h.marks.permission, RecordLogPermission.refused)
        let sent = (h.of("record.open").count, h.of("record.entries").count)
        _ = try? h.save("r2", ["t": 2])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(h.of("record.open").count, sent.0, "nothing more is sent")
        XCTAssertEqual(h.of("record.entries").count, sent.1, "nothing more is sent")
        XCTAssertNotNil(try h.read("r1"), "the rows stay readable")
    }

    func testTheWorkersRefusalOfAnOpenIsHandledTheSame() async throws {
        let h = try await harness()
        await h.session.start()
        await h.feed(["type": "error", "messageType": "record.open", "code": "DOCUMENT_DELETED", "message": "Access denied to document"])
        XCTAssertEqual(h.failed.value, ["DOCUMENT_DELETED"])
        XCTAssertEqual(h.marks.permission, RecordLogPermission.refused)
    }

    func testAnAccessDeniedRefusalStillReportsAccessDenied() async throws {
        let h = try await harness()
        await h.session.start()
        await h.feed(["type": "error", "messageType": "record.open", "message": "Access denied to document"])
        XCTAssertEqual(h.failed.value, ["ACCESS_DENIED"])
    }
}
