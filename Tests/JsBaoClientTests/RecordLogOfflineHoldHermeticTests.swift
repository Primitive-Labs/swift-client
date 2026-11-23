import XCTest
@testable import JsBaoClient

/// #5447 — Swift keeps its socket across `setNetworkMode(.offline)`, so the
/// room keeps relaying to it. While the client may not use the network, what
/// the room sends waits: the copy changes only once networking is allowed
/// again, in the order the frames came, as the JS client's copy does (its
/// socket closes). Frames still waiting when the socket closes are dropped:
/// the next open catches up from the cursor.
final class RecordLogOfflineHoldHermeticTests: XCTestCase {
    typealias H = RecordLogReceiptHarness

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private func harness() async throws -> H.Fixture {
        let directory = NSTemporaryDirectory() + "/record-log-offline-hold-\(UUID().uuidString)"
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

    /// A session open as this client's writer, the room at log number 0.
    private func live() async throws -> H.Fixture {
        let h = try await harness()
        await h.session.start()
        await h.feed(H.opened(lsn: 0))
        await until("open") { h.synced.value == 1 }
        return h
    }

    func testWhatTheRoomRelaysOfflineWaitsAndAppliesInOrderOnceNetworkingIsAllowed() async throws {
        let h = try await live()
        h.connection.networkingAllowed = false
        await h.feed(H.results([H.result(1, "r1", ["t": 1])]))
        await h.feed(H.results([H.result(2, "r1", ["t": 2])]))
        XCTAssertNil(try h.read("r1"), "offline, the copy does not take what the room relays")
        XCTAssertEqual(h.marks.cursor, 0)

        h.connection.networkingAllowed = true
        await h.session.kick()
        XCTAssertEqual(try h.read("r1")?["t"], .number(2), "both apply, in the order they came")
        XCTAssertEqual(h.marks.cursor, 2)
    }

    func testAFrameHeardOnceNetworkingIsAllowedAppliesAfterTheOnesThatWaited() async throws {
        let h = try await live()
        h.connection.networkingAllowed = false
        await h.feed(H.results([H.result(1, "r1", ["t": 1])]))
        XCTAssertNil(try h.read("r1"))

        // Allowed again, and the room's next frame comes before the kick.
        h.connection.networkingAllowed = true
        await h.feed(H.results([H.result(2, "r1", ["t": 2])]))
        XCTAssertEqual(try h.read("r1")?["t"], .number(2))
        XCTAssertEqual(h.marks.cursor, 2, "no gap: the one that waited applied first")
    }

    /// A listener the first frame tells sets the client offline again, the
    /// next time `Note` changes only (the listener runs inside the replay).
    private func offlineFromTheNextChange(_ h: H.Fixture) {
        let fired = LockedBox(false)
        h.binding.onModelChanged("Note") {
            guard !fired.value else { return }
            fired.value = true
            h.connection.networkingAllowed = false
        }
    }

    func testOfflineAgainFromAReplayedFramesListenerTheRestKeepWaiting() async throws {
        let h = try await live()
        h.connection.networkingAllowed = false
        await h.feed(H.results([H.result(1, "r1", ["t": 1])]))
        await h.feed(H.results([H.result(2, "r1", ["t": 2])]))
        offlineFromTheNextChange(h)

        h.connection.networkingAllowed = true
        await h.session.kick()
        XCTAssertEqual(try h.read("r1")?["t"], .number(1), "offline again from the first, the second waits")
        XCTAssertEqual(h.marks.cursor, 1)

        h.connection.networkingAllowed = true
        await h.session.kick()
        XCTAssertEqual(try h.read("r1")?["t"], .number(2))
        XCTAssertEqual(h.marks.cursor, 2)
    }

    func testOfflineAgainFromAReplayedFramesListenerTheFrameJustHeardWaits() async throws {
        let h = try await live()
        h.connection.networkingAllowed = false
        await h.feed(H.results([H.result(1, "r1", ["t": 1])]))
        offlineFromTheNextChange(h)

        // Allowed again, and the room's next frame comes before the kick.
        h.connection.networkingAllowed = true
        await h.feed(H.results([H.result(2, "r1", ["t": 2])]))
        XCTAssertEqual(try h.read("r1")?["t"], .number(1), "offline again from the one that waited, the new one waits")
        XCTAssertEqual(h.marks.cursor, 1)

        h.connection.networkingAllowed = true
        await h.session.kick()
        XCTAssertEqual(try h.read("r1")?["t"], .number(2))
        XCTAssertEqual(h.marks.cursor, 2)
    }

    func testFramesStillWaitingWhenTheSocketClosesAreDroppedAndTheNextOpenCatchesUp() async throws {
        let h = try await live()
        h.connection.networkingAllowed = false
        await h.feed(H.results([H.result(1, "r1", ["t": 1])]))
        await h.session.disconnected()
        h.connection.networkingAllowed = true
        await h.session.kick()
        XCTAssertNil(try h.read("r1"), "dropped with the socket")
        XCTAssertEqual(h.marks.cursor, 0)

        await h.session.start()
        await h.feed(H.opened(lsn: 1, catchUp: .object([
            "mode": "inline", "rows": [H.row("r1", ["t": 1])], "gone": [], "lsn": 1, "upTo": 1,
        ])))
        await until("open again") { h.synced.value == 2 }
        XCTAssertEqual(try h.read("r1")?["t"], .number(1), "the catch-up carries it")
        XCTAssertEqual(h.marks.cursor, 1)
    }
}
