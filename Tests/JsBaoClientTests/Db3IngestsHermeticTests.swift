import XCTest
@testable import JsBaoClient

/// #4889 behavior 18 and edge case E7 (the Swift half) — `client.db3.ingests`
/// sends what `client.documents.ingests` sends, to the db3 mounts.
///
/// Each call goes to `/db3/<id>/ingest…` with the method, query and body its
/// documents twin sends to `/documents/<id>/ingest…`; the chunk upload's
/// multipart body is the twin's byte for byte once the boundary is named
/// alike; `buildChunks` answers the same chunks; a session id carrying `/`
/// or `?` is encoded once.
final class Db3IngestsHermeticTests: XCTestCase {

    private static let session = #"{"sessionId":"S1","documentId":"D1","state":"uploading","mode":"merge","reserveEpoch":"open","refusedRows":0}"#

    private func transport() -> RecordingTransport {
        RecordingTransport(responder: { call in
            let json: String
            if call.path.hasSuffix("/chunks") {
                json = #"{"ok":true,"bytes":3,"ordinal":0}"#
            } else if call.method == .get && (call.path.hasSuffix("/ingest") || call.path.contains("/ingest?")) {
                json = #"{"items":[],"hasMore":false}"#
            } else {
                json = Self.session
            }
            return TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
        })
    }

    /// A multipart body with its boundary replaced, so two uploads compare.
    private func unbounded(_ call: RecordedRequest?) -> String {
        let text = String(decoding: call?.body ?? Data(), as: UTF8.self)
        let header = call?.options?.customHeaders["Content-Type"] ?? ""
        guard let boundary = header.components(separatedBy: "boundary=").last, !boundary.isEmpty else { return text }
        return text.replacingOccurrences(of: boundary, with: "<boundary>")
    }

    func testEachCallIsTheDocumentsCallOnTheDb3Mount() async throws {
        let ours = transport()
        let theirs = transport()
        let db3 = Db3IngestsAPI(transport: ours)
        let documents = DocumentIngestsAPI(transport: theirs)
        let rows = [
            DocumentIngestRow(model: "Note", id: "n1", patch: ["title": .string("One")]),
            DocumentIngestRow(model: "Note", id: "n2", patch: ["title": .string("Two")]),
        ]
        let chunks = try db3.buildChunks(rows: rows)
        let twinChunks = try documents.buildChunks(rows: rows)
        XCTAssertEqual(chunks.map(\.sha256), twinChunks.map(\.sha256))
        XCTAssertEqual(chunks.map(\.body), twinChunks.map(\.body))

        _ = try await db3.create(db3Id: "D1")
        _ = try await documents.create(documentId: "D1")
        _ = try await db3.create(db3Id: "D1", options: DocumentIngestCreateOptions(mode: .refresh, models: ["Note"]))
        _ = try await documents.create(documentId: "D1", options: DocumentIngestCreateOptions(mode: .refresh, models: ["Note"]))
        _ = try await db3.uploadChunk(db3Id: "D1", sessionId: "S1", chunk: chunks[0])
        _ = try await documents.uploadChunk(documentId: "D1", sessionId: "S1", chunk: chunks[0])
        _ = try await db3.commit(db3Id: "D1", sessionId: "S1")
        _ = try await documents.commit(documentId: "D1", sessionId: "S1")
        _ = try await db3.abort(db3Id: "D1", sessionId: "S1")
        _ = try await documents.abort(documentId: "D1", sessionId: "S1")
        _ = try await db3.get(db3Id: "D1", sessionId: "S1")
        _ = try await documents.get(documentId: "D1", sessionId: "S1")
        _ = try await db3.list(db3Id: "D1", limit: 5, cursor: "c1")
        _ = try await documents.list(documentId: "D1", limit: 5, cursor: "c1")

        XCTAssertEqual(ours.calls.count, theirs.calls.count)
        for (mine, twin) in zip(ours.calls, theirs.calls) {
            XCTAssertEqual(mine.method, twin.method)
            XCTAssertEqual(mine.path, twin.path.replacingOccurrences(of: "/documents/", with: "/db3/"))
            XCTAssertTrue(mine.path.hasPrefix("/db3/D1/ingest"), mine.path)
            if mine.path.hasSuffix("/chunks") {
                XCTAssertEqual(unbounded(mine), unbounded(twin))
                XCTAssertEqual(mine.options?.rawBody, true)
            } else {
                XCTAssertEqual(mine.jsonBody, twin.jsonBody, mine.path)
            }
        }
        XCTAssertNil(ours.calls[0].body, "no options, no body")
        XCTAssertEqual(ours.calls[1].jsonBody, ["mode": "refresh", "models": ["Note"]])
    }

    func testASessionIdIsEncodedOnce() async throws {
        let ours = transport()
        let db3 = Db3IngestsAPI(transport: ours)
        _ = try await db3.get(db3Id: "D 1", sessionId: "a/b?c")
        XCTAssertEqual(ours.lastCall?.path, "/db3/D%201/ingest/a%2Fb%3Fc")
    }

    func testTheClientsDb3NamespaceHasIngests() {
        let api = Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: RecordingTransport(status: 200))
        let _: Db3IngestsAPI = api.ingests
    }
}
