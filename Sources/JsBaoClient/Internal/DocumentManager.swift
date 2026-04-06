import Foundation
import YSwift

/// Tracks per-document awareness (presence) state for local and remote clients.
public struct AwarenessEntry: @unchecked Sendable {
    public var localState: [String: Any]?
    public var remoteStates: [String: [String: Any]] = [:]
}

/// Manages document lifecycle, Yjs sync protocol, metadata, and pending creates.
public final class DocumentManager: @unchecked Sendable {
    private let lock = NSLock()
    private let logger: Logger

    // Open documents
    private var openDocs: [String: YDocument] = [:]
    private var docSyncStates: [String: Bool] = [:]
    private var docPermissions: [String: DocumentPermission] = [:]
    private var docOpenStartTime: [String: CFAbsoluteTime] = [:]
    private var docServerBytes: [String: Int] = [:]

    // Yjs persistence (SQLite-backed, replacing y-indexeddb)
    private var docPersistence: [String: YjsSQLitePersistence] = [:]

    // Metadata
    private var metadataIndex: [String: LocalMetadataEntry] = [:]

    // Pending creates
    private var pendingCreates: Set<String> = []
    private var pendingCreateRetryTimers: [String: Task<Void, Never>] = [:]
    private var localOnlyDocs: Set<String> = []

    // Awareness state per document
    private var docAwareness: [String: AwarenessEntry] = [:]

    // Sync protocol state
    private var syncProtocols: [String: YProtocol] = [:]

    // Update observers (one per open document)
    private var updateSubscriptions: [String: YSubscription] = [:]
    // Flag to suppress update observer during remote update application
    private var applyingRemoteUpdate: [String: Bool] = [:]

    // Dependencies (set externally)
    var offlineStore: OfflineStore?
    var appId: String = ""
    var userId: String = ""
    weak var emitter: EventEmitter?
    var sendWebSocketMessage: ((String) async throws -> Void)?
    var onLocalUpdate: ((String, [UInt8]) -> Void)?
    var fetchDocumentInfo: ((String) async throws -> DocumentInfo)?
    var createRemoteDocument: (([String: Any]) async throws -> [String: Any])?
    var commitRetryBackoff: CommitRetryBackoff = CommitRetryBackoff()

    public init(logger: Logger) {
        self.logger = logger.forScope(scope: "docMgr")
    }

    // MARK: - Document Lifecycle

    /// Open a document, restoring from local persistence if available
    public func openDocument(
        documentId: String,
        options: OpenDocumentOptions
    ) async throws -> YDocument {
        lock.lock()
        if let existing = openDocs[documentId] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let doc = YDocument()
        let startTime = CFAbsoluteTimeGetCurrent()

        lock.lock()
        openDocs[documentId] = doc
        docOpenStartTime[documentId] = startTime
        docSyncStates[documentId] = false
        docAwareness[documentId] = AwarenessEntry()
        lock.unlock()

        // Create sync protocol for this document
        let syncProtocol = YProtocol(document: doc)
        lock.lock()
        syncProtocols[documentId] = syncProtocol
        lock.unlock()

        // Restore from local persistence if offline enabled
        if let offlineStore = offlineStore {
            if let persistence = docPersistence[documentId] {
                let data = try await persistence.loadDocument()
                if let data = data, !data.isEmpty {
                    doc.transactSync { txn in
                        // Apply stored update
                    }
                    let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                    emitter?.emit(.documentLoaded, DocumentLoadedEvent(
                        documentId: documentId,
                        source: "sqlite",
                        hadData: true,
                        bytes: data.count,
                        elapsedMs: elapsed
                    ))
                }
            }
        }

        // Load metadata
        if let metadata = try? await offlineStore?.getMetadata(appId: appId, userId: userId, documentId: documentId) {
            lock.lock()
            metadataIndex[documentId] = metadata
            if let permStr = metadata.permission, let perm = DocumentPermission(rawValue: permStr) {
                docPermissions[documentId] = perm
            }
            lock.unlock()
        }

        // Register update observer — equivalent to JS `doc.on("update", handler)`.
        // This captures ALL writes and forwards local ones for WebSocket sync.
        let docId = documentId
        let subscription = doc.observeUpdate { [weak self] update in
            guard let self = self else { return }
            // Skip if we're applying a remote update (server sync)
            self.lock.lock()
            let isRemote = self.applyingRemoteUpdate[docId] == true
            self.lock.unlock()
            if !isRemote {
                self.onLocalUpdate?(docId, update)
            }
        }
        lock.lock()
        updateSubscriptions[documentId] = subscription
        lock.unlock()

        return doc
    }

    /// Close a document and optionally evict local data
    public func closeDocument(documentId: String, options: CloseDocumentOptions = CloseDocumentOptions()) async {
        lock.lock()
        let doc = openDocs.removeValue(forKey: documentId)
        docSyncStates.removeValue(forKey: documentId)
        docOpenStartTime.removeValue(forKey: documentId)
        docServerBytes.removeValue(forKey: documentId)
        syncProtocols.removeValue(forKey: documentId)
        updateSubscriptions.removeValue(forKey: documentId)?.cancel()
        docAwareness.removeValue(forKey: documentId)
        lock.unlock()

        if options.evictLocal {
            await evictLocalData(documentId: documentId)
        }

        emitter?.emit(.documentClosed, DocumentClosedEvent(documentId: documentId))
    }

    // MARK: - Sync Protocol

    /// Generate syncStep1 message (state vector) for a document
    public func buildSyncStep1Message(documentId: String) -> String? {
        lock.lock()
        guard let doc = openDocs[documentId] else {
            lock.unlock()
            return nil
        }
        let syncProto = syncProtocols[documentId]
        lock.unlock()

        guard let syncProto = syncProto else { return nil }

        let step1 = syncProto.handleConnectionStarted()
        let base64 = Data(step1.buffer).base64EncodedString()

        let message: [String: Any] = [
            "type": "syncStep1",
            "documentId": documentId,
            "stateVector": base64,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        return jsonString
    }

    /// Build a syncStep2 response message given the server's state vector.
    /// This sends the client's diff back to the server so it gets any data we have that it doesn't.
    public func buildSyncStep2Response(documentId: String, serverStateVectorBase64: String) -> String? {
        lock.lock()
        guard let doc = openDocs[documentId] else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        guard let svData = Data(base64Encoded: serverStateVectorBase64) else { return nil }
        let serverSV = [UInt8](svData)

        // Compute the diff: what we have that the server doesn't
        var clientUpdate: [UInt8] = []
        doc.transactSync { [self] txn in
            do {
                clientUpdate = try txn.transactionEncodeStateAsUpdateFromSv(stateVector: serverSV)
            } catch {
                self.logger.warn("Failed to encode diff for syncStep2 response:", documentId, error.localizedDescription)
            }
        }

        guard !clientUpdate.isEmpty else { return nil }

        let updateB64 = Data(clientUpdate).base64EncodedString()
        let message: [String: Any] = [
            "type": "syncStep2",
            "documentId": documentId,
            "update": updateB64,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        return jsonString
    }

    /// Handle syncStep2 response from server
    public func handleSyncStep2(documentId: String, updateBase64: String) {
        lock.lock()
        guard let doc = openDocs[documentId] else {
            lock.unlock()
            return
        }
        applyingRemoteUpdate[documentId] = true
        lock.unlock()

        guard let updateData = Data(base64Encoded: updateBase64) else {
            logger.warn("Invalid base64 in syncStep2 for doc:", documentId)
            lock.lock()
            applyingRemoteUpdate[documentId] = false
            lock.unlock()
            return
        }

        let updateBytes = [UInt8](updateData)
        doc.transactSync { [self] txn in
            do {
                try txn.transactionApplyUpdate(update: updateBytes)
                self.logger.debug("SyncStep2 applied for doc:", documentId)
            } catch {
                self.logger.warn("Failed to apply syncStep2 for doc:", documentId, error.localizedDescription)
            }
        }

        lock.lock()
        applyingRemoteUpdate[documentId] = false
        lock.unlock()

        let bytes = updateData.count
        lock.lock()
        docServerBytes[documentId] = (docServerBytes[documentId] ?? 0) + bytes
        lock.unlock()
    }

    /// Handle an incremental update from server
    public func handleUpdate(documentId: String, updateBase64: String) {
        lock.lock()
        guard let doc = openDocs[documentId] else {
            lock.unlock()
            return
        }
        applyingRemoteUpdate[documentId] = true
        lock.unlock()

        guard let updateData = Data(base64Encoded: updateBase64) else {
            logger.warn("Invalid base64 in update for doc:", documentId)
            lock.lock()
            applyingRemoteUpdate[documentId] = false
            lock.unlock()
            return
        }

        let updateBytes = [UInt8](updateData)
        doc.transactSync { [self] txn in
            do {
                try txn.transactionApplyUpdate(update: updateBytes)
                self.logger.debug("Update applied for doc:", documentId)
            } catch {
                self.logger.warn("Failed to apply update for doc:", documentId, error.localizedDescription)
            }
        }

        lock.lock()
        applyingRemoteUpdate[documentId] = false
        lock.unlock()
    }

    /// Handle syncComplete message
    public func handleSyncComplete(documentId: String) {
        lock.lock()
        docSyncStates[documentId] = true
        let startTime = docOpenStartTime[documentId]
        let bytes = docServerBytes[documentId]
        lock.unlock()

        let elapsed = startTime.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000 } ?? 0

        emitter?.emit(.documentLoaded, DocumentLoadedEvent(
            documentId: documentId,
            source: "server",
            hadData: (bytes ?? 0) > 0,
            bytes: bytes,
            elapsedMs: elapsed
        ))

        emitter?.emit(.sync, SyncEvent(documentId: documentId, synced: true))

        // Persist to local storage
        Task { [weak self] in
            guard let self = self else { return }
            await self.persistDocumentToLocal(documentId: documentId)

            // Also persist metadata so hasLocalCopy works across sessions
            if self.offlineStore != nil {
                self.lock.lock()
                var entry = self.metadataIndex[documentId] ?? LocalMetadataEntry(documentId: documentId)
                entry.metadataSyncedAt = ISO8601DateFormatter().string(from: Date())
                self.metadataIndex[documentId] = entry
                self.lock.unlock()
                try? await self.offlineStore?.putMetadata(appId: self.appId, userId: self.userId, record: entry)
            }
        }
    }

    /// Send a local update to the server
    public func sendLocalUpdate(documentId: String, update: [UInt8]) async {
        let base64 = Data(update).base64EncodedString()
        let message: [String: Any] = [
            "type": "update",
            "documentId": documentId,
            "update": base64,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        do {
            try await sendWebSocketMessage?(jsonString)
        } catch {
            logger.warn("Failed to send update for doc:", documentId, error.localizedDescription)
        }
    }

    // MARK: - Document State

    public func getDocument(_ documentId: String) -> YDocument? {
        lock.lock()
        defer { lock.unlock() }
        return openDocs[documentId]
    }

    public func isSynced(_ documentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return docSyncStates[documentId] ?? false
    }

    public func isOpen(_ documentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return openDocs[documentId] != nil
    }

    public func getPermission(_ documentId: String) -> DocumentPermission? {
        lock.lock()
        defer { lock.unlock() }
        return docPermissions[documentId]
    }

    public func setPermission(_ documentId: String, permission: DocumentPermission) {
        lock.lock()
        docPermissions[documentId] = permission
        lock.unlock()
        emitter?.emit(.permission, PermissionEvent(documentId: documentId, permission: permission))
    }

    public func isReadOnly(_ documentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return docPermissions[documentId] == .reader
    }

    public func listOpenDocuments() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(openDocs.keys)
    }

    // MARK: - Metadata

    public func getMetadataIndex() -> [String: LocalMetadataEntry] {
        lock.lock()
        defer { lock.unlock() }
        return metadataIndex
    }

    public func getLocalMetadata(_ documentId: String) -> LocalMetadataEntry? {
        lock.lock()
        defer { lock.unlock() }
        return metadataIndex[documentId]
    }

    public func setMetadata(_ documentId: String, entry: LocalMetadataEntry) {
        lock.lock()
        metadataIndex[documentId] = entry
        lock.unlock()
    }

    public func handleServerDocuments(_ documents: [[String: Any]]) async {
        for docData in documents {
            guard let documentId = docData["documentId"] as? String else { continue }

            var entry = getLocalMetadata(documentId) ?? LocalMetadataEntry(documentId: documentId)
            if let title = docData["title"] as? String { entry.title = title }
            if let perm = docData["permission"] as? String { entry.permission = perm }
            if let createdBy = docData["createdBy"] as? String { entry.createdBy = createdBy }
            if let createdAt = docData["createdAt"] as? String { entry.createdAt = createdAt }
            if let modifiedAt = docData["modifiedAt"] as? String { entry.modifiedAt = modifiedAt }
            if let tags = docData["tags"] as? [String] { entry.tags = tags }
            entry.metadataSyncedAt = ISO8601DateFormatter().string(from: Date())

            setMetadata(documentId, entry: entry)

            if let permStr = docData["permission"] as? String,
               let perm = DocumentPermission(rawValue: permStr) {
                lock.lock()
                docPermissions[documentId] = perm
                lock.unlock()
            }

            // Persist
            try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: entry)
        }

        emitter?.emit(.documentMetadataChanged, [:] as [String: Any])
    }

    // MARK: - Pending Creates

    public func isPendingCreate(_ documentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingCreates.contains(documentId)
    }

    public func isLocalOnly(_ documentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return localOnlyDocs.contains(documentId)
    }

    /// Create a document locally (offline or local-only)
    public func createLocalDocument(documentId: String, title: String?, localOnly: Bool) async throws -> YDocument {
        let doc = YDocument()

        var metadata = LocalMetadataEntry(documentId: documentId)
        metadata.title = title
        metadata.pendingCreate = !localOnly
        metadata.localOnly = localOnly
        metadata.createdAt = ISO8601DateFormatter().string(from: Date())

        lock.lock()
        openDocs[documentId] = doc
        docSyncStates[documentId] = false
        metadataIndex[documentId] = metadata
        if localOnly {
            localOnlyDocs.insert(documentId)
        } else {
            pendingCreates.insert(documentId)
        }
        lock.unlock()

        // Persist metadata
        try await offlineStore?.putMetadata(appId: appId, userId: userId, record: metadata)

        emitter?.emit(.documentMetadataChanged, ["action": "created", "documentId": documentId] as [String: Any])

        return doc
    }

    /// Commit a pending create to the server
    public func commitOfflineCreate(
        documentId: String,
        onExists: String = "fail"
    ) async throws -> [String: Any] {
        guard isPendingCreate(documentId) else {
            throw JsBaoError(code: .invalidArgument, message: "Document is not a pending create")
        }

        let metadata = getLocalMetadata(documentId)

        do {
            let body: [String: Any] = [
                "documentId": documentId,
                "title": metadata?.title as Any,
            ]

            guard let createRemote = createRemoteDocument else {
                throw JsBaoError(code: .unavailable, message: "Remote create not configured")
            }

            let result = try await createRemote(body)

            // Success
            lock.lock()
            pendingCreates.remove(documentId)
            if var meta = metadataIndex[documentId] {
                meta.pendingCreate = false
                meta.commitError = nil
                metadataIndex[documentId] = meta
                lock.unlock()
                try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: meta)
            } else {
                lock.unlock()
            }

            return ["created": true]
        } catch let error as HttpError where error.status == 409 {
            if onExists == "link" {
                lock.lock()
                pendingCreates.remove(documentId)
                if var meta = metadataIndex[documentId] {
                    meta.pendingCreate = false
                    metadataIndex[documentId] = meta
                    lock.unlock()
                    try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: meta)
                } else {
                    lock.unlock()
                }
                return ["linked": true]
            }
            return ["reason": "exists"]
        } catch {
            // Record error and schedule retry
            lock.lock()
            if var meta = metadataIndex[documentId] {
                meta.commitError = CommitError(
                    message: error.localizedDescription,
                    at: ISO8601DateFormatter().string(from: Date())
                )
                metadataIndex[documentId] = meta
                lock.unlock()
                try? await offlineStore?.putMetadata(appId: appId, userId: userId, record: meta)
            } else {
                lock.unlock()
            }

            emitter?.emit(.pendingCreateFailed, ["documentId": documentId, "error": error.localizedDescription] as [String: Any])
            throw error
        }
    }

    /// Cancel a pending create
    public func cancelPendingCreate(_ documentId: String) async {
        lock.lock()
        pendingCreates.remove(documentId)
        pendingCreateRetryTimers[documentId]?.cancel()
        pendingCreateRetryTimers.removeValue(forKey: documentId)
        let _ = openDocs.removeValue(forKey: documentId)
        metadataIndex.removeValue(forKey: documentId)
        lock.unlock()

        try? await offlineStore?.deleteMetadata(appId: appId, userId: userId, documentId: documentId)
    }

    public func listPendingCreates() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(pendingCreates)
    }

    // MARK: - Awareness State

    /// Set the local awareness state for a document.
    public func setLocalAwarenessState(_ documentId: String, state: [String: Any]) {
        lock.lock()
        docAwareness[documentId]?.localState = state
        lock.unlock()
    }

    /// Get the full awareness snapshot for a document (local + remote states).
    public func getAwarenessSnapshot(_ documentId: String) -> AwarenessEntry? {
        lock.lock()
        defer { lock.unlock() }
        return docAwareness[documentId]
    }

    /// Apply incoming remote awareness states for a document.
    public func applyRemoteAwareness(_ documentId: String, states: [[String: Any]]) {
        lock.lock()
        guard var entry = docAwareness[documentId] else {
            lock.unlock()
            return
        }
        for state in states {
            if let clientId = state["clientId"] as? String {
                entry.remoteStates[clientId] = state
            }
        }
        docAwareness[documentId] = entry
        lock.unlock()
    }

    /// Remove awareness states for specific clients. Returns the IDs that were actually removed.
    @discardableResult
    public func removeAwarenessClients(_ documentId: String, clientIds: [String]) -> [String] {
        lock.lock()
        guard var entry = docAwareness[documentId] else {
            lock.unlock()
            return []
        }
        var removed: [String] = []
        for clientId in clientIds {
            if entry.remoteStates.removeValue(forKey: clientId) != nil {
                removed.append(clientId)
            }
        }
        docAwareness[documentId] = entry
        lock.unlock()
        return removed
    }

    // MARK: - Local Data Management

    public func hasLocalCopy(_ documentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return metadataIndex[documentId] != nil || docPersistence[documentId] != nil
    }

    public func evictLocalData(documentId: String) async {
        lock.lock()
        metadataIndex.removeValue(forKey: documentId)
        docPersistence.removeValue(forKey: documentId)
        lock.unlock()

        try? await offlineStore?.deleteMetadata(appId: appId, userId: userId, documentId: documentId)
    }

    public func evictAllLocalData() async {
        lock.lock()
        let docIds = Array(metadataIndex.keys)
        metadataIndex.removeAll()
        docPersistence.removeAll()
        openDocs.removeAll()
        docSyncStates.removeAll()
        docPermissions.removeAll()
        pendingCreates.removeAll()
        localOnlyDocs.removeAll()
        pendingCreateRetryTimers.values.forEach { $0.cancel() }
        pendingCreateRetryTimers.removeAll()
        lock.unlock()

        for docId in docIds {
            try? await offlineStore?.deleteMetadata(appId: appId, userId: userId, documentId: docId)
        }
    }

    // MARK: - Document Hash

    public func getDocHash(documentId: String) -> String? {
        lock.lock()
        guard let doc = openDocs[documentId] else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        // Use state vector as a content hash for the document
        let stateVector: [UInt8] = doc.transactSync { txn in
            txn.transactionStateVector()
        }
        return Data(stateVector).base64EncodedString()
    }

    // MARK: - Persistence

    private func persistDocumentToLocal(documentId: String) async {
        lock.lock()
        guard let doc = openDocs[documentId] else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Get full document state as an update.
        // Use transactionEncodeStateAsUpdate (no state vector param) to get the
        // complete document state, avoiding the empty-state-vector crash in yrs.
        let state: [UInt8] = doc.transactSync { txn in
            txn.transactionEncodeStateAsUpdate()
        }

        if let persistence = docPersistence[documentId] {
            try? await persistence.saveDocument(data: Data(state))
        }
    }

    /// Load all local metadata from storage
    public func loadLocalMetadata() async {
        guard let offlineStore = offlineStore else { return }
        guard let entries = try? await offlineStore.loadAllMetadata(appId: appId, userId: userId) else { return }

        lock.lock()
        for entry in entries {
            metadataIndex[entry.documentId] = entry
            if entry.pendingCreate == true {
                pendingCreates.insert(entry.documentId)
            }
            if entry.localOnly == true {
                localOnlyDocs.insert(entry.documentId)
            }
        }
        lock.unlock()
    }

    // MARK: - Cleanup

    public func destroy() async {
        lock.lock()
        let docIds = Array(openDocs.keys)
        lock.unlock()

        for docId in docIds {
            await closeDocument(documentId: docId)
        }

        lock.lock()
        pendingCreateRetryTimers.values.forEach { $0.cancel() }
        pendingCreateRetryTimers.removeAll()
        syncProtocols.removeAll()
        lock.unlock()
    }
}

// MARK: - Yjs SQLite Persistence

/// Persists Yjs document state to SQLite (replaces y-indexeddb)
public final class YjsSQLitePersistence: @unchecked Sendable {
    private let storageProvider: StorageProvider
    private let documentId: String
    private static let store = "yjs_docs"

    public init(storageProvider: StorageProvider, documentId: String) {
        self.storageProvider = storageProvider
        self.documentId = documentId
    }

    public func loadDocument() async throws -> Data? {
        let record: StorageRecord<Data>? = try await storageProvider.get(store: Self.store, key: documentId)
        return record?.value
    }

    public func saveDocument(data: Data) async throws {
        try await storageProvider.put(store: Self.store, key: documentId, value: data, metadata: nil)
    }

    public func deleteDocument() async throws {
        try await storageProvider.delete(store: Self.store, key: documentId)
    }
}
