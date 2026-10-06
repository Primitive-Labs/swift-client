import XCTest
@testable import JsBaoClient

/// Server-free tests for #4159: a pending create committed over HTTP emits
/// `PendingCreateCommittedEvent`, as js-bao's `commitOfflineCreate` does on
/// every settled path. Before, only the WebSocket frame handler emitted it, so
/// a create committed without the document open never signalled, and nothing
/// waiting on the commit (`documents.validateAccess`) could hear it.
final class PendingCreateCommitEventHermeticTests: XCTestCase {

    private func makeManager(emitter: EventEmitter) -> DocumentManager {
        let mgr = DocumentManager(logger: Logger(level: .none, scope: "commit-event-test"))
        mgr.appId = "commit-event-test-app"
        mgr.userId = "test-user"
        mgr.emitter = emitter
        return mgr
    }

    private func newDocId() -> String { "doc-\(UUID().uuidString.prefix(8))" }

    private final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func record(_ id: String) { lock.withLock { ids.append(id) } }
        var all: [String] { lock.withLock { ids } }
    }

    private func recordCommits(_ emitter: EventEmitter) -> (Recorded, EventSubscription) {
        let recorded = Recorded()
        let sub = emitter.subscribe(PendingCreateCommittedEvent.self) { recorded.record($0.documentId) }
        return (recorded, sub)
    }

    func testHttpCommitEmitsPendingCreateCommittedOnce() async throws {
        let emitter = EventEmitter()
        let mgr = makeManager(emitter: emitter)
        let docId = newDocId()
        mgr.createRemoteDocument = { _ in ["documentId": docId] }
        let (recorded, sub) = recordCommits(emitter)
        defer { sub.cancel() }

        _ = try await mgr.createLocalDocument(documentId: docId, title: "t", localOnly: false)
        XCTAssertTrue(mgr.isPendingCreate(docId))

        _ = try await mgr.commitOfflineCreate(documentId: docId)

        XCTAssertFalse(mgr.isPendingCreate(docId))
        XCTAssertEqual(recorded.all, [docId])
    }

    func testLinkedCommitEmitsPendingCreateCommittedOnce() async throws {
        let emitter = EventEmitter()
        let mgr = makeManager(emitter: emitter)
        let docId = newDocId()
        mgr.createRemoteDocument = { _ in
            throw HttpError(status: 409, message: "Document already exists")
        }
        let (recorded, sub) = recordCommits(emitter)
        defer { sub.cancel() }

        _ = try await mgr.createLocalDocument(documentId: docId, title: "t", localOnly: false)
        let result = try await mgr.commitOfflineCreate(documentId: docId, onExists: "link")

        XCTAssertEqual(result["linked"] as? Bool, true)
        XCTAssertFalse(mgr.isPendingCreate(docId))
        XCTAssertEqual(recorded.all, [docId])
    }

    func testFailedCommitDoesNotEmitPendingCreateCommitted() async throws {
        let emitter = EventEmitter()
        let mgr = makeManager(emitter: emitter)
        let docId = newDocId()
        mgr.createRemoteDocument = { _ in
            throw HttpError(status: 500, message: "boom")
        }
        let (recorded, sub) = recordCommits(emitter)
        defer { sub.cancel() }

        _ = try await mgr.createLocalDocument(documentId: docId, title: "t", localOnly: false)
        _ = try? await mgr.commitOfflineCreate(documentId: docId)

        XCTAssertTrue(mgr.isPendingCreate(docId))
        XCTAssertEqual(recorded.all, [])
    }
}
