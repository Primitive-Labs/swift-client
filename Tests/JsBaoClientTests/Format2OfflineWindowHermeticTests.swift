import XCTest
@testable import JsBaoClient

/// The offline write window of a large document (#3437, behavior 1, edge E14).
///
/// A format-2 client writes while it is offline: the write lands in the merged
/// view at once and waits in `_pending_ops` for the reconnect that replays it
/// onto whatever epoch the room has reached. What makes that replay
/// RESOLVABLE is the sealed-overlay chain back to the epoch the op was written
/// against — and retention releases an overlay once a base covers it and it is
/// older than the window W. So a client away for longer than W is writing
/// against a past the server can no longer reconcile it with.
///
/// The numbers are js-bao's, not Swift's own: 7 days by default, clamped to
/// 1–14, the same range overlay retention prunes archives by. #3436 shipped 30
/// days unclamped (finding 3437-R01), which would have let a Swift app go on
/// accepting writes for three weeks after the server could no longer place
/// them. Parity is asserted against `offlineWindowStatus` running in node, so
/// the two clients cannot drift on where the boundary falls.
final class Format2OfflineWindowHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directories = []
        super.tearDown()
    }

    private func makeStore() async throws -> Format2RecordStore {
        let directory = NSTemporaryDirectory() + "/f2-window-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "test")
        let store = Format2RecordStore(host: provider, documentId: "d", clientId: "me")
        try store.initialize()
        return store
    }

    private static let dayMs = 24 * 60 * 60 * 1000

    // MARK: - Behavior 1 — the numbers

    func testTheDefaultIsSevenDaysAndTheClampIsOneToFourteen() {
        XCTAssertEqual(Format2OfflineWindow.defaultOfflineWindowDays, 7)
        XCTAssertEqual(Format2OfflineWindow.minOfflineWindowDays, 1)
        XCTAssertEqual(Format2OfflineWindow.maxOfflineWindowDays, 14)

        // Nothing reported is the default, not "no window".
        XCTAssertEqual(Format2OfflineWindow.configuredOfflineWindowDays(nil), 7)
        // Clamped rather than refused: the alternative to a usable number is a
        // client that either never goes read-only or goes read-only at once,
        // and both are worse than a number that is merely not the one someone
        // configured.
        XCTAssertEqual(Format2OfflineWindow.configuredOfflineWindowDays(0), 1)
        XCTAssertEqual(Format2OfflineWindow.configuredOfflineWindowDays(-5), 1)
        XCTAssertEqual(Format2OfflineWindow.configuredOfflineWindowDays(30), 14)
        XCTAssertEqual(Format2OfflineWindow.configuredOfflineWindowDays(7), 7)
        XCTAssertEqual(Format2OfflineWindow.configuredOfflineWindowDays(1), 1)
        XCTAssertEqual(Format2OfflineWindow.configuredOfflineWindowDays(14), 14)
    }

    func testAClientWithNoMarkAndOneWithAFutureMarkAreBothWritable() {
        let now = 1_700_000_000_000

        // No mark: the window measures time since the last sync, and reading
        // "never synced" as "infinitely stale" would strand a freshly loaded
        // document in read-only with no way out of it.
        let never = Format2OfflineWindow.offlineWindowStatus(
            lastSyncAt: nil, windowDays: 7, now: now
        )
        XCTAssertTrue(never.writable)
        XCTAssertNil(never.lastSyncAt)
        XCTAssertEqual(never.overdueMs, 0)

        // A mark in the future — a clock that jumped back — is "just synced".
        // The honest failure direction here is to keep accepting writes.
        let future = Format2OfflineWindow.offlineWindowStatus(
            lastSyncAt: now + 5 * Self.dayMs, windowDays: 7, now: now
        )
        XCTAssertTrue(future.writable)
        XCTAssertEqual(future.overdueMs, 0)
    }

    func testInsideTheWindowIsWritableAndPastItCarriesHowFarPast() {
        let now = 1_700_000_000_000

        let inside = Format2OfflineWindow.offlineWindowStatus(
            lastSyncAt: now - 6 * Self.dayMs, windowDays: 7, now: now
        )
        XCTAssertTrue(inside.writable)
        XCTAssertEqual(inside.overdueMs, 0)
        XCTAssertEqual(inside.windowMs, 7 * Self.dayMs)

        // Exactly at the boundary is still inside it.
        let boundary = Format2OfflineWindow.offlineWindowStatus(
            lastSyncAt: now - 7 * Self.dayMs, windowDays: 7, now: now
        )
        XCTAssertTrue(boundary.writable)

        let past = Format2OfflineWindow.offlineWindowStatus(
            lastSyncAt: now - 10 * Self.dayMs, windowDays: 7, now: now
        )
        XCTAssertFalse(past.writable)
        XCTAssertEqual(past.overdueMs, 3 * Self.dayMs)
        XCTAssertEqual(past.lastSyncAt, now - 10 * Self.dayMs)
        XCTAssertEqual(past.windowDays, 7)
    }

    func testTheRefusalCarriesTheCodeAndWhatItWasMeasuredFrom() {
        let now = 1_700_000_000_000
        let status = Format2OfflineWindow.offlineWindowStatus(
            lastSyncAt: now - 10 * Self.dayMs, windowDays: 7, now: now
        )
        let error = Format2OfflineWindow.expired(documentId: "doc-1", status: status)

        XCTAssertEqual(error.code, .documentOfflineWindowExpired)
        // The JS client's own string, so one runbook covers both clients.
        XCTAssertEqual(error.code.rawValue, "DOCUMENT_OFFLINE_WINDOW_EXPIRED")
        XCTAssertEqual(error.details?["documentId"], .string("doc-1"))
        XCTAssertEqual(
            error.details?["lastSyncAt"], .number(Double(now - 10 * Self.dayMs))
        )
        XCTAssertEqual(error.details?["windowDays"], .number(7))
        XCTAssertEqual(error.details?["overdueMs"], .number(Double(3 * Self.dayMs)))
        // It names the next step, not only the problem (principle 6).
        XCTAssertTrue(
            error.message.contains("readable"),
            "the refusal should say the document still reads: \(error.message)"
        )
    }

    // MARK: - Behavior 1 — what the store answers

    func testTheStoreAnswersSevenWhenNothingWasRecordedAndClampsWhatArrives()
        async throws
    {
        let store = try await makeStore()

        // Nothing recorded yet. #3436 answered 30 here.
        XCTAssertEqual(try store.offlineWindowDays(), 7)

        try store.noteOfflineWindow(30)
        XCTAssertEqual(try store.offlineWindowDays(), 14)

        try store.noteOfflineWindow(0)
        XCTAssertEqual(try store.offlineWindowDays(), 1)

        try store.noteOfflineWindow(10)
        XCTAssertEqual(try store.offlineWindowDays(), 10)

        // `nil` is "the frame said nothing", which must not overwrite what the
        // last frame did say.
        try store.noteOfflineWindow(nil)
        XCTAssertEqual(try store.offlineWindowDays(), 10)
    }

    func testNoteSyncRecordsTheMarkAndClampsTheWindowItCarries() async throws {
        let store = try await makeStore()
        XCTAssertNil(try store.lastSyncAt())

        try store.noteSync(at: 1_700_000_000_000, windowDays: 90)
        XCTAssertEqual(try store.lastSyncAt(), 1_700_000_000_000)
        XCTAssertEqual(try store.offlineWindowDays(), 14)
    }

    // MARK: - Edge E14 — what `epoch.info` reports

    func testTheWindowOnTheHandshakeIsStoredClamped() async throws {
        // 0 → 1 (clamped up), 30 → 14 (clamped down), absent → 7 (the
        // default). A non-integer never survives `frame["x"] as? Int`, so it
        // reaches the store as "the frame said nothing" and the document keeps
        // the default — which is E14's third case.
        for (reported, expected) in [(0, 1), (30, 14), (7, 7), (14, 14), (1, 1)] {
            let store = try await makeStore()
            try store.noteOfflineWindow(reported)
            XCTAssertEqual(
                try store.offlineWindowDays(), expected,
                "a reported window of \(reported) should store \(expected)"
            )
        }

        let fresh = try await makeStore()
        let frame: [String: Any] = ["documentId": "d", "offlineWindowDays": 7.5]
        try fresh.noteOfflineWindow(frame["offlineWindowDays"] as? Int)
        XCTAssertEqual(try fresh.offlineWindowDays(), 7)
    }

    // MARK: - Behavior 1 — parity with js-bao

    /// The boundary itself, against `offlineWindowStatus` running in node.
    ///
    /// A window is a number two clients have to agree about to the
    /// millisecond: one that goes read-only a day early refuses writes it
    /// could have replayed, and one that goes read-only a day late accepts
    /// writes the server cannot place. Parity is asserted over the integer
    /// windows a server can report — the shape of the number the retention
    /// config holds — because the Swift column is INTEGER and a fractional
    /// window is not representable on this side at all.
    func testTheWindowBoundaryAgreesWithJsBao() throws {
        let now = 1_700_000_000_000
        var cases: [[String: Any]] = []
        let marks: [Int?] = [
            nil,
            now,
            now + 5 * Self.dayMs,
            now - 1,
            now - 6 * Self.dayMs,
            now - 7 * Self.dayMs,
            now - 7 * Self.dayMs - 1,
            now - 10 * Self.dayMs,
            now - 400 * Self.dayMs,
        ]
        for days in [nil, 0, 1, 7, 13, 14, 30] as [Int?] {
            for mark in marks {
                var each: [String: Any] = ["now": now]
                if let days { each["windowDays"] = days }
                if let mark { each["lastSyncAt"] = mark }
                cases.append(each)
            }
        }

        let response = try Format2Harness.run([
            "command": "offline-window",
            "cases": cases,
        ])
        let expected = try XCTUnwrap(response["statuses"] as? [[String: Any]])
        XCTAssertEqual(expected.count, cases.count)

        for (index, each) in cases.enumerated() {
            let theirs = expected[index]
            let ours = Format2OfflineWindow.offlineWindowStatus(
                lastSyncAt: each["lastSyncAt"] as? Int,
                windowDays: each["windowDays"] as? Int,
                now: now
            )
            let label = "case \(index): \(each)"
            XCTAssertEqual(ours.writable, theirs["writable"] as? Bool, label)
            XCTAssertEqual(ours.windowDays, theirs["windowDays"] as? Int, label)
            XCTAssertEqual(ours.windowMs, theirs["windowMs"] as? Int, label)
            XCTAssertEqual(ours.overdueMs, theirs["overdueMs"] as? Int, label)
            XCTAssertEqual(ours.lastSyncAt, theirs["lastSyncAt"] as? Int, label)
        }
    }

    func testTheClampAgreesWithJsBao() throws {
        let raws = [0, 1, 2, 7, 13, 14, 15, 30, 365, -1]
        let response = try Format2Harness.run([
            "command": "offline-window",
            "configured": raws,
        ])
        let theirs = try XCTUnwrap(response["configured"] as? [Int])
        XCTAssertEqual(theirs.count, raws.count)
        for (index, raw) in raws.enumerated() {
            XCTAssertEqual(
                Format2OfflineWindow.configuredOfflineWindowDays(raw), theirs[index],
                "a configured window of \(raw)"
            )
        }
    }
}
