import Foundation
import XCTest
@testable import JsBaoClient

/// What the live `client.db3.blobs` suites (#4943) share: the server's view
/// of a db3's or a document's blobs, an authenticated GET, refusals read as
/// status and code, and the db3 ids the upload events carry.
extension RecordLogLiveApp {
    /// The blob ids the server lists under `path` (`/db3/<id>/blobs` or
    /// `/documents/<id>/blobs`), read as the app owner.
    func serverBlobIds(_ path: String) async throws -> [String] {
        let answer = try await ctx.appRequest(method: "GET", appId: app.appId, path: path, body: nil, jwt: app.ownerJWT)
        return (answer["items"] as? [[String: Any]] ?? []).compactMap { $0["blobId"] as? String }
    }

    /// A GET of `url` with `jwt`, answering the status and the bytes.
    func authenticatedGet(_ url: String, jwt: String) async throws -> (Int, Data) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: url)))
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue(TestConfig.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// A refusal as `(status, serverCode)`; `(nil, nil)` when the call answered.
func db3BlobRefusal(_ body: () async throws -> Void) async -> (Int?, String?) {
    do {
        try await body()
        return (nil, nil)
    } catch let error as HttpError {
        return (error.status, error.serverCode)
    } catch let error as JsBaoError {
        return (-1, error.code.rawValue)
    } catch {
        return (-1, "\(error)")
    }
}

/// The blob events one client emits, with the ids each carries.
final class Db3BlobEventLog: @unchecked Sendable {
    struct Entry: Equatable {
        let kind: String
        let documentId: String
        let blobId: String
        let queueId: String
        let status: String?
        let willRetry: Bool?
    }

    private let entries = LockedBox([Entry]())
    private var subscriptions: [EventSubscription] = []

    init(_ client: JsBaoClient) {
        let entries = self.entries
        let emitter = client.eventEmitter
        subscriptions = [
            emitter.subscribe(BlobUploadProgressEvent.self) { e in
                entries.withValue { $0.append(Entry(kind: "progress", documentId: e.documentId, blobId: e.blobId, queueId: e.queueId, status: e.status, willRetry: nil)) }
            },
            emitter.subscribe(BlobUploadFailedEvent.self) { e in
                entries.withValue { $0.append(Entry(kind: "failed", documentId: e.documentId, blobId: e.blobId, queueId: e.queueId, status: nil, willRetry: e.willRetry)) }
            },
            emitter.subscribe(BlobUploadCompletedEvent.self) { e in
                entries.withValue { $0.append(Entry(kind: "completed", documentId: e.documentId, blobId: e.blobId, queueId: e.queueId, status: nil, willRetry: nil)) }
            },
        ]
    }

    func of(_ blobId: String) -> [Entry] { entries.value.filter { $0.blobId == blobId } }
    func kinds(_ blobId: String) -> [String] { of(blobId).map { $0.status.map { "progress:\($0)" } ?? $0.kind } }
    var all: [Entry] { entries.value }

    func cancel() { subscriptions.forEach { $0.cancel() } }
}
