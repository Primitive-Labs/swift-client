import SwiftUI
import XCTest
@_spi(JsBaoClientUI) @testable import JsBaoClient
@testable import JsBaoClientUI

/// #4968 behaviors 8, 9 and 10 and edge case E7 — `BlobImage` (the
/// `JsBaoClientUI` product) shows a db3 blob the way `blobs.read` reads it.
///
/// The loader behind the view serves the local copy first and otherwise
/// downloads with the client's auth; offline with no local copy it fails
/// `.offline`, and bytes that are not an image fail `.invalidArgument`, both
/// with nothing sent. Downloads are counted at a capturing `URLProtocol` on
/// the manager's `networkSession`, the boundary `read` sends through. A new
/// load identity (client, db3, blob) resets the phase and shows the new
/// result, and a cancelled load publishes nothing. The three initializers
/// compile at the call site with the `AsyncImage` shapes.
@MainActor
final class BlobImageHermeticTests: XCTestCase {

    /// A 1x1 transparent PNG.
    private static let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    )!

    private func transport() -> RecordingTransport {
        RecordingTransport(responder: { _ in
            TransportResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        })
    }

    /// A db3 blob context over a manager whose downloads reach the capture protocol.
    private func blobs(online: Bool = true, token: String = "image-token", db3Id: String = "D1") -> Db3BlobContext {
        BlobDownloadCaptureURLProtocol.reset()
        let transport = transport()
        let manager = BlobManager(
            logger: createLogger(level: .error, scope: "test"), transport: transport,
            getApiUrl: { "https://api.test" }, getAppId: { "app1" }, getToken: { token },
            networkingAllowed: { online }, networkSession: makeCaptureSession()
        )
        return Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport, blobManager: manager).blobs(db3Id)
    }

    private func uploaded(_ data: Data, to blobs: Db3BlobContext) async throws -> String {
        try await blobs.upload(data: data, options: BlobUploadSourceOptions(filename: "dot.png", contentType: "image/png")).blobId
    }

    private func code(_ phase: BlobImagePhase) -> JsBaoErrorCode? {
        (phase.error as? JsBaoError)?.code
    }

    // MARK: - Behavior 8

    func testTheLocalCopyIsShownWithNothingSent() async throws {
        let context = blobs()
        let blobId = try await uploaded(Self.png, to: context)
        BlobDownloadCaptureURLProtocol.reset()

        let loader = BlobImageLoader()
        await loader.load(context, blobId: blobId)
        XCTAssertNotNil(loader.phase.image, "\(String(describing: loader.phase.error))")
        XCTAssertEqual(loader.loadedKey?.blobId, blobId)
        XCTAssertEqual(BlobDownloadCaptureURLProtocol.requests.count, 0)
    }

    func testWithNoLocalCopyItDownloadsOnceWithTheClientsAuth() async throws {
        let context = blobs(token: "image-token")
        BlobDownloadCaptureURLProtocol.configure(status: 200, body: Self.png)

        let loader = BlobImageLoader()
        await loader.load(context, blobId: "B1")
        XCTAssertNotNil(loader.phase.image, "\(String(describing: loader.phase.error))")
        let sent = BlobDownloadCaptureURLProtocol.requests
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.headers["Authorization"], "Bearer image-token")
        XCTAssertEqual(sent.first?.url, context.downloadUrl(blobId: "B1", disposition: .inline))
    }

    // MARK: - Behavior 9

    func testOfflineWithNoLocalCopyFailsOfflineWithNothingSent() async {
        let context = blobs(online: false)
        BlobDownloadCaptureURLProtocol.configure(status: 200, body: Self.png)

        let loader = BlobImageLoader()
        await loader.load(context, blobId: "B1")
        XCTAssertNil(loader.phase.image)
        XCTAssertEqual(code(loader.phase), .offline)
        XCTAssertEqual(BlobDownloadCaptureURLProtocol.requests.count, 0)
    }

    func testBytesThatAreNotAnImageFailInvalidArgumentWithNothingSent() async throws {
        let context = blobs()
        let blobId = try await uploaded(Data("plain text, not a picture".utf8), to: context)
        BlobDownloadCaptureURLProtocol.reset()

        let loader = BlobImageLoader()
        await loader.load(context, blobId: blobId)
        XCTAssertNil(loader.phase.image)
        XCTAssertEqual(code(loader.phase), .invalidArgument)
        XCTAssertEqual(BlobDownloadCaptureURLProtocol.requests.count, 0)
    }

    // MARK: - Behavior 10

    func testTheThreeInitializersHaveTheAsyncImageShapes() {
        let context = blobs()
        let plain = BlobImage(context, blobId: "B1")
        let withPlaceholder = BlobImage(context, blobId: "B1") { image in
            image.resizable()
        } placeholder: {
            ProgressView()
        }
        let phased = BlobImage(context, blobId: "B1") { phase in
            switch phase {
            case .success(let image): image.resizable()
            case .failure: Color.red
            case .empty: ProgressView()
            }
        }
        XCTAssertTrue(type(of: plain) == BlobImage<Image>.self)
        _ = (withPlaceholder, phased)

        let image = Image(systemName: "photo")
        XCTAssertNotNil(BlobImagePhase.success(image).image)
        XCTAssertNil(BlobImagePhase.success(image).error)
        XCTAssertNil(BlobImagePhase.empty.image)
        XCTAssertNil(BlobImagePhase.empty.error)
        let failure = BlobImagePhase.failure(JsBaoError(code: .offline, message: "offline"))
        XCTAssertNil(failure.image)
        XCTAssertEqual(code(failure), .offline)
    }

    // MARK: - E7

    func testANewBlobOverTheSameContextShowsTheNewBlob() async throws {
        let context = blobs()
        let first = try await uploaded(Self.png, to: context)
        let second = try await uploaded(Self.png + Data([0]), to: context)

        let loader = BlobImageLoader()
        await loader.load(context, blobId: first)
        XCTAssertNotNil(loader.phase.image)
        XCTAssertEqual(loader.loadedKey?.blobId, first)
        await loader.load(context, blobId: second)
        XCTAssertNotNil(loader.phase.image)
        XCTAssertEqual(loader.loadedKey?.blobId, second)
    }

    func testTheSameIdsOverAnotherClientShowThatClientsResult() async throws {
        let first = blobs(db3Id: "D1")
        let blobId = try await uploaded(Self.png, to: first)
        let loader = BlobImageLoader()
        await loader.load(first, blobId: blobId)
        XCTAssertNotNil(loader.phase.image)

        // Another client's context for the same db3 and blob: no local copy, offline.
        let second = blobs(online: false, db3Id: "D1")
        XCTAssertNotEqual(second.backingClientIdentity, first.backingClientIdentity)
        await loader.load(second, blobId: blobId)
        XCTAssertNil(loader.phase.image, "the first client's image is not kept")
        XCTAssertEqual(code(loader.phase), .offline)
        XCTAssertEqual(loader.loadedKey, BlobImageLoadKey(second, blobId: blobId))
        XCTAssertNotEqual(BlobImageLoadKey(first, blobId: blobId), BlobImageLoadKey(second, blobId: blobId))
        XCTAssertEqual(BlobDownloadCaptureURLProtocol.requests.count, 0)
    }

    func testACancelledLoadPublishesNothing() async throws {
        let context = blobs()
        let shown = try await uploaded(Self.png, to: context)
        let other = try await uploaded(Data("not a picture".utf8), to: context)
        let loader = BlobImageLoader()
        await loader.load(context, blobId: shown)
        XCTAssertNotNil(loader.phase.image)

        let cancelled = Task { await loader.load(context, blobId: other) }
        cancelled.cancel()
        await cancelled.value
        XCTAssertNotNil(loader.phase.image, "the cancelled load changed nothing")
        XCTAssertEqual(loader.loadedKey?.blobId, shown)
    }
}
