import SwiftUI
import XCTest
@testable import JsBaoClient
@testable import JsBaoClientUI

/// #4968 behavior 11 — `BlobImage` shows a db3 blob from the dev server.
///
/// A fresh client of a reader, with no local copy, loads a PNG another client
/// uploaded and ends in `.success`; a user with no access to the db3 ends in
/// `.failure` carrying the route's 403.
@MainActor
final class BlobImageLiveTests: XCTestCase {

    /// A 1x1 transparent PNG.
    private static let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    )!

    func testAReaderSeesTheImageAndAStrangerIsRefused() async throws {
        let ctx = TestContext()
        try await ctx.initialize()
        let live = try RecordLogLiveApp(ctx: ctx, app: try await ctx.createTestApp(name: "swift-blob-image-4968"))
        do {
            let owner = try await live.client("owner", models: [])
            let db3Id = try await createdOnServer(owner, title: "Pictures").id
            let blobId = try await owner.db3.blobs(db3Id).upload(
                data: Self.png, options: BlobUploadSourceOptions(filename: "dot.png", contentType: "image/png")
            ).blobId

            let reader = try await ctx.createTestUser(appId: live.app.appId)
            _ = try await owner.db3.permissions(db3Id).set(.user(reader.userId, permission: "reader"))
            let readerClient = try await live.client("reader", models: [], token: reader.jwt)
            let shown = BlobImageLoader()
            await shown.load(readerClient.db3.blobs(db3Id), blobId: blobId)
            XCTAssertNotNil(shown.phase.image, "\(String(describing: shown.phase.error))")

            let stranger = try await ctx.createTestUser(appId: live.app.appId)
            let strangerClient = try await live.client("stranger", models: [], token: stranger.jwt)
            let refused = BlobImageLoader()
            await refused.load(strangerClient.db3.blobs(db3Id), blobId: blobId)
            XCTAssertNil(refused.phase.image)
            XCTAssertEqual((refused.phase.error as? HttpError)?.status, 403, "\(String(describing: refused.phase.error))")
        } catch {
            await live.destroy()
            await ctx.cleanup()
            throw error
        }
        await live.destroy()
        await ctx.cleanup()
    }
}
