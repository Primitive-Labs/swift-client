import XCTest
@testable import JsBaoClient

/// Live integration coverage for the document-blob `prefetch` (#957 / #1058)
/// and the typed `read(blobId:as:)` variants. Mirrors JS
/// `blobs.prefetch([ids], { concurrency })` semantics: best-effort cache
/// warming, individual failures swallowed.
final class BlobPrefetchTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var documentId: String!
    /// Uploader client — seeds blobs; its cache is irrelevant to the tests.
    var uploader: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-blob-prefetch")
        documentId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)
        uploader = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await uploader?.destroy()
        if let ctx: TestContext = ctx { await ctx.cleanup() }
    }

    private func uploadBlob(_ text: String, filename: String) async throws -> String {
        let result = try await uploader.documents.blobs(documentId: documentId).upload(
            data: text.data(using: .utf8)!,
            options: BlobUploadSourceOptions(filename: filename, contentType: "text/plain")
        )
        return result.blobId
    }

    /// Happy path: `prefetch` warms a FRESH client's local cache. Proof: the
    /// blob is deleted server-side afterwards, and `read` still returns the
    /// bytes (a cache miss would re-download and fail with 404).
    func testPrefetchWarmsLocalCache() async throws {
        let payload = "prefetch me — \(UUID().uuidString)"
        let blobId = try await uploadBlob(payload, filename: "prefetch.txt")

        let reader = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await reader.destroy() } }
        let readerBlobs = reader.documents.blobs(documentId: documentId)

        await readerBlobs.prefetch(blobIds: [blobId])

        // Delete server-side through the UPLOADER (its `delete` only evicts
        // the uploader's own cache) so the reader's next fetch would 404.
        let deleted = try await uploader.documents.blobs(documentId: documentId).delete(blobId: blobId)
        XCTAssertTrue(deleted.deleted)

        let data = try await readerBlobs.read(blobId: blobId)
        XCTAssertEqual(
            String(data: data, encoding: .utf8), payload,
            "read after server-side delete must be served from the prefetch-warmed cache"
        )
    }

    /// Edge: prefetch is best-effort — a nonexistent blobId is swallowed
    /// (no throw; the method isn't even `throws`) and the valid ids in the
    /// same batch are still cached. Also exercises a custom `concurrency`.
    func testPrefetchBestEffortIgnoresMissingIds() async throws {
        let payloadA = "valid blob A — \(UUID().uuidString)"
        let payloadB = "valid blob B — \(UUID().uuidString)"
        let idA = try await uploadBlob(payloadA, filename: "a.txt")
        let idB = try await uploadBlob(payloadB, filename: "b.txt")

        let reader = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
        defer { Task { await reader.destroy() } }
        let readerBlobs = reader.documents.blobs(documentId: documentId)

        await readerBlobs.prefetch(
            blobIds: ["definitely-not-a-blob", idA, idB],
            concurrency: 3
        )

        // Both valid blobs were cached despite the bad id in the batch.
        _ = try await uploader.documents.blobs(documentId: documentId).delete(blobId: idA)
        _ = try await uploader.documents.blobs(documentId: documentId).delete(blobId: idB)

        let dataA = try await readerBlobs.read(blobId: idA)
        let dataB = try await readerBlobs.read(blobId: idB)
        XCTAssertEqual(String(data: dataA, encoding: .utf8), payloadA)
        XCTAssertEqual(String(data: dataB, encoding: .utf8), payloadB)
    }

    /// Typed read variants (#957 companion): `read(blobId:as: String.self)`
    /// decodes UTF-8 text, and the generic `Decodable` overload decodes JSON.
    func testTypedReadVariants() async throws {
        struct Payload: Codable, Equatable { let kind: String; let count: Int }

        let textId = try await uploadBlob("plain text content", filename: "text.txt")
        let jsonId = try await uploadBlob(
            #"{"kind":"swift","count":3}"#,
            filename: "payload.json"
        )

        let blobs = uploader.documents.blobs(documentId: documentId)
        let text = try await blobs.read(blobId: textId, as: String.self)
        XCTAssertEqual(text, "plain text content")

        let decoded = try await blobs.read(blobId: jsonId, as: Payload.self)
        XCTAssertEqual(decoded, Payload(kind: "swift", count: 3))
    }
}
