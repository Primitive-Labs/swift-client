import Foundation
import CryptoKit

/// Manages blob upload/download with queue, caching, and SHA256 hashing.
public final class BlobManager: @unchecked Sendable {
    private let lock = NSLock()
    private let logger: Logger

    // Dependencies (set externally)
    var makeRequest: ((String, String, Any?) async throws -> Any)?
    var makeRawRequest: ((String, String, Data?, [String: String]?) async throws -> (Data, Int))?
    var getApiUrl: (() -> String)?
    var getAppId: (() -> String)?
    var getToken: (() -> String?)?
    var getGlobalAdminAppId: (() -> String)?
    var getCurrentUserId: (() -> String?)?
    weak var emitter: EventEmitter?

    // Upload queue
    private var uploadQueue: [String: UploadTask] = [:]
    private var activeUploads = 0
    private var uploadConcurrency: Int
    private var isPaused = false

    // Memory cache for blobs
    private var memoryBlobs: [String: Data] = [:]

    // Backoff settings
    private let backoffBase: Int = 2000
    private let backoffMax: Int = 60000

    public init(logger: Logger, uploadConcurrency: Int = 2) {
        self.logger = logger.forScope(scope: "blob")
        self.uploadConcurrency = uploadConcurrency
    }

    // MARK: - Upload

    /// Upload a blob immediately
    public func uploadImmediate(
        documentId: String,
        blobId: String,
        data: Data,
        options: BlobUploadSourceOptions = BlobUploadSourceOptions()
    ) async throws -> BlobUploadResult {
        let sha256 = options.sha256Base64 ?? hashSHA256Base64(data)
        let filename = options.filename ?? blobId
        let contentType = options.contentType ?? "application/octet-stream"

        let path = "/documents/\(documentId)/blobs/\(blobId)"
        var headers: [String: String] = [
            "Content-Type": contentType,
            "X-Blob-Filename": filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename,
            "X-Blob-Size": "\(data.count)",
            "X-Blob-Sha256": sha256,
        ]
        if let disposition = options.disposition {
            headers["X-Blob-Disposition"] = disposition.rawValue
        }

        guard let makeRawRequest = makeRawRequest else {
            throw JsBaoError(code: .unavailable, message: "HTTP client not configured")
        }

        let (responseData, status) = try await makeRawRequest("PUT", path, data, headers)

        guard status >= 200 && status < 300 else {
            throw HttpError(status: status, message: "Blob upload failed", body: String(data: responseData, encoding: .utf8))
        }

        let result = BlobUploadResult(
            blobId: blobId,
            numBytes: data.count,
            contentType: contentType,
            bytesTransferred: data.count
        )

        emitter?.emit(.blobsUploadCompleted, BlobUploadCompletedEvent(
            documentId: documentId,
            blobId: blobId,
            numBytes: data.count
        ))

        return result
    }

    /// Upload from source data with queuing
    public func uploadFromSource(
        documentId: String,
        source: Data,
        options: BlobUploadSourceOptions = BlobUploadSourceOptions()
    ) async throws -> BlobUploadResult {
        let blobId = ULID.generate()
        let sha256 = options.sha256Base64 ?? hashSHA256Base64(source)

        // Store in memory cache
        lock.lock()
        memoryBlobs["\(documentId)::\(blobId)"] = source
        lock.unlock()

        // Try immediate upload
        do {
            let result = try await uploadImmediate(
                documentId: documentId,
                blobId: blobId,
                data: source,
                options: BlobUploadSourceOptions(
                    filename: options.filename,
                    contentType: options.contentType,
                    sha256Base64: sha256,
                    disposition: options.disposition
                )
            )
            return result
        } catch {
            // Queue for retry
            let task = UploadTask(
                blobId: blobId,
                documentId: documentId,
                data: source,
                options: options,
                sha256: sha256,
                attempts: 1,
                lastError: error.localizedDescription
            )

            lock.lock()
            uploadQueue[blobId] = task
            lock.unlock()

            emitter?.emit(.blobsUploadFailed, BlobUploadFailedEvent(
                documentId: documentId,
                blobId: blobId,
                error: error.localizedDescription,
                willRetry: true
            ))

            scheduleQueueProcessing()
            throw error
        }
    }

    // MARK: - Download

    /// Build download URL for a blob
    public func downloadUrl(documentId: String, blobId: String, disposition: BlobDisposition? = nil) -> String {
        guard let apiUrl = getApiUrl?(), let appId = getAppId?() else { return "" }
        var url = "\(apiUrl)/app/\(appId)/api/documents/\(documentId)/blobs/\(blobId)/download"
        if let disposition = disposition {
            url += "?disposition=\(disposition.rawValue)"
        }
        return url
    }

    /// Read a blob's content
    public func read(documentId: String, blobId: String, force: Bool = false) async throws -> Data {
        // Check memory cache first
        let cacheKey = "\(documentId)::\(blobId)"
        if !force {
            lock.lock()
            if let cached = memoryBlobs[cacheKey] {
                lock.unlock()
                return cached
            }
            lock.unlock()
        }

        // Download from server
        let url = downloadUrl(documentId: documentId, blobId: blobId, disposition: .inline)
        guard let requestUrl = URL(string: url) else {
            throw JsBaoError(code: .invalidArgument, message: "Invalid blob URL")
        }

        var request = URLRequest(url: requestUrl)
        if let token = getToken?() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let adminAppId = getGlobalAdminAppId?() {
            request.setValue(adminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw HttpError(status: status, message: "Blob download failed")
        }

        // Cache in memory
        lock.lock()
        memoryBlobs[cacheKey] = data
        lock.unlock()

        return data
    }

    /// Prefetch multiple blobs
    public func prefetch(documentId: String, blobIds: [String], concurrency: Int = 2) async {
        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for blobId in blobIds {
                if active >= concurrency {
                    await group.next()
                    active -= 1
                }
                group.addTask {
                    try? await self.read(documentId: documentId, blobId: blobId)
                }
                active += 1
            }
        }
    }

    // MARK: - Queue Management

    public func pauseUpload(_ blobId: String) -> Bool {
        lock.lock()
        guard var task = uploadQueue[blobId] else {
            lock.unlock()
            return false
        }
        task.paused = true
        uploadQueue[blobId] = task
        lock.unlock()
        return true
    }

    public func resumeUpload(_ blobId: String) -> Bool {
        lock.lock()
        guard var task = uploadQueue[blobId] else {
            lock.unlock()
            return false
        }
        task.paused = false
        uploadQueue[blobId] = task
        lock.unlock()
        scheduleQueueProcessing()
        return true
    }

    public func pauseAll() {
        lock.lock()
        isPaused = true
        lock.unlock()
    }

    public func resumeAll() {
        lock.lock()
        isPaused = false
        lock.unlock()
        scheduleQueueProcessing()
    }

    public func setUploadConcurrency(_ value: Int) {
        lock.lock()
        uploadConcurrency = max(1, value)
        lock.unlock()
    }

    public func getUploadConcurrency() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return uploadConcurrency
    }

    public func listUploads() -> [BlobUploadStatus] {
        lock.lock()
        defer { lock.unlock() }
        return uploadQueue.values.map { task in
            BlobUploadStatus(
                blobId: task.blobId,
                documentId: task.documentId,
                status: task.paused ? "paused" : "pending",
                attempts: task.attempts,
                numBytes: task.data.count,
                lastError: task.lastError
            )
        }
    }

    // MARK: - Cleanup

    public func clearCache() {
        lock.lock()
        memoryBlobs.removeAll()
        lock.unlock()
    }

    // MARK: - Private

    private func scheduleQueueProcessing() {
        Task {
            await processQueue()
        }
    }

    private func processQueue() async {
        lock.lock()
        guard !isPaused else {
            lock.unlock()
            return
        }
        let tasks = uploadQueue.values.filter { !$0.paused }
            .sorted(by: { $0.nextAttemptAt < $1.nextAttemptAt })
        let available = uploadConcurrency - activeUploads
        lock.unlock()

        guard available > 0 else { return }

        let now = Date().timeIntervalSince1970
        let toProcess = tasks.prefix(available).filter { $0.nextAttemptAt <= now }

        for task in toProcess {
            lock.lock()
            activeUploads += 1
            lock.unlock()

            do {
                let _ = try await uploadImmediate(
                    documentId: task.documentId,
                    blobId: task.blobId,
                    data: task.data,
                    options: task.options
                )

                lock.lock()
                uploadQueue.removeValue(forKey: task.blobId)
                activeUploads -= 1
                let queueEmpty = uploadQueue.isEmpty
                lock.unlock()

                if queueEmpty {
                    emitter?.emit(.blobsQueueDrained, [:] as [String: Any])
                }
            } catch {
                lock.lock()
                activeUploads -= 1
                if var updatedTask = uploadQueue[task.blobId] {
                    updatedTask.attempts += 1
                    updatedTask.lastError = error.localizedDescription
                    let delay = computeBackoff(attempts: updatedTask.attempts)
                    updatedTask.nextAttemptAt = Date().timeIntervalSince1970 + Double(delay) / 1000.0
                    uploadQueue[task.blobId] = updatedTask
                }
                lock.unlock()

                // Schedule retry
                let delay = computeBackoff(attempts: task.attempts + 1)
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    await self.processQueue()
                }
            }
        }
    }

    private func computeBackoff(attempts: Int) -> Int {
        let delay = Double(backoffBase) * pow(2.0, Double(attempts - 1))
        return min(Int(delay), backoffMax)
    }

    private func hashSHA256Base64(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
    }
}

// MARK: - Supporting Types

struct UploadTask {
    let blobId: String
    let documentId: String
    let data: Data
    let options: BlobUploadSourceOptions
    let sha256: String
    var attempts: Int
    var lastError: String?
    var paused: Bool = false
    var nextAttemptAt: TimeInterval = 0
}

public struct BlobUploadResult: Sendable {
    public let blobId: String
    public let numBytes: Int
    public let contentType: String
    public let bytesTransferred: Int?
}

public struct BlobUploadStatus: Sendable {
    public let blobId: String
    public let documentId: String
    public let status: String
    public let attempts: Int
    public let numBytes: Int
    public let lastError: String?
}

public struct BlobListResult: Sendable, Codable {
    public let items: [BlobInfo]
}

public struct BlobInfo: Sendable, Codable {
    public let blobId: String
    public let filename: String?
    public let contentType: String?
    public let numBytes: Int?
    public let sha256: String?
    public let createdAt: String?
    public let disposition: String?
}

// MARK: - ULID Generator

enum ULID {
    private static let encoding: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generate() -> String {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var chars = [Character](repeating: "0", count: 26)

        // Encode 10-char timestamp (48-bit ms) in Crockford's Base32, big-endian
        var t = now
        for i in stride(from: 9, through: 0, by: -1) {
            chars[i] = encoding[Int(t & 0x1F)]
            t >>= 5
        }

        // Encode 16 chars of randomness
        for i in 10..<26 {
            chars[i] = encoding[Int.random(in: 0..<32)]
        }

        return String(chars)
    }
}
