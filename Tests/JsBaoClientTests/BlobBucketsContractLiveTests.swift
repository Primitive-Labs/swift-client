import XCTest
@testable import JsBaoClient

/// #6244 behavior 28 — `BlobBucketsAPI` speaks the db3 blob contract against
/// the dev server (project `blob-api-unification` phase 2).
///
/// `upload` stores under the `blobId` it is given, or a ULID it mints, with
/// the bytes' size and SHA-256: the same bytes again transfer nothing, other
/// bytes throw 409, a non-ULID id throws 400. `getMetadata`, `download` and
/// `list` read the new routes, and `BucketBlobInfo` decodes `createdAt`.
final class BlobBucketsContractLiveTests: XCTestCase {

    private func isULID(_ id: String) -> Bool {
        id.range(of: "^[0-7][0-9A-HJKMNP-TV-Z]{25}$", options: .regularExpression) != nil
    }

    private func status(of call: () async throws -> BucketBlobInfo) async -> Int? {
        do {
            _ = try await call()
            return nil
        } catch let error as HttpError {
            return error.status
        } catch {
            return -1
        }
    }

    func testUploadUnderAnIdRepeatsConflictsAndReadsThroughTheNewRoutes() async throws {
        let ctx = TestContext()
        try await ctx.initialize()
        let live = try RecordLogLiveApp(ctx: ctx, app: try await ctx.createTestApp(name: "swift-bucket-contract-6244"))
        do {
            let owner = try await live.client("owner", models: [])
            let bucket = try await owner.blobBuckets.createBucket(
                params: CreateBlobBucketParams(
                    bucketKey: "swift6244-\(ULID.generate().lowercased())",
                    name: "Swift contract",
                    ttlTier: .permanent,
                    preset: .authenticated
                )
            )
            let blobs = owner.blobBuckets

            let minted = try await blobs.upload(
                bucketIdOrKey: bucket.bucketId, data: Data("minted".utf8), filename: "minted.txt", contentType: "text/plain"
            )
            XCTAssertTrue(isULID(minted.blobId), minted.blobId)
            XCTAssertNotNil(minted.createdAt)
            XCTAssertEqual(minted.bytesTransferred, 6)

            let blobId = ULID.generate()
            let chosen = try await blobs.upload(
                bucketIdOrKey: bucket.bucketId, data: Data("chosen".utf8), filename: "chosen.txt", contentType: "text/plain",
                tags: ["t"], blobId: blobId
            )
            XCTAssertEqual(chosen.blobId, blobId)
            XCTAssertEqual(chosen.bytesTransferred, 6)

            let again = try await blobs.upload(
                bucketIdOrKey: bucket.bucketId, data: Data("chosen".utf8), filename: "chosen.txt", contentType: "text/plain",
                blobId: blobId
            )
            XCTAssertEqual(again.bytesTransferred, 0)
            XCTAssertEqual(again.createdAt, chosen.createdAt)

            let conflict = await status {
                try await blobs.upload(
                    bucketIdOrKey: bucket.bucketId, data: Data("other!".utf8), filename: "chosen.txt", blobId: blobId
                )
            }
            XCTAssertEqual(conflict, 409)
            let badId = await status {
                try await blobs.upload(bucketIdOrKey: bucket.bucketId, data: Data("x".utf8), filename: "x.txt", blobId: "not-a-ulid")
            }
            XCTAssertEqual(badId, 400)

            let meta = try await blobs.getMetadata(bucketIdOrKey: bucket.bucketId, blobId: blobId)
            XCTAssertEqual(meta.blobId, blobId)
            XCTAssertEqual(meta.filename, "chosen.txt")
            XCTAssertEqual(meta.tags, ["t"])
            XCTAssertEqual(meta.createdAt, chosen.createdAt)
            XCTAssertNotNil(meta.etag)

            let bytes = try await blobs.download(bucketIdOrKey: bucket.bucketId, blobId: blobId)
            XCTAssertEqual(String(data: bytes, encoding: .utf8), "chosen")

            let listed = try await blobs.list(bucketIdOrKey: bucket.bucketId, limit: 100)
            let item = listed.items.first { $0.blobId == blobId }
            XCTAssertEqual(item?.createdAt, meta.createdAt)
        } catch {
            await live.destroy()
            await ctx.cleanup()
            throw error
        }
        await live.destroy()
        await ctx.cleanup()
    }
}
