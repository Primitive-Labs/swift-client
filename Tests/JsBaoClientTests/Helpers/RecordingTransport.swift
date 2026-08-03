import Foundation
@testable import JsBaoClient

/// One recorded call into `Transport.execute`.
struct RecordedRequest: Sendable {
    let method: HTTPMethod
    let path: String
    let body: Data?
    let options: RequestOptions?

    /// The request body decoded as JSON, for tests that assert wire shape.
    var jsonBody: JSONValue? {
        guard let body = body else { return nil }
        return try? JSONCoding.decodeData(JSONValue.self, from: body)
    }
}

/// A `Transport` that returns scripted bytes and records what it was asked
/// for.
///
/// `Transport` has a single requirement (`execute`), so this fake scripts raw
/// bytes plus a status and inherits the real encode / decode / empty-body /
/// non-2xx policy from the protocol extension — a test fake cannot drift from
/// production semantics.
final class RecordingTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [RecordedRequest] = []
    private let responder: @Sendable (RecordedRequest) async throws -> TransportResponse

    var calls: [RecordedRequest] { lock.withLock { _calls } }
    var lastCall: RecordedRequest? { lock.withLock { _calls.last } }

    init(responder: @escaping @Sendable (RecordedRequest) async throws -> TransportResponse) {
        self.responder = responder
    }

    convenience init(
        status: Int = 200,
        contentType: String? = "application/json",
        body: Data = Data()
    ) {
        self.init(responder: { _ in
            TransportResponse(
                status: status,
                headers: contentType.map { ["Content-Type": $0] } ?? [:],
                body: body
            )
        })
    }

    convenience init(status: Int = 200, json: String) {
        self.init(status: status, body: Data(json.utf8))
    }

    func execute(
        method: HTTPMethod,
        path: String,
        body: Data?,
        options: RequestOptions?
    ) async throws -> TransportResponse {
        let call = RecordedRequest(method: method, path: path, body: body, options: options)
        lock.withLock { _calls.append(call) }
        return try await responder(call)
    }
}
