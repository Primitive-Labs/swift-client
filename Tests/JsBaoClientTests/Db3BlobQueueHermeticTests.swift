import XCTest
@testable import JsBaoClient

/// #4943 code second opinion (C001, C002) — the db3 family's queue after an
/// offline upload. A db3 upload queued while the network was not allowed is
/// attempted once the network is back even when the network came back while
/// it was being queued, before there was anything for `networkingChanged()`
/// to arm; and a queued db3 upload made with `retainLocal: false` keeps no
/// local copy once it lands (JS `handleUploadSuccess`).
///
/// A `BlobManager` over a `RecordingTransport` with the networking and
/// identity closures the client passes, as `BlobUploadOwnedAttemptHermeticTests`
/// builds it.
final class Db3BlobQueueHermeticTests: XCTestCase {
    private static let bytes = Data("db3 queued bytes".utf8)

    private var managers: [BlobManager] = []

    override func tearDown() async throws {
        for manager in managers { await manager.shutdown() }
        managers = []
    }

    private func manager(
        transport: RecordingTransport, networking: LockedBox<Bool>, events: LockedBox<[any JsBaoEventPayload]>,
        onEmit: @escaping @Sendable (any JsBaoEventPayload) -> Void = { _ in }
    ) -> BlobManager {
        let manager = BlobManager(
            logger: Logger(level: .error, scope: "test"),
            backoffBaseMs: 20,
            backoffMaxMs: 40,
            transport: transport,
            getAppId: { "app1" },
            emit: { payload in
                events.withValue { $0.append(payload) }
                onEmit(payload)
            },
            currentIdentity: { UploadIdentity(token: "token-u-a", userId: "u-a") },
            networkingAllowed: { networking.value }
        )
        managers.append(manager)
        return manager
    }

    private static func accepting() -> RecordingTransport {
        RecordingTransport { _ in
            TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        }
    }

    private static func completed(_ events: LockedBox<[any JsBaoEventPayload]>, _ blobId: String) -> Bool {
        events.value.contains { ($0 as? BlobUploadCompletedEvent)?.blobId == blobId }
    }

    // MARK: - C001

    func testANetworkThatComesBackWhileTheUploadIsQueuedStillRunsIt() async throws {
        let transport = Self.accepting()
        let networking = LockedBox(false)
        let events = LockedBox([any JsBaoEventPayload]())
        // The network comes back once the task is queued and `networkingChanged()`
        // is not called again: the call it made before the task was queued
        // found nothing to arm.
        let manager = manager(transport: transport, networking: networking, events: events) { payload in
            if let progress = payload as? BlobUploadProgressEvent, progress.status == "pending" {
                networking.value = true
            }
        }

        let result = try await manager.uploadFromSource(
            documentId: "D1", source: Self.bytes, options: BlobUploadSourceOptions(), family: .db3
        )
        XCTAssertEqual(result.bytesTransferred, 0, "queued offline")

        try await eventually(timeout: 5, description: "the queued db3 upload lands") {
            Self.completed(events, result.blobId)
        }
        XCTAssertEqual(transport.calls.map(\.path), ["/db3/D1/blobs/\(result.blobId)"])
        let left = await manager.listUploads(documentId: "D1", family: .db3)
        XCTAssertEqual(left.map(\.blobId), [])
    }

    // MARK: - C002

    func testAQueuedDb3UploadWithoutRetainLocalKeepsNoCopyOnceItLands() async throws {
        let transport = Self.accepting()
        let networking = LockedBox(false)
        let events = LockedBox([any JsBaoEventPayload]())
        let manager = manager(transport: transport, networking: networking, events: events)

        let dropped = try await manager.uploadFromSource(
            documentId: "D1", source: Self.bytes, options: BlobUploadSourceOptions(retainLocal: false), family: .db3
        )
        let kept = try await manager.uploadFromSource(
            documentId: "D1", source: Self.bytes, options: BlobUploadSourceOptions(), family: .db3
        )
        XCTAssertEqual(dropped.bytesTransferred, 0)
        var cachedWhileQueued = await manager.hasCachedBytes(documentId: "D1", blobId: dropped.blobId, family: .db3)
        XCTAssertTrue(cachedWhileQueued, "the queued upload's bytes are kept until it lands")

        networking.value = true
        await manager.networkingChanged()
        try await eventually(timeout: 5, description: "both queued db3 uploads land") {
            Self.completed(events, dropped.blobId) && Self.completed(events, kept.blobId)
        }

        cachedWhileQueued = await manager.hasCachedBytes(documentId: "D1", blobId: dropped.blobId, family: .db3)
        XCTAssertFalse(cachedWhileQueued, "retainLocal: false keeps no copy once the upload lands")
        let keptCopy = await manager.hasCachedBytes(documentId: "D1", blobId: kept.blobId, family: .db3)
        XCTAssertTrue(keptCopy, "the default retainLocal keeps the copy")
    }
}
