import XCTest
@testable import JsBaoClient

/// #4943 behavior 9 and edge cases E6 and E12 — `client.db3.blobs(id)` sends
/// what `client.documents.blobs(documentId:)` sends, to the db3 routes.
///
/// Over two recording transports the upload PUT carries the documents
/// context's headers to `/db3/<id>/blobs/<blobId>`; `list`, `get` and
/// `delete` use `/db3/<id>/blobs…` with the twin's query; `downloadUrl` is
/// the db3 download route with the twin's query; ids are encoded once. A
/// queued db3 upload's record names its destination; an unknown destination
/// still reads as a document upload. Request serialization only: the live
/// suites prove what the server answers.
final class Db3BlobsHermeticTests: XCTestCase {

    private func transport() -> RecordingTransport {
        RecordingTransport(responder: { call in
            let json: String
            if call.method == .put {
                json = "{}"
            } else if call.method == .delete {
                json = #"{"deleted":true}"#
            } else if call.path.contains("/blobs?") || call.path.hasSuffix("/blobs") {
                json = #"{"items":[{"blobId":"B1"}],"hasMore":false}"#
            } else {
                json = #"{"blobId":"B1","filename":"a.txt"}"#
            }
            return TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
        })
    }

    private func manager(_ transport: RecordingTransport) -> BlobManager {
        BlobManager(
            logger: createLogger(level: .error, scope: "test"), transport: transport,
            getApiUrl: { "https://api.test" }, getAppId: { "app1" }
        )
    }

    private func db3(_ transport: RecordingTransport, _ db3Id: String = "D1") -> Db3BlobContext {
        Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport, blobManager: manager(transport)).blobs(db3Id)
    }

    private func documents(_ transport: RecordingTransport, _ documentId: String = "D1") -> DocumentBlobContext {
        DocumentBlobContext(documentId: documentId, transport: transport, blobManager: manager(transport))
    }

    // MARK: - Behavior 9

    func testEachRequestIsTheDocumentsRequestOnTheDb3Route() async throws {
        let ours = transport()
        let theirs = transport()
        let blobs = db3(ours)
        let twin = documents(theirs)
        let data = Data("hello, db3".utf8)
        let options = BlobUploadSourceOptions(filename: "hello world.txt", contentType: "text/plain", disposition: .attachment)

        let uploaded = try await blobs.upload(data: data, options: options)
        let twinUploaded = try await twin.upload(data: data, options: options)
        XCTAssertEqual(uploaded.bytesTransferred, data.count)
        XCTAssertEqual(uploaded.numBytes, twinUploaded.numBytes)
        XCTAssertEqual(uploaded.contentType, twinUploaded.contentType)
        _ = try await blobs.list(limit: 5, cursor: "c 1")
        _ = try await twin.list(limit: 5, cursor: "c 1")
        _ = try await blobs.get(blobId: "B1")
        _ = try await twin.get(blobId: "B1")
        let deleted = try await blobs.delete(blobId: "B1")
        _ = try await twin.delete(blobId: "B1")
        XCTAssertTrue(deleted.deleted)

        XCTAssertEqual(ours.calls.count, 4)
        XCTAssertEqual(ours.calls.count, theirs.calls.count)
        let put = ours.calls[0]
        let twinPut = theirs.calls[0]
        XCTAssertEqual(put.method, .put)
        XCTAssertEqual(put.path, "/db3/D1/blobs/\(uploaded.blobId)")
        XCTAssertEqual(twinPut.path, "/documents/D1/blobs/\(twinUploaded.blobId)")
        XCTAssertEqual(put.body, data)
        XCTAssertEqual(put.options?.customHeaders, twinPut.options?.customHeaders, "the same X-Blob-* headers")
        XCTAssertEqual(put.options?.customHeaders["X-Blob-Disposition"], "attachment")
        XCTAssertEqual(put.options?.customHeaders["Content-Type"], "text/plain")
        for (mine, other) in zip(ours.calls.dropFirst(), theirs.calls.dropFirst()) {
            XCTAssertEqual(mine.method, other.method)
            XCTAssertEqual(mine.path, other.path.replacingOccurrences(of: "/documents/", with: "/db3/"))
        }
        XCTAssertEqual(ours.calls.map(\.path).dropFirst(), ["/db3/D1/blobs?limit=5&cursor=c%201", "/db3/D1/blobs/B1", "/db3/D1/blobs/B1"])
    }

    func testTheDownloadUrlIsTheDb3Route() {
        let blobs = db3(transport())
        let twin = documents(transport())
        XCTAssertEqual(blobs.downloadUrl(blobId: "B1"), "https://api.test/app/app1/api/db3/D1/blobs/B1/download")
        let full = blobs.downloadUrl(blobId: "B1", disposition: .attachment, attachmentFilename: "résumé 1.pdf")
        XCTAssertEqual(
            full,
            twin.downloadUrl(blobId: "B1", disposition: .attachment, attachmentFilename: "résumé 1.pdf")
                .replacingOccurrences(of: "/api/documents/", with: "/api/db3/")
        )
        XCTAssertEqual(
            full,
            "https://api.test/app/app1/api/db3/D1/blobs/B1/download?disposition=attachment&attachmentFilename=UTF-8''r%C3%A9sum%C3%A9%201.pdf"
        )
    }

    func testEveryIdIsEncodedOnce() async throws {
        let ours = transport()
        let blobs = db3(ours, "D/1?x")
        _ = try await blobs.get(blobId: "B/1")
        _ = try await blobs.list()
        let uploaded = try await blobs.upload(data: Data("x".utf8))
        XCTAssertEqual(ours.calls.map(\.path), ["/db3/D%2F1%3Fx/blobs/B%2F1", "/db3/D%2F1%3Fx/blobs", "/db3/D%2F1%3Fx/blobs/\(uploaded.blobId)"])
        XCTAssertEqual(blobs.downloadUrl(blobId: "B/1"), "https://api.test/app/app1/api/db3/D%2F1%3Fx/blobs/B%2F1/download")
    }

    // MARK: - E12

    func testADb3ApiWithoutAManagerStillUploadsThroughItsTransport() async throws {
        let ours = transport()
        let api = Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: ours)
        let uploaded = try await api.blobs("D1").upload(data: Data("bytes".utf8))
        XCTAssertEqual(ours.lastCall?.method, .put)
        XCTAssertEqual(ours.lastCall?.path, "/db3/D1/blobs/\(uploaded.blobId)")
    }

    // MARK: - The persisted destination (behavior 13's record, E6)

    func testADb3UploadRecordNamesItsDestinationAndADocumentOneNamesNone() throws {
        let db3Task = UploadTask(
            blobId: "B1", documentId: "D1", data: Data("x".utf8), options: BlobUploadSourceOptions(), sha256: "s",
            attempts: 0, lastError: nil, destination: .db3("D1")
        )
        let documentTask = UploadTask(
            blobId: "B2", documentId: "D1", data: Data("x".utf8), options: BlobUploadSourceOptions(), sha256: "s",
            attempts: 0, lastError: nil
        )
        let encoded = try JSONCoding.decodeData(JSONValue.self, from: JSONEncoder().encode(db3Task.persistedRecord))
        XCTAssertEqual(encoded["destination"], ["kind": "db3", "documentId": "D1"])
        let documentEncoded = try JSONCoding.decodeData(JSONValue.self, from: JSONEncoder().encode(documentTask.persistedRecord))
        XCTAssertNil(documentEncoded["destination"], "a document upload's record is unchanged")

        let restored = UploadTask(restoring: db3Task.persistedRecord, data: Data("x".utf8), userId: "u", generation: 0)
        XCTAssertEqual(restored.destination, .db3("D1"))
    }

    func testAStoredDestinationDecodesByItsKind() throws {
        func decode(_ json: String) throws -> UploadDestination {
            try JSONDecoder().decode(UploadDestination.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"kind":"db3","documentId":"D1"}"#), .db3("D1"))
        XCTAssertEqual(try decode(#"{"kind":"agent-session","sessionId":"S1"}"#), .agentSession("S1"))
        XCTAssertEqual(try decode(#"{"kind":"document","documentId":"D1"}"#), .document)
        XCTAssertEqual(try decode(#"{"kind":"something-later"}"#), .document, "an unknown kind reads as a document upload")
    }
}
