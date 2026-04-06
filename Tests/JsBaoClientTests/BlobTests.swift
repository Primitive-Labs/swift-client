import XCTest
@testable import JsBaoClient

/// Port of tests/client/js-bao-client-blobs.test.ts
final class BlobTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!
    var documentId: String!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-blobs")
        documentId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT)
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    func testUploadListGetDeleteBlob() async throws {
        let blobContext = client.documents.blobs(documentId: documentId)
        let testData = "Hello, blob world!".data(using: .utf8)!

        // Upload
        let uploadResult = try await blobContext.upload(data: testData, options: BlobUploadSourceOptions(
            filename: "test.txt",
            contentType: "text/plain",
            disposition: .attachment
        ))
        let blobId = uploadResult.blobId
        XCTAssertFalse(blobId.isEmpty)

        // List
        let items = try await blobContext.list()
        XCTAssertGreaterThanOrEqual(items.count, 1)
        XCTAssertTrue(items.contains { ($0["blobId"] as? String) == blobId })

        // Get
        let meta = try await blobContext.get(blobId: blobId)
        XCTAssertEqual(meta["blobId"] as? String, blobId)
        XCTAssertEqual(meta["filename"] as? String, "test.txt")

        // Download URL
        let url = blobContext.downloadUrl(blobId: blobId, disposition: .attachment)
        XCTAssertTrue(url.contains("/blobs/\(blobId)/download"))

        // Delete
        let deleteResult = try await blobContext.delete(blobId: blobId)
        XCTAssertEqual(deleteResult["deleted"] as? Bool, true)

        // Verify deleted
        let itemsAfter = try await blobContext.list()
        XCTAssertFalse(itemsAfter.contains { ($0["blobId"] as? String) == blobId })
    }

    func testUploadAndReadBlobData() async throws {
        let blobContext = client.documents.blobs(documentId: documentId)
        let originalData = "This is the blob content to read back".data(using: .utf8)!

        let uploadResult = try await blobContext.upload(data: originalData, options: BlobUploadSourceOptions(
            filename: "readable.txt",
            contentType: "text/plain"
        ))

        // Read the blob data back
        let downloadedData = try await blobContext.read(blobId: uploadResult.blobId)
        XCTAssertEqual(downloadedData, originalData)

        // Cleanup
        _ = try await blobContext.delete(blobId: uploadResult.blobId)
    }

    func testRemovesBlobsWhenDocumentDeleted() async throws {
        // Create a separate document for this test
        let cleanupDocId = try await ctx.createDocument(appId: testApp.appId, jwt: testApp.ownerJWT, title: "Blob Cleanup Doc")
        let blobContext = client.documents.blobs(documentId: cleanupDocId)

        let data = "blob to cleanup".data(using: .utf8)!
        let uploadResult = try await blobContext.upload(data: data, options: BlobUploadSourceOptions(
            filename: "cleanup.txt",
            contentType: "text/plain"
        ))
        XCTAssertFalse(uploadResult.blobId.isEmpty)

        // Delete the document
        _ = try await client.documents.delete(documentId: cleanupDocId)

        // Wait for cleanup
        try await delay(1)

        // Blobs should be gone (or at least the document is inaccessible)
        do {
            let items = try await blobContext.list()
            // If we can still list, blobs should be empty
            XCTAssertTrue(items.isEmpty || !items.contains { ($0["blobId"] as? String) == uploadResult.blobId })
        } catch {
            // Expected: document not found
            let msg = String(describing: error)
            XCTAssertTrue(msg.contains("404") || msg.contains("not found"))
        }
    }
}
