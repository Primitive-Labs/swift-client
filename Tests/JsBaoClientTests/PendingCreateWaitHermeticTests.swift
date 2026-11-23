import XCTest
@testable import JsBaoClient

/// Server-free tests for the wait `documents.validateAccess` runs on a pending
/// create (#4159): `EventEmitter.waitForPendingCreateCommit`.
///
/// The wait subscribes BEFORE it rechecks the pending state, so a commit that
/// lands between the caller's check and the subscription is not missed. Only
/// the commit settles it successfully; going offline, the timeout and a
/// cancelled task end it, and failure events do not (the client retries).
final class PendingCreateWaitHermeticTests: XCTestCase {

    private static let docId = "doc-wait-4159"

    private static func wait(
        _ emitter: EventEmitter,
        timeout: TimeInterval = 5,
        stillPending: @escaping @Sendable () -> Bool = { true },
        isOffline: @escaping @Sendable () -> Bool = { false }
    ) async throws {
        try await emitter.waitForPendingCreateCommit(
            documentId: Self.docId,
            timeout: timeout,
            stillPending: stillPending,
            isOffline: isOffline
        )
    }

    private func assertPendingCreate(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let error = error as? JsBaoError else {
            return XCTFail("expected JsBaoError, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(error.code, .pendingCreate, file: file, line: line)
        XCTAssertEqual(error.details?["documentId"], .string(Self.docId), file: file, line: line)
    }

    func testReturnsAtOnceWhenTheCreateHasAlreadyCommitted() async throws {
        let emitter = EventEmitter()
        // The commit fired before the wait began: the recheck sees it.
        emitter.emit(PendingCreateCommittedEvent(documentId: Self.docId))

        let started = Date()
        try await Self.wait(emitter, stillPending: { false })
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testResumesOnTheCommitAndIgnoresFailureEvents() async throws {
        let emitter = EventEmitter()
        let fire = Task {
            try await Task.sleep(nanoseconds: 100_000_000)
            emitter.emit(PendingCreateFailedEvent(documentId: Self.docId, error: "transient"))
            emitter.emit(DocumentCreateCommitFailedEvent(documentId: Self.docId, reason: "transient"))
            emitter.emit(PendingCreateCommittedEvent(documentId: "some-other-doc"))
            try await Task.sleep(nanoseconds: 100_000_000)
            emitter.emit(PendingCreateCommittedEvent(documentId: Self.docId))
        }
        defer { fire.cancel() }

        try await Self.wait(emitter)
    }

    func testTimeoutIsReportedAsPendingCreateNotUnavailable() async throws {
        let emitter = EventEmitter()
        do {
            try await Self.wait(emitter, timeout: 0.2)
            XCTFail("expected the wait to time out")
        } catch {
            assertPendingCreate(error)
        }
    }

    func testRejectsAtOnceWhenAlreadyOffline() async throws {
        let emitter = EventEmitter()
        let started = Date()
        do {
            try await Self.wait(emitter, isOffline: { true })
            XCTFail("expected PENDING_CREATE")
        } catch {
            assertPendingCreate(error)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testGoingOfflineDuringTheWaitEndsIt() async throws {
        let emitter = EventEmitter()
        let fire = Task {
            try await Task.sleep(nanoseconds: 100_000_000)
            emitter.emit(NetworkModeEvent(mode: .offline, isOnline: false, reason: "user_set"))
        }
        defer { fire.cancel() }

        let started = Date()
        do {
            try await Self.wait(emitter)
            XCTFail("expected PENDING_CREATE")
        } catch {
            assertPendingCreate(error)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testCancellingTheCallingTaskEndsTheWait() async throws {
        let emitter = EventEmitter()
        let waiter = Task { try await Self.wait(emitter) }
        try await Task.sleep(nanoseconds: 100_000_000)
        waiter.cancel()

        do {
            try await waiter.value
            XCTFail("expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }
}
