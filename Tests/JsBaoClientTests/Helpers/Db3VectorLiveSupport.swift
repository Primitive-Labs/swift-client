import Foundation
import XCTest
@testable import JsBaoClient

/// #5230 — what the live device-vector suites share, the Swift twin of
/// `tests/client/db3-device-vector-shared-model-5229.test.ts`'s helpers: a
/// synced db3 holding notes with 16-d embeddings written over HTTP, an `ann`
/// vector index registered on it, devices subscribed and holding every row,
/// and a recorder of every model request a client sends and every answer it
/// gets, with when (through the client's pass-through observers; nothing is
/// faked).
enum Db3VectorLive {
    static let dims = 16
    static let rows = 1_200
    static let encoding = VectorEncoding(dims: dims, element: .f32)
    static let model = "vec5230_note"
    static let name = "idx_vec_\(model)_embedding"
    static let note = PrimitiveSchema(name: model, fields: [
        "id": FieldDescriptor(type: .id), "title": FieldDescriptor(type: .string), "n": FieldDescriptor(type: .number),
        "embedding": FieldDescriptor(type: .vector, dims: dims, element: .f32),
        "other": FieldDescriptor(type: .vector, dims: dims, element: .f32),
    ])
    static let vectors = Db3VectorTestSupport.clusteredVectors(rows, dims, clusters: 24, seed: 5229)

    /// Note `i`'s id: a ULID of the test's own.
    static func id(_ i: Int) -> String { "01JD5230AAAA" + String(format: "%014d", i) }

    static var ann: [String: Any] { [
        "model": model, "field": "embedding", "kind": "vector", "on": "device", "vector": ["distance": "cos", "index": ["mode": "ann"]],
    ] }

    /// A synced db3 holding `count` notes with embeddings, written over HTTP.
    static func seeded(
        _ live: RecordLogLiveApp, count: Int = rows, vectors: [[Float]] = vectors, embedded: (Int) -> Bool = { _ in true }, other: Bool = false
    ) async throws -> String {
        let id = try await live.db3Written(0, model: model)
        // The model declared as a device's open declares it, so the room knows embedding is a vector field.
        _ = try await live.route(id, "declare", [
            "model": model,
            "declaration": ["fields": ["title": ["type": "string"], "n": ["type": "number"],
                                       "embedding": ["type": "vector", "dims": dims, "element": "f32"],
                                       "other": ["type": "vector", "dims": dims, "element": "f32"]]],
        ])
        func data(_ i: Int) throws -> [String: Any] {
            var row: [String: Any] = ["title": "note \(i)", "n": i]
            guard embedded(i) else { return row }
            let stored = try VectorCodec.encode(vectors[i], encoding: encoding)
            row["embedding"] = stored
            if other { row["other"] = stored }
            return row
        }
        // 100 creates a request (`records/batch`'s cap), eight requests at a time.
        let batches = try stride(from: 0, to: count, by: 100).map { at in
            SendingBox(try (at..<min(count, at + 100)).map { i -> [String: Any] in
                ["model": model, "action": "create", "id": self.id(i), "data": try data(i)]
            })
        }
        let (ctx, appId, jwt) = (live.ctx, live.app.appId, live.app.ownerJWT)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, batch) in batches.enumerated() {
                if index >= 8 { try await group.next() }
                group.addTask {
                    _ = try await ctx.appRequest(
                        method: "POST", appId: appId, path: "/documents/\(id)/records/batch", body: ["operations": batch.value], jwt: jwt
                    )
                }
            }
            try await group.waitForAll()
        }
        return id
    }

    /// Register `body` (the `ann` index by default) on `id`, as its owner.
    @discardableResult
    static func register(_ live: RecordLogLiveApp, _ id: String, _ body: [String: Any] = ann) async throws -> [String: Any] {
        let answer = try await live.ctx.appRequest(method: "POST", appId: live.app.appId, path: "/db3/\(id)/indexes", body: body, jwt: live.app.ownerJWT)
        return try XCTUnwrap(answer["index"] as? [String: Any])
    }

    /// The room's listing of the vector index, over HTTP.
    static func listed(_ live: RecordLogLiveApp, _ id: String) async throws -> [String: Any]? {
        let answer = try await live.ctx.appRequest(method: "GET", appId: live.app.appId, path: "/db3/\(id)/indexes", body: nil, jwt: live.app.ownerJWT)
        return (answer["indexes"] as? [[String: Any]])?.first { $0["name"] as? String == name }
    }

    /// A client subscribed to `id` and ready, holding `count` rows.
    static func device(
        _ live: RecordLogLiveApp, _ id: String, name: String = "device", count: Int = rows, file: String? = nil, token: String? = nil
    ) async throws -> (client: JsBaoClient, subscription: Db3Subscription, traffic: Db3ModelTraffic) {
        let client = try await live.client(name, models: [note], token: token, file: file)
        // Heard from before the subscription, so the open's model requests are heard too.
        let traffic = Db3ModelTraffic(client)
        let subscription = try client.db3.subscribe(id)
        try await subscription.ready()
        try await eventually(timeout: 60, description: "every row on \(name)") {
            (try? client.db3.records(id).count(model)) == count
        }
        return (client, subscription, traffic)
    }

    /// The vector index's local status on `client`.
    static func local(_ client: JsBaoClient, _ id: String) async throws -> Db3LocalIndex? {
        try await client.db3.indexes.local(id).first { $0.name == name }
    }

    static func mode(_ client: JsBaoClient, _ id: String) async -> Db3LocalIndexMode? {
        (try? await local(client, id))?.mode
    }

    /// `$near` for note `i`'s own vector on `client`: the note itself first.
    static func nearest(_ client: JsBaoClient, _ id: String, _ i: Int, k: Int = 10, filter: DocumentFilter? = nil) throws -> [PrimitiveRow] {
        var near: [String: JSONValue] = ["field": "embedding", "vector": .array(vectors[i].map { .number(Double($0)) }), "k": .number(Double(k))]
        if let filter { near["filter"] = .object(filter) }
        return try client.db3.records(id).query(model, ["$near": .object(near)]).data
    }

    /// A model trained by vec1 on a connection of the test's own over `vectors`, in its envelope.
    static func trainedElsewhere(
        _ vectors: [[Float]] = vectors, nbucket: Int = 35, codesize: Int = 16, quantizer: String = "opq", rows: Int = rows
    ) throws -> Data {
        let params = RecordLogVectorModelParams(
            vec1: try Db3VectorTestSupport.vec1Version(), dims: dims, distance: "cos", nbucket: nbucket, codesize: codesize, quantizer: quantizer,
            rows: rows, trainedAt: Db3IndexesAPI.isoDate(Date())
        )
        return RecordLogVectorModelCheck.encode(
            params, model: try Db3VectorTestSupport.trainModel(vectors, distance: "cos", nbucket: nbucket, codesize: codesize, quantizer: quantizer)
        )
    }

    /// A raw request to the model route as `jwt`, answering its status, headers and body.
    static func modelRoute(
        _ live: RecordLogLiveApp, _ id: String, method: String, headers: [String: String] = [:], body: Data? = nil, jwt: String? = nil
    ) async throws -> (status: Int, headers: [String: String], body: Data) {
        let url = try XCTUnwrap(URL(string: "\(TestConfig.httpUrl)/app/\(live.app.appId)/api/db3/\(id)/indexes/\(name)/model"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(jwt ?? live.app.ownerJWT)", forHTTPHeaderField: "Authorization")
        request.setValue(TestConfig.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        var out: [String: String] = [:]
        for (key, value) in http.allHeaderFields { out[String(describing: key)] = String(describing: value) }
        return (http.statusCode, out, data)
    }
}

/// Every model request one client sends and every answer it gets, with when:
/// heard through the client's pass-through observers of its API transport.
final class Db3ModelTraffic: @unchecked Sendable {

    struct Request: Sendable {
        var method: HTTPMethod
        var path: String
        var at: Date
        var bodyBytes: Int
    }

    struct Answer: Sendable {
        var method: HTTPMethod
        var path: String
        var at: Date
        /// The status, or `nil` for a request that got no answer.
        var status: Int?
        var headers: [String: String]
        var body: Data
        var code: String?
        /// Why a request got no answer.
        var failure: String? = nil
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    private var _answers: [Answer] = []
    private var claims: [Date] = []

    init(_ client: JsBaoClient) {
        client.observeTrafficForTest(requests: { [weak self] method, path, body in
            guard let self else { return }
            self.lock.withLock { self._requests.append(Request(method: method, path: path, at: Date(), bodyBytes: body?.count ?? 0)) }
        }, frames: nil)
        client.gatedTransportForTest.observeAnsweredForTest { [weak self] method, path, result in
            guard let self else { return }
            let answer: Answer
            switch result {
            case .success(let response):
                answer = Answer(
                    method: method, path: path, at: Date(), status: response.status, headers: response.headers, body: response.body,
                    code: HttpError.parseBody(response.text).code
                )
            case .failure(let error):
                answer = Answer(method: method, path: path, at: Date(), status: nil, headers: [:], body: Data(), code: nil, failure: "\(error)")
            }
            self.lock.withLock { self._answers.append(answer) }
        }
    }

    /// Every request, in order.
    var requests: [Request] { lock.withLock { _requests } }
    var answers: [Answer] { lock.withLock { _answers } }

    /// The model requests (method only), from `index` on.
    func model(from index: Int = 0) -> [Request] {
        let all = requests
        return Array(all.dropFirst(index)).filter { $0.path.hasSuffix("/indexes/\(Db3VectorLive.name)/model") }
    }

    func modelAnswers(from index: Int = 0) -> [Answer] {
        Array(answers.dropFirst(index)).filter { $0.path.hasSuffix("/indexes/\(Db3VectorLive.name)/model") }
    }

    /// The model requests' methods, from `index` on.
    func methods(from index: Int = 0) -> [String] { model(from: index).map(\.method.rawValue) }
}
