import CryptoKit
import Foundation
import XCTest
@testable import JsBaoClient

/// One chunk of a bulk load as the ingest route takes it: gzip of
/// `⟨id⟩\t⟨patch JSON⟩` lines, encoded here in Swift (`GzipFixture`, CryptoKit
/// sha256), and its descriptor.
struct RecordLogLoadChunk {
    let model: String
    let index: Int
    let rows: Int
    let bytes: Int
    let rawBytes: Int
    let sha256: String
    let firstId: String
    let lastId: String
    let body: Data

    /// Build one chunk from its lines, in the order given (the room wants them in id order).
    init(model: String, index: Int, lines: [(String, [String: JSONValue])]) {
        let text = lines.map { "\($0.0)\t\(RecordLogJSON.text(.object($0.1)))" }.joined(separator: "\n")
        let raw = Data(text.utf8)
        let body = GzipFixture.gzip(raw)
        self.model = model
        self.index = index
        rows = lines.count
        bytes = body.count
        rawBytes = raw.count
        sha256 = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        firstId = lines.first?.0 ?? ""
        lastId = lines.last?.0 ?? ""
        self.body = body
    }
}

/// `n` ids that sort in order: `\(prefix)00001` … (`digits` wide).
func recordLogIds(_ n: Int, prefix: String = "r", from: Int = 1, digits: Int = 5) -> [String] {
    (0..<n).map { prefix + String(format: "%0\(digits)d", from + $0) }
}

/// The routes of one format-3 document's bulk loads, for one app and caller:
/// the Swift twin of js-bao's `LoadDriver` (`tests/helpers/record-log-load-4310.ts`).
struct RecordLogLoadDriver {
    let ctx: TestContext
    let appId: String
    let documentId: String
    let jwt: String

    private var base: String { "\(TestConfig.httpUrl)/app/\(appId)/api/documents/\(documentId)" }

    /// One app-API request; answers the status and the JSON.
    func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> (status: Int, json: [String: Any]) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: base + path)))
        request.httpMethod = method
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? ["text": String(decoding: data, as: UTF8.self)]
        return (status, json)
    }

    /// Open a session, failing loudly when it is refused; answers its view.
    func open(_ body: [String: Any] = [:]) async throws -> [String: Any] {
        let created = try await request("POST", "/ingest", body: body)
        guard created.status == 201 else { throw TestSetupError("opening an ingest session answered \(created.status): \(created.json)") }
        return created.json
    }

    /// Upload one chunk as the `multipart/form-data` body the route takes,
    /// built by hand as `Format2IngestLiveTests` builds it.
    func upload(_ sessionId: String, _ chunk: RecordLogLoadChunk) async throws -> (status: Int, json: [String: Any]) {
        let boundary = "swift-record-log-\(UUID().uuidString)"
        var payload = Data()
        func append(_ text: String) { payload.append(Data(text.utf8)) }
        let fields: [(String, String)] = [
            ("model", chunk.model), ("index", String(chunk.index)), ("rows", String(chunk.rows)),
            ("bytes", String(chunk.bytes)), ("rawBytes", String(chunk.rawBytes)), ("sha256", chunk.sha256),
            ("firstId", chunk.firstId), ("lastId", chunk.lastId),
        ]
        for (name, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"chunk\"; filename=\"\(chunk.index).ndjson.gz\"\r\n")
        append("Content-Type: application/gzip\r\n\r\n")
        payload.append(chunk.body)
        append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: try XCTUnwrap(URL(string: base + "/ingest/\(sessionId)/chunks")))
        request.httpMethod = "POST"
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? ["text": String(decoding: data, as: UTF8.self)]
        return (status, json)
    }

    func commit(_ sessionId: String) async throws -> (status: Int, json: [String: Any]) {
        try await request("POST", "/ingest/\(sessionId)/commit", body: [:])
    }

    func abort(_ sessionId: String) async throws -> (status: Int, json: [String: Any]) {
        try await request("POST", "/ingest/\(sessionId)/abort", body: [:])
    }

    /// The session's view.
    func view(_ sessionId: String) async throws -> [String: Any] {
        let answer = try await request("GET", "/ingest/\(sessionId)")
        guard answer.status == 200 else { throw TestSetupError("the session's view answered \(answer.status): \(answer.json)") }
        return (answer.json["session"] as? [String: Any]) ?? answer.json
    }

    /// Poll the session until `done(view)`; answers the view.
    @discardableResult
    func until(_ sessionId: String, timeout: TimeInterval = 120, _ done: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Any] = [:]
        while Date() < deadline {
            last = try await view(sessionId)
            if done(last) { return last }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TestSetupError("session \(sessionId) did not get there in \(Int(timeout)) s; last: \(last)")
    }

    /// Open, upload every chunk, commit; answers the committed view.
    func load(_ chunks: [RecordLogLoadChunk], body: [String: Any] = [:]) async throws -> [String: Any] {
        let session = try await open(body)
        let sessionId = try XCTUnwrap(session["sessionId"] as? String)
        for chunk in chunks {
            let stored = try await upload(sessionId, chunk)
            guard stored.status == 200 else { throw TestSetupError("uploading chunk \(chunk.index) answered \(stored.status): \(stored.json)") }
        }
        let committed = try await commit(sessionId)
        guard committed.status == 200 else { throw TestSetupError("committing answered \(committed.status): \(committed.json)") }
        var view = committed.json
        if view["sessionId"] == nil { view["sessionId"] = sessionId }
        return view
    }

    /// How many live records of `model` a server read counts.
    func count(_ model: String) async throws -> Int {
        let answer = try await request("GET", "/records/\(model)/count")
        guard answer.status == 200 else { throw TestSetupError("count answered \(answer.status): \(answer.json)") }
        return (answer.json["count"] as? NSNumber)?.intValue ?? -1
    }

    /// A record as a server read answers it, or `nil`.
    func record(_ model: String, _ id: String) async throws -> [String: Any]? {
        let filter = String(decoding: try JSONSerialization.data(withJSONObject: ["id": id]), as: UTF8.self)
        let encoded = filter.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? filter
        let answer = try await request("GET", "/records/\(model)?filter=\(encoded)&limit=1")
        return (answer.json["items"] as? [[String: Any]])?.first
    }

    /// Save a record through the app API (a server write).
    func save(_ model: String, _ id: String, _ data: [String: Any]) async throws -> Int {
        try await request("POST", "/records/\(model)", body: ["id": id, "data": data]).status
    }

    /// Delete a record through the app API.
    func remove(_ model: String, _ id: String) async throws -> Int {
        try await request("DELETE", "/records/\(model)/\(id)").status
    }

    /// The record room's test route `action`.
    @discardableResult
    func test(_ action: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        try await ctx.documentTestRoute(appId: appId, documentId: documentId, action: action, body: body)
    }
}
