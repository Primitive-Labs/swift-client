import XCTest
@testable import JsBaoClient

/// #4806 behavior 17 — the session treats the room's `DB3_SYNC_OFF` as a
/// terminal refusal, as js-bao's session does (#4799).
///
/// A db3 whose sync is off answers every record frame with an `error` frame
/// `DB3_SYNC_OFF`. Whatever frame it answers, the conversation stops: the
/// store is marked `refused`, nothing more is sent, and the host hears the
/// open failed with `DB3_SYNC_OFF`, not the retried arm an unknown code takes.
final class RecordLogSyncOffSessionHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func harness() async throws -> H.Fixture {
        let directory = NSTemporaryDirectory() + "/record-log-sync-off-\(UUID().uuidString)"
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

    private static let syncOff: [String: JSONValue] = [
        "type": "error", "code": "DB3_SYNC_OFF", "message": "This db3's sync is off",
    ]

    func testTheCodeIsAnAccessRefusalOfAnyRecordFrame() {
        for messageType in ["record.open", "record.entries", "record.declare", "record.catchUp"] {
            var frame = Self.syncOff
            frame["messageType"] = .string(messageType)
            XCTAssertTrue(RecordLogSession.isAccessRefusal(frame), messageType)
        }
        var other = Self.syncOff
        other["messageType"] = "channel.subscribe"
        XCTAssertFalse(RecordLogSession.isAccessRefusal(other))
    }

    func testARefusedOpenIsTerminalAndReportsTheCode() async throws {
        let h = try await harness()
        try h.save("r1", ["t": 1])
        await h.session.start()
        XCTAssertEqual(h.of("record.open").count, 1)
        var frame = Self.syncOff
        frame["messageType"] = "record.open"
        await h.feed(frame)
        XCTAssertEqual(h.failed.value, ["DB3_SYNC_OFF"])
        XCTAssertEqual(h.marks.permission, RecordLogPermission.refused)
        // Nothing more is sent, and the unsent write is kept for the room to judge.
        let sent = (h.of("record.open").count, h.of("record.entries").count)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(h.of("record.open").count, sent.0)
        XCTAssertEqual(h.of("record.entries").count, sent.1)
        XCTAssertNotNil(try h.read("r1"))
    }

    func testARefusedEntriesFrameIsHandledTheSame() async throws {
        let h = try await harness()
        await h.session.start()
        await h.feed(H.opened(lsn: 0))
        await until("open") { h.synced.value == 1 }
        try h.save("r2", ["t": 2])
        await until("the entries sent") { !h.of("record.entries").isEmpty }
        var frame = Self.syncOff
        frame["messageType"] = "record.entries"
        await h.feed(frame)
        XCTAssertEqual(h.failed.value, ["DB3_SYNC_OFF"])
        XCTAssertEqual(h.marks.permission, RecordLogPermission.refused)
        let entries = h.of("record.entries").count
        _ = try? h.save("r3", ["t": 3])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(h.of("record.entries").count, entries, "nothing more is sent")
    }

    func testAnAccessDeniedRefusalStillReportsAccessDenied() async throws {
        let h = try await harness()
        await h.session.start()
        await h.feed(["type": "error", "messageType": "record.open", "code": "ACCESS_DENIED"])
        XCTAssertEqual(h.failed.value, ["ACCESS_DENIED"])
        XCTAssertEqual(h.marks.permission, RecordLogPermission.refused)
    }
}
