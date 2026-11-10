import Foundation

/// A db3 vector index's shared ANN model over HTTP (#5230), the Swift port of
/// the JS client's `db3IndexModels.ts`: `PUT|GET|DELETE
/// db3/:db3Id/indexes/:name/model` with the `X-Index-Model-*` headers the
/// model travels with. A claim (no body) comes before a device trains, a
/// renewal keeps it while the training runs, an upload stores the bytes
/// under it, and a release gives it back when the training failed; an app's
/// own upload claims, stores and commits in one request. Bytes travel as
/// they are: the server never reads them.
///
/// Every request goes through `Transport.execute` with `rawBody`, keeping the
/// response's headers: a fetched model's generation, revision, rows,
/// trainedAt and format are the `GET` answer's headers, and its body's
/// length is checked against `Content-Length`. A refusal is the route's
/// `HttpError` (its `serverCode` the server's code, its `body` the envelope
/// with `details`); a failure to reach the server is the transport's error.
struct Db3IndexModelHttp: Sendable {

    /// The headers a model travels with.
    enum Header {
        static let generation = "X-Index-Model-Generation"
        static let revision = "X-Index-Model-Revision"
        static let rows = "X-Index-Model-Rows"
        static let trainedAt = "X-Index-Model-Trained-At"
        static let format = "X-Index-Model-Format"
        static let claim = "X-Index-Model-Claim"
    }

    /// A model as `GET …/model` answers it, read from its headers.
    struct Fetched: Sendable {
        var bytes: Data
        var generation: Int
        var revision: Int
        var rows: Int
        var trainedAt: String
        var format: String
    }

    /// A claim on a model's upload, as the server answers it.
    struct Claim: Sendable {
        /// What the upload is sent under.
        var token: String
        /// The revision the model is stored under.
        var revision: Int
        /// When the claim lapses unless renewed (ms since the epoch).
        var expiresAt: Int64
    }

    /// The metadata an upload carries in its headers.
    struct Metadata: Sendable {
        var generation: Int
        /// The revision the uploader saw listed.
        var revision: Int
        var rows: Int
        var trainedAt: String
        var format: String
    }

    /// A response whose metadata or body length is not what the route sends:
    /// a network-class failure, asked again on the backoff, never a guess.
    struct Malformed: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    let transport: any Transport
    /// How long a request may take (`nil`: the transport's own).
    var timeout: TimeInterval? = nil

    static func path(_ db3Id: String, _ name: String) -> String {
        "/db3/\(URLEncoding.encodeComponent(db3Id))/indexes/\(URLEncoding.encodeComponent(name))/model"
    }

    /// One request; a non-2xx answer is the route's `HttpError`.
    private func send(_ method: HTTPMethod, _ db3Id: String, _ name: String, headers: [String: String], body: Data? = nil) async throws -> TransportResponse {
        let response = try await transport.execute(
            method: method, path: Self.path(db3Id, name), body: body,
            options: RequestOptions(rawBody: true, customHeaders: headers, timeout: timeout)
        )
        guard response.ok else {
            throw HttpError.fromBytes(status: response.status, message: "the \(method.rawValue) of \(name)'s model was refused", body: response.body)
        }
        return response
    }

    /// Read the model (`GET`): its bytes, and the metadata its headers carry.
    func fetch(_ db3Id: String, _ name: String) async throws -> Fetched {
        let response = try await send(.get, db3Id, name, headers: [:])
        if let declared = response.header("Content-Length").flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), declared != response.body.count {
            throw Malformed(message: "the model's body ended after \(response.body.count) of \(declared) bytes")
        }
        let int = { (header: String) throws -> Int in
            guard let value = response.header(header).flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
                throw Malformed(message: "the model's answer carries no \(header)")
            }
            return value
        }
        guard let trainedAt = response.header(Header.trainedAt), let format = response.header(Header.format) else {
            throw Malformed(message: "the model's answer carries no \(Header.trainedAt) or \(Header.format)")
        }
        return Fetched(
            bytes: response.body, generation: try int(Header.generation), revision: try int(Header.revision), rows: try int(Header.rows),
            trainedAt: trainedAt, format: format
        )
    }

    /// Claim the upload (`request`) or renew `token`'s claim: a `PUT` with no body.
    func claim(_ db3Id: String, _ name: String, generation: Int, revision: Int, token: String? = nil) async throws -> (index: JSONValue, claim: Claim) {
        let response = try await send(.put, db3Id, name, headers: [
            "Content-Type": "application/octet-stream", Header.generation: String(generation), Header.revision: String(revision),
            Header.claim: token ?? "request",
        ], body: Data())
        let answer = JSONValue(jsonText: response.text ?? "") ?? .null
        guard let claim = answer["claim"], let token = claim["token"]?.stringValue, let revision = RecordLogVectorIndex.integer(claim["revision"]) else {
            throw Malformed(message: "the claim's answer names no claim")
        }
        return (answer["index"] ?? .null, Claim(token: token, revision: revision, expiresAt: Int64(claim["expiresAt"]?.numberValue ?? 0)))
    }

    /// Upload `bytes` (`PUT`): under `token`'s claim, or claimed, stored and committed in one request without one.
    func upload(_ db3Id: String, _ name: String, bytes: Data, _ metadata: Metadata, token: String? = nil) async throws -> JSONValue {
        var headers = [
            "Content-Type": "application/octet-stream", Header.generation: String(metadata.generation), Header.revision: String(metadata.revision),
            Header.rows: String(metadata.rows), Header.trainedAt: metadata.trainedAt, Header.format: metadata.format,
        ]
        if let token { headers[Header.claim] = token }
        let response = try await send(.put, db3Id, name, headers: headers, body: bytes)
        return (JSONValue(jsonText: response.text ?? "") ?? .null)["index"] ?? .null
    }

    /// Give `token`'s claim back (`DELETE` naming it): the training it was for ended without a model.
    func release(_ db3Id: String, _ name: String, token: String) async throws {
        _ = try await send(.delete, db3Id, name, headers: [Header.claim: token])
    }

    /// Delete the model (`DELETE`, the db3's owner): answers the index's new revision.
    func delete(_ db3Id: String, _ name: String) async throws -> (ok: Bool, name: String, revision: Int) {
        let response = try await send(.delete, db3Id, name, headers: [:])
        let answer = JSONValue(jsonText: response.text ?? "") ?? .null
        return (answer["ok"]?.boolValue ?? true, answer["name"]?.stringValue ?? name, RecordLogVectorIndex.integer(answer["revision"]) ?? 0)
    }

    /// A refusal's server code, or `nil` for a failure to reach the server.
    static func code(_ error: Error) -> String? { (error as? HttpError)?.serverCode }

    /// A refusal's `details`, from its envelope.
    static func details(_ error: Error) -> [String: JSONValue] {
        guard let body = (error as? HttpError)?.body, let envelope = JSONValue(jsonText: body) else { return [:] }
        return envelope["details"]?.objectValue ?? [:]
    }

    /// A failure asked again on the backoff: no answer from the server, a 5xx, a timeout or a rate limit.
    static func retryable(_ error: Error) -> Bool {
        guard let status = (error as? HttpError)?.status else { return !isOffline(error) }
        return status >= 500 || status == 408 || status == 429
    }

    /// The client's own refusal while networking is not allowed: the loop runs again when it is.
    static func isOffline(_ error: Error) -> Bool { (error as? JsBaoError)?.code == .offline }
}
