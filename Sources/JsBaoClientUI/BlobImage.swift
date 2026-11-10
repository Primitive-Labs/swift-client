@_spi(JsBaoClientUI) import JsBaoClient
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Where a `BlobImage` load stands, as `AsyncImagePhase` is for `AsyncImage`.
public enum BlobImagePhase {
    /// Not loaded yet, or loading.
    case empty
    /// The blob, decoded as an image.
    case success(Image)
    /// The load failed: the error `read` threw (`JsBaoError` `.offline` with
    /// no local copy while offline, `HttpError` for a refusal), or
    /// `JsBaoError` `.invalidArgument` for bytes that are not an image.
    case failure(any Error)

    /// The image, in the `.success` phase.
    public var image: Image? {
        if case .success(let image) = self { return image }
        return nil
    }

    /// The error, in the `.failure` phase.
    public var error: (any Error)? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

/// A database (db3) blob shown as an image, as `AsyncImage` shows a URL.
///
/// It loads through `blobs.read(blobId:)`, so the request carries the
/// signed-in user's auth, a local copy is shown without a request, and while
/// the client is offline with no local copy the load fails with
/// `JsBaoError` `.offline`. The load restarts when the client, the db3 or the
/// blob changes.
///
/// ```swift
/// BlobImage(client.db3.blobs(db3Id), blobId: blobId) { image in
///     image.resizable().scaledToFit()
/// } placeholder: {
///     ProgressView()
/// }
/// ```
public struct BlobImage<Content: View>: View {
    private let blobs: Db3BlobContext
    private let blobId: String
    private let content: (BlobImagePhase) -> Content
    /// The plain form shows a placeholder of its own until the image loads.
    private let showsPlaceholder: Bool
    @StateObject private var loader = BlobImageLoader()

    /// The image, or a plain placeholder while it loads or when it fails.
    /// - Parameters:
    ///   - blobs: The db3's blobs, `client.db3.blobs(db3Id)`.
    ///   - blobId: The blob.
    public init(_ blobs: Db3BlobContext, blobId: String) where Content == Image {
        self.blobs = blobs
        self.blobId = blobId
        self.content = { phase in phase.image ?? Image(systemName: "photo") }
        self.showsPlaceholder = true
    }

    /// The image through `content`, and `placeholder` while it loads or when it fails.
    /// - Parameters:
    ///   - blobs: The db3's blobs, `client.db3.blobs(db3Id)`.
    ///   - blobId: The blob.
    ///   - content: The view for the loaded image.
    ///   - placeholder: The view until then, and on failure.
    public init<I: View, P: View>(
        _ blobs: Db3BlobContext,
        blobId: String,
        @ViewBuilder content: @escaping (Image) -> I,
        @ViewBuilder placeholder: @escaping () -> P
    ) where Content == _ConditionalContent<I, P> {
        self.blobs = blobs
        self.blobId = blobId
        self.content = { phase in
            Self.conditional(phase.image, content: content, placeholder: placeholder)
        }
        self.showsPlaceholder = false
    }

    /// A view for each phase of the load.
    /// - Parameters:
    ///   - blobs: The db3's blobs, `client.db3.blobs(db3Id)`.
    ///   - blobId: The blob.
    ///   - content: The view for a phase.
    public init(
        _ blobs: Db3BlobContext,
        blobId: String,
        @ViewBuilder content: @escaping (BlobImagePhase) -> Content
    ) {
        self.blobs = blobs
        self.blobId = blobId
        self.content = content
        self.showsPlaceholder = false
    }

    /// The view for the current phase.
    public var body: some View {
        Group {
            if showsPlaceholder, loader.phase.image == nil {
                Color.secondary.opacity(0.15)
            } else {
                content(loader.phase)
            }
        }
        .task(id: BlobImageLoadKey(blobs, blobId: blobId)) { [loader, blobs, blobId] in
            await loader.load(blobs, blobId: blobId)
        }
    }

    @ViewBuilder
    private static func conditional<I: View, P: View>(
        _ image: Image?, content: (Image) -> I, placeholder: () -> P
    ) -> _ConditionalContent<I, P> {
        if let image {
            content(image)
        } else {
            placeholder()
        }
    }
}

/// What a `BlobImage` load is of: the client behind the context, the db3 and
/// the blob. A change of any of them restarts the load.
struct BlobImageLoadKey: Hashable, Sendable {
    let client: ObjectIdentifier
    let db3Id: String
    let blobId: String

    init(_ blobs: Db3BlobContext, blobId: String) {
        client = blobs.backingClientIdentity
        db3Id = blobs.db3Id
        self.blobId = blobId
    }
}

/// Loads a `BlobImage`'s blob and publishes its phase.
@MainActor
final class BlobImageLoader: ObservableObject {
    @Published private(set) var phase: BlobImagePhase = .empty
    /// The load the phase belongs to.
    private(set) var loadedKey: BlobImageLoadKey?

    /// Read the blob and publish the result. A load of a new key shows
    /// `.empty` until it ends; a cancelled load publishes nothing.
    func load(_ blobs: Db3BlobContext, blobId: String) async {
        guard !Task.isCancelled else { return }
        let key = BlobImageLoadKey(blobs, blobId: blobId)
        if key != loadedKey {
            loadedKey = key
            phase = .empty
        }
        let result: BlobImagePhase
        do {
            let data = try await blobs.read(blobId: blobId)
            if let image = Self.image(from: data) {
                result = .success(image)
            } else {
                result = .failure(JsBaoError(code: .invalidArgument, message: "Blob \(blobId) is not an image"))
            }
        } catch {
            result = .failure(error)
        }
        guard !Task.isCancelled, loadedKey == key else { return }
        phase = result
    }

    private static func image(from data: Data) -> Image? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }
}
