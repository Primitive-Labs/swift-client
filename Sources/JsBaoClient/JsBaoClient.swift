import Foundation
import YSwift
import Yniffi

/// Main client for the JsBao platform. Manages WebSocket connections,
/// document collaboration via y-crdt, authentication, offline storage, and REST APIs.
public final class JsBaoClient: @unchecked Sendable {

    // MARK: - Public Properties

    /// Event emitter for subscribing to client events
    public let events: EventEmitter

    /// Sub-APIs
    public private(set) var documents: DocumentsAPI!
    public private(set) var collections: CollectionsAPI!
    public private(set) var databases: DatabasesAPI!
    public private(set) var me: MeAPI!
    public private(set) var session: SessionAPI!
    public private(set) var llm: LlmAPI!
    public private(set) var gemini: GeminiAPI!
    public private(set) var users: UsersAPI!
    public private(set) var groups: GroupsAPI!
    public private(set) var ruleSets: RuleSetsAPI!
    public private(set) var groupTypeConfigs: GroupTypeConfigsAPI!
    public private(set) var integrations: IntegrationsAPI!
    public private(set) var prompts: PromptsAPI!
    public private(set) var workflows: WorkflowsAPI!

    /// Cache facade for general-purpose caching
    public private(set) var cache: CacheFacade!

    // MARK: - Internal Components

    private let options: JsBaoClientOptions
    private let logger: Logger
    private let httpClient: HttpClient
    private let wsManager: WebSocketManager
    /// `internal` (not `private`) so `@testable import JsBaoClient`
    /// tests can drive auth flows directly (e.g., concurrent-refresh
    /// coalescing tests). Not part of the public surface.
    internal let authController: AuthController
    let documentManager: DocumentManager
    private let blobManager: BlobManager
    private let offlineStore: OfflineStore
    private let analyticsQueue: AnalyticsQueue
    private let kvCache: KvCache

    private let lock = NSLock()
    private var networkMode: NetworkMode = .auto
    private var lastOnlineAt: Date?
    private var subscribedDocuments: Set<String> = []
    private var outboundDebounceTimers: [String: Task<Void, Never>] = [:]
    private var pendingUpdates: [String: [[UInt8]]] = [:]
    private var isDestroyed = false

    // MARK: - Initialization

    public init(options: JsBaoClientOptions) {
        self.options = options
        self.events = EventEmitter()

        // Logger
        self.logger = createLogger(level: options.logLevel, scope: "JsBaoClient")

        // Offline store
        self.offlineStore = OfflineStore()

        // Auth controller
        self.authController = AuthController(
            appId: options.appId,
            apiUrl: options.apiUrl,
            logger: logger,
            offlineStore: offlineStore,
            emitter: events,
            refreshProxy: options.auth.refreshProxy,
            persistConfig: options.auth
        )

        // HTTP client
        self.httpClient = HttpClient(config: HttpClientConfig(
            apiUrl: options.apiUrl,
            appId: options.appId,
            getToken: { [weak authController] in authController?.getToken() },
            getConnectionId: { nil }, // Will be set after wsManager init
            onTokenRefresh: { [weak authController] token in
                authController?.updateToken(token, cause: "http_refresh")
            },
            onRefreshOutcome: { _ in },
            getGlobalAdminAppId: { options.globalAdminAppId },
            logger: logger,
            refreshProxy: options.auth.refreshProxy
        ))

        // WebSocket manager
        self.wsManager = WebSocketManager(
            logger: logger,
            maxReconnectDelayMs: Int(options.maxReconnectDelay * 1000)
        )

        // Document manager
        self.documentManager = DocumentManager(logger: logger)

        // Blob manager
        self.blobManager = BlobManager(logger: logger, uploadConcurrency: options.blobUploadConcurrency)

        // Analytics queue
        self.analyticsQueue = AnalyticsQueue(logger: logger)

        // KV cache
        self.kvCache = KvCache()

        // Wire up dependencies
        setupDependencies()
        setupSubApis()

        // Bootstrap token synchronously so it's available for connect().
        // The async setupStorage() Task would set it too late.
        if let token = options.token {
            authController.bootstrapToken(token)
        }

        setupStorage()
    }

    // MARK: - Static Methods

    /// Exchange an OAuth authorization code for an access token.
    /// This is a static method that doesn't require a client instance.
    public static func exchangeOAuthCode(
        apiUrl: String,
        appId: String,
        code: String,
        state: String
    ) async throws -> String {
        var components = URLComponents(string: "\(apiUrl)/app/\(appId)/api/oauth/callback")!
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "state", value: state),
        ]
        let url = components.url!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError(code: .unauthorized, message: "OAuth exchange failed: \(body)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw AuthError(code: .unauthorized, message: "No token in OAuth response")
        }
        return token
    }

    // MARK: - Connection

    /// Connect to the WebSocket server
    public func connect() async throws {
        guard !isDestroyed else { return }
        try await wsManager.connect()
    }

    /// Disconnect from the WebSocket server
    public func disconnect() async {
        await wsManager.disconnect()
    }

    /// Set whether the client should maintain a WebSocket connection
    public func setShouldConnect(_ shouldConnect: Bool) async {
        await wsManager.setDesiredConnection(shouldConnect: shouldConnect)
    }

    /// Force reconnect the WebSocket
    public func forceReconnect() {
        wsManager.forceReconnect()
    }

    /// Check if WebSocket is connected
    public var isConnected: Bool {
        wsManager.isConnected
    }

    /// Get the current connection ID
    public var connectionId: String {
        wsManager.connectionId
    }

    // MARK: - Authentication

    /// Wait for authentication to be ready
    public func waitForAuthReady(timeout: TimeInterval = 10) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.authController.waitForAuthReady()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw JsBaoError(code: .unavailable, message: "Auth ready timeout")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Wait for user ID to be available
    public func waitForUserId(timeout: TimeInterval = 10) async throws -> String {
        try await waitForAuthReady(timeout: timeout)
        guard let userId = authController.getUserId() else {
            throw AuthError(code: .unauthorized, message: "Not authenticated")
        }
        return userId
    }

    /// Get current auth state
    public func getAuthState() -> AuthState {
        authController.getAuthState()
    }

    /// Get current user ID
    public func getUserId() -> String? {
        authController.getUserId()
    }

    /// Check if user is authenticated
    public func isAuthenticated() -> Bool {
        authController.isAuthenticated()
    }

    /// Get auth persistence info
    public func getAuthPersistenceInfo() -> [String: Any] {
        var info: [String: Any] = [:]
        if options.auth.persistJwtInStorage {
            info["mode"] = "persisted"
            info["prefix"] = options.auth.storageKeyPrefix ?? "default"
        } else {
            info["mode"] = "memory"
        }
        return info
    }

    /// Logout
    public func logout(wipeLocal: Bool = false) async throws {
        try await authController.logout(wipeLocal: wipeLocal)
        if wipeLocal {
            await documentManager.evictAllLocalData()
            await kvCache.clearAll()
        }
        await disconnect()
    }

    // MARK: - OAuth

    /// Start an OAuth flow. Returns the authorization URL to open in a browser.
    public func startOAuthFlow(redirectUri: String, continueUrl: String? = nil) async throws -> URL {
        try await authController.startOAuthFlow(redirectUri: redirectUri, continueUrl: continueUrl)
    }

    /// Handle the OAuth callback after the user authorizes. Exchanges the code for a token.
    public func handleOAuthCallback(code: String, state: String) async throws {
        try await authController.handleOAuthCallback(code: code, state: state)
    }

    // MARK: - Magic Link

    /// Request a magic link email for the given address.
    public func magicLinkRequest(email: String, redirectUri: String) async throws -> Bool {
        try await authController.magicLinkRequest(email: email, redirectUri: redirectUri)
    }

    /// Verify a magic link token received from the email callback.
    public func magicLinkVerify(token: String) async throws -> [String: Any] {
        try await authController.magicLinkVerify(token: token)
    }

    // MARK: - OTP

    /// Request a one-time password sent to the given email.
    public func otpRequest(email: String) async throws -> Bool {
        try await authController.otpRequest(email: email)
    }

    /// Verify a one-time password code.
    public func otpVerify(email: String, code: String) async throws -> [String: Any] {
        try await authController.otpVerify(email: email, code: code)
    }

    // MARK: - Token Management

    /// Update the auth token externally (e.g. after a custom auth flow).
    public func updateToken(_ token: String?, cause: String? = nil) {
        authController.updateToken(token, cause: cause)
    }

    /// Get the current JWT payload.
    public func getJwtPayload() -> [String: Any]? {
        authController.getJwtPayload()
    }

    // MARK: - Network Mode

    /// Check if in online mode
    public func isOnline() -> Bool {
        let mode = getNetworkMode()
        return mode != .offline
    }

    /// Get current network mode
    public func getNetworkMode() -> NetworkMode {
        lock.lock()
        defer { lock.unlock() }
        return networkMode
    }

    /// Get detailed network status
    public func getNetworkStatus() -> NetworkStatus {
        lock.lock()
        let mode = networkMode
        let lastOnline = lastOnlineAt
        lock.unlock()
        return NetworkStatus(
            mode: mode,
            isOnline: mode != .offline,
            lastOnlineAt: lastOnline,
            reason: nil
        )
    }

    /// Switch to online mode
    public func goOnline() async {
        setNetworkMode(.online)
        try? await connect()
    }

    /// Switch to offline mode
    public func goOffline() async {
        setNetworkMode(.offline)
        await disconnect()
    }

    /// Set network mode
    public func setNetworkMode(_ mode: NetworkMode) {
        lock.lock()
        networkMode = mode
        lock.unlock()
        authController.setNetworkMode(mode)
        events.emit(.networkMode, NetworkModeEvent(
            mode: mode,
            isOnline: mode != .offline,
            reason: "user_set"
        ))
    }

    // MARK: - Offline Access

    /// Enable offline access by requesting a grant from the server and storing it securely.
    /// Requires online connectivity.
    public func enableOfflineAccess(options: EnableOfflineAccessOptions = EnableOfflineAccessOptions()) async throws -> [String: Any] {
        try await authController.enableOfflineAccess(options: options)
    }

    /// Unlock offline access by reading the stored grant.
    /// If biometric-protected, this triggers Face ID / Touch ID.
    public func unlockOffline() async throws -> Bool {
        let result = try await authController.unlockOffline()
        if result {
            setNetworkMode(.offline)
        }
        return result
    }

    /// Check if an offline access grant is available.
    public func isOfflineGrantAvailable() -> Bool {
        authController.isOfflineGrantAvailable()
    }

    /// Get the status of the offline access grant.
    public func getOfflineGrantStatus() -> OfflineGrantStatus {
        authController.getOfflineGrantStatus()
    }

    /// Renew the offline access grant while online.
    public func renewOfflineGrantOnline(options: EnableOfflineAccessOptions = EnableOfflineAccessOptions()) async throws -> Bool {
        try await authController.renewOfflineGrantOnline(options: options)
    }

    /// Revoke the offline access grant.
    public func revokeOfflineGrant(options: RevokeOfflineGrantOptions = RevokeOfflineGrantOptions()) async throws {
        try await authController.revokeOfflineGrant(options: options)
        if options.wipeLocal {
            await evictAllLocal(force: true)
        }
    }

    /// Get the offline identity (available after unlockOffline succeeds).
    public func getOfflineIdentity() -> OfflineIdentity? {
        authController.getOfflineIdentity()
    }

    // MARK: - Document Operations

    /// Open a document
    public func openDocument(
        _ documentId: String,
        options: OpenDocumentOptions = OpenDocumentOptions()
    ) async throws -> YDocument {
        let doc = try await documentManager.openDocument(
            documentId: documentId,
            options: options
        )

        // Start network sync if requested
        if options.enableNetworkSync && isOnline() {
            await startNetworkSync(documentId: documentId)

            // If waitForLoad is .network, actually wait for the sync to
            // complete before returning. Without this, callers get an empty
            // YDocument and have to race against the .sync event.
            if options.waitForLoad == .network && !documentManager.isSynced(documentId) {
                let syncDocId = documentId
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    // Class-boxed so the sync handler and timeout Task share
                    // the flag without an UnsafeMutablePointer leak.
                    final class ResumedFlag { var value: Bool = false }
                    let resumed = ResumedFlag()
                    let resumedLock = NSLock()

                    func resumeOnce() {
                        resumedLock.lock()
                        let alreadyResumed = resumed.value
                        resumed.value = true
                        resumedLock.unlock()
                        if !alreadyResumed {
                            cont.resume()
                        }
                    }

                    var sub: EventSubscription?
                    sub = self.events.on(.sync) { (event: SyncEvent) in
                        if event.documentId == syncDocId && event.synced {
                            sub?.cancel()
                            resumeOnce()
                        }
                    }
                    // Timeout after 15s to avoid hanging forever
                    Task {
                        try? await Task.sleep(nanoseconds: 15_000_000_000)
                        sub?.cancel()
                        resumeOnce()
                    }
                }
            }
        }

        return doc
    }

    /// Close a document
    public func closeDocument(_ documentId: String, options: CloseDocumentOptions = CloseDocumentOptions()) async {
        lock.lock()
        subscribedDocuments.remove(documentId)
        outboundDebounceTimers[documentId]?.cancel()
        outboundDebounceTimers.removeValue(forKey: documentId)
        pendingUpdates.removeValue(forKey: documentId)
        lock.unlock()

        await documentManager.closeDocument(documentId: documentId, options: options)
    }

    /// Create a new document
    public func createDocument(options: CreateDocumentOptions = CreateDocumentOptions()) async throws -> (documentId: String, doc: YDocument?) {
        let documentId = UUID().uuidString.lowercased()

        if options.localOnly || !isOnline() {
            let doc = try await documentManager.createLocalDocument(
                documentId: documentId,
                title: options.title,
                localOnly: options.localOnly
            )
            return (documentId, doc)
        }

        // Create on server
        var body: [String: Any] = ["documentId": documentId]
        if let title = options.title { body["title"] = title }
        if let tags = options.tags { body["tags"] = tags }

        let _ = try await makeRequest("POST", "/documents", body)
        return (documentId, nil)
    }

    /// Get a Y.Doc for an open document
    public func getDoc(_ documentId: String) -> YDocument? {
        documentManager.getDocument(documentId)
    }

    /// Perform a transaction on a document and send any resulting changes to the server.
    ///
    /// YSwift doesn't expose document-level update observers, so local writes to a YDocument
    /// aren't automatically sent. Use this method instead of calling `doc.transactSync` directly
    /// when you want changes to propagate to other clients.
    public func transactAndSync<T>(_ documentId: String, _ changes: @escaping (YrsTransaction) -> T) -> T {
        guard let doc = documentManager.getDocument(documentId) else {
            fatalError("Document \(documentId) is not open")
        }

        // Capture state vector before the write
        let svBefore: [UInt8] = doc.transactSync { txn in
            txn.transactionStateVector()
        }

        // Run the user's changes
        let result = doc.transactSync(changes)

        // Compute the diff (what changed)
        var update: [UInt8] = []
        doc.transactSync { [self] txn in
            do {
                update = try txn.transactionEncodeStateAsUpdateFromSv(stateVector: svBefore)
            } catch {
                self.logger.warn("Failed to encode update after transaction:", error.localizedDescription)
            }
        }

        // Send the update if there were changes
        if !update.isEmpty {
            queueOutboundUpdate(documentId: documentId, update: update)
        }

        return result
    }

    /// Async version of `transactAndSync` — bypasses syncQueue entirely using the raw YrsDoc
    /// to avoid deadlocking with the WebSocket message handler. Safe to call from `@MainActor`.
    @discardableResult
    public func transactAndSyncAsync<T: Sendable>(_ documentId: String, _ changes: @escaping @Sendable (YrsTransaction) -> T) async -> T {
        guard let doc = documentManager.getDocument(documentId) else {
            fatalError("Document \(documentId) is not open")
        }

        let result: (T, [UInt8]) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Use raw YrsDoc to bypass syncQueue entirely
                let rawDoc = doc.document

                // 1. Get state vector before write
                let svTxn = rawDoc.transact(origin: nil)
                let svBefore = svTxn.transactionStateVector()
                svTxn.free()

                // 2. Apply changes
                let writeTxn = rawDoc.transact(origin: nil)
                let result = changes(writeTxn)
                writeTxn.free()

                // 3. Compute diff
                let diffTxn = rawDoc.transact(origin: nil)
                var update: [UInt8] = []
                do {
                    update = try diffTxn.transactionEncodeStateAsUpdateFromSv(stateVector: svBefore)
                } catch {}
                diffTxn.free()

                continuation.resume(returning: (result, update))
            }
        }

        if !result.1.isEmpty {
            queueOutboundUpdate(documentId: documentId, update: result.1)
        }

        return result.0
    }

    /// Check if a document is synced
    public func isSynced(_ documentId: String) -> Bool {
        documentManager.isSynced(documentId)
    }

    /// Check if a document is open
    public func isDocumentOpen(_ documentId: String) -> Bool {
        documentManager.isOpen(documentId)
    }

    /// List open document IDs
    public func listOpenDocuments() -> [String] {
        documentManager.listOpenDocuments()
    }

    /// Check if document is read-only
    public func isDocumentReadOnly(_ documentId: String) -> Bool {
        documentManager.isReadOnly(documentId)
    }

    /// Get root document ID
    public func getRootDocId() async throws -> String? {
        let result = try await makeRequest("GET", "/documents/root", nil)
        guard let dict = result as? [String: Any] else { return nil }
        return dict["documentId"] as? String
    }

    /// Check if a document is a pending create
    public func isPendingCreate(_ documentId: String) -> Bool {
        documentManager.isPendingCreate(documentId)
    }

    /// Check if a document is local-only (never syncs to server)
    public func isLocalOnly(_ documentId: String) -> Bool {
        documentManager.isLocalOnly(documentId)
    }

    /// Check if document has local copy
    public func hasLocalCopy(_ documentId: String) -> Bool {
        documentManager.hasLocalCopy(documentId)
    }

    /// Commit a pending offline create to the server.
    ///
    /// - Parameters:
    ///   - documentId: The document to commit.
    ///   - onExists: Behavior when document already exists on server: "fail" (default) or "link".
    public func commitOfflineCreate(documentId: String, onExists: String = "fail") async throws -> [String: Any] {
        try await documentManager.commitOfflineCreate(documentId: documentId, onExists: onExists)
    }

    /// List all documents pending server creation.
    public func listPendingCreates() -> [String] {
        documentManager.listPendingCreates()
    }

    /// Cancel a pending offline create.
    ///
    /// - Parameters:
    ///   - documentId: The document to cancel.
    ///   - evictLocal: If true, also removes the local copy.
    public func cancelPendingCreate(_ documentId: String, evictLocal: Bool = false) async {
        await documentManager.cancelPendingCreate(documentId)
        if evictLocal {
            await documentManager.evictLocalData(documentId: documentId)
        }
    }

    /// Start network sync for a document
    public func startNetworkSync(documentId: String) async {
        guard let message = documentManager.buildSyncStep1Message(documentId: documentId) else { return }

        lock.lock()
        subscribedDocuments.insert(documentId)
        lock.unlock()

        do {
            try await wsManager.send(message)
        } catch {
            logger.warn("Failed to send syncStep1 for", documentId, error.localizedDescription)
        }
    }

    // MARK: - Awareness

    /// Set awareness state for a document (e.g. cursor position, selection, user info).
    public func setAwareness(_ documentId: String, state: [String: Any]) {
        documentManager.setLocalAwarenessState(documentId, state: state)

        let message: [String: Any] = [
            "type": "awareness",
            "documentId": documentId,
            "states": [state],
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        Task {
            try? await wsManager.send(jsonString)
        }
    }

    /// Remove awareness states for specific clients.
    public func removeAwareness(documentId: String, clientIds: [String]) {
        documentManager.removeAwarenessClients(documentId, clientIds: clientIds)

        // Send removal as [clientId, null] tuples
        let states: [[Any]] = clientIds.map { [$0, NSNull()] }
        let message: [String: Any] = [
            "type": "awareness",
            "documentId": documentId,
            "states": states,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        Task {
            try? await wsManager.send(jsonString)
        }
    }

    /// Get all awareness states for a document (local + remote).
    /// Returns a dictionary keyed by client ID.
    public func getAwarenessStates(documentId: String) -> [String: [String: Any]] {
        guard let snapshot = documentManager.getAwarenessSnapshot(documentId) else { return [:] }
        var states = snapshot.remoteStates
        if let localState = snapshot.localState {
            states[connectionId] = localState
        }
        return states
    }

    // MARK: - HTTP API

    /// Make an authenticated HTTP request
    public func makeRequest(_ method: String, _ path: String, _ data: Any? = nil) async throws -> Any {
        try await httpClient.request(method: method, path: path, data: data)
    }

    /// Make a raw HTTP request
    public func makeRawRequest(_ method: String, _ path: String, _ data: Data? = nil, headers: [String: String]? = nil) async throws -> (Data, Int) {
        let opts = headers.map { RequestOptions(rawBody: true, customHeaders: $0) }
        let result = try await httpClient.requestRaw(method: method, path: path, data: data, options: opts)
        let responseData = (result.text ?? "").data(using: .utf8) ?? Data()
        return (responseData, result.status)
    }

    // MARK: - Configuration

    /// Get the API URL
    public func getApiUrl() -> String { options.apiUrl }

    /// Get the app ID
    public func getAppId() -> String { options.appId }

    /// Get the global admin app ID
    public func getGlobalAdminAppId() -> String { options.globalAdminAppId }

    /// Set log level
    public func setLogLevel(_ level: LogLevel) {
        logger.setLevel(level)
    }

    /// Set blob upload concurrency
    public func setBlobUploadConcurrency(_ value: Int) {
        blobManager.setUploadConcurrency(value)
    }

    /// Get blob upload concurrency
    public func getBlobUploadConcurrency() -> Int {
        blobManager.getUploadConcurrency()
    }

    // MARK: - Offline Data

    /// Evict all local data
    public func evictAllLocal(force: Bool = false) async {
        await documentManager.evictAllLocalData()
        await kvCache.clearAll()
        blobManager.clearCache()
    }

    /// Get offline info for a document
    public func getOfflineInfo(_ documentId: String) -> [String: Any] {
        return [
            "hasLocalCopy": hasLocalCopy(documentId),
            "isSynced": isSynced(documentId),
        ]
    }

    /// Sync metadata
    public func syncMetadata() async throws {
        let result = try await makeRequest("GET", "/documents", nil)
        guard let docs = result as? [[String: Any]] else { return }
        await documentManager.handleServerDocuments(docs)
    }

    // MARK: - Analytics

    /// Log an analytics event
    public func logAnalyticsEvent(_ event: [String: Any]) {
        analyticsQueue.logEvent(event)
    }

    /// Flush pending analytics events immediately.
    public func flushAnalytics() {
        analyticsQueue.flush()
    }

    /// Override the plan field on all subsequent analytics events.
    public func setAnalyticsPlanOverride(_ plan: String?) {
        analyticsQueue.setPlanOverride(plan)
    }

    /// Override the app version field on all subsequent analytics events.
    public func setAnalyticsAppVersionOverride(_ version: String?) {
        analyticsQueue.setAppVersionOverride(version)
    }

    // MARK: - Blob Management

    /// Get blob manager (for advanced usage)
    public func getBlobManager() -> BlobManager {
        blobManager
    }

    // MARK: - Document Context

    /// Get a scoped document context
    public func document(_ documentId: String) -> DocumentContext {
        DocumentContext(
            documentId: documentId,
            client: self,
            blobManager: blobManager,
            makeRequest: makeRequest
        )
    }

    // MARK: - Lifecycle

    /// Destroy the client and clean up resources
    public func destroy() async {
        lock.lock()
        guard !isDestroyed else {
            lock.unlock()
            return
        }
        isDestroyed = true
        outboundDebounceTimers.values.forEach { $0.cancel() }
        outboundDebounceTimers.removeAll()
        lock.unlock()

        await disconnect()
        await documentManager.destroy()
        analyticsQueue.destroy()
        offlineStore.closeStorage()
        events.removeAll()
    }

    // MARK: - Private Setup

    private func setupDependencies() {
        // Wire auth controller's makeRequest
        authController.makeRequest = { [weak self] method, path, data in
            guard let self = self else { throw JsBaoError(code: .unavailable) }
            return try await self.httpClient.request(method: method, path: path, data: data)
        }

        // Note: HTTP client's getConnectionId is set via config closure at init time

        // Wire document manager dependencies
        documentManager.offlineStore = offlineStore
        documentManager.appId = options.appId
        documentManager.emitter = events
        documentManager.sendWebSocketMessage = { [weak self] message in
            try await self?.wsManager.send(message)
        }
        documentManager.createRemoteDocument = { [weak self] body in
            guard let self = self else { throw JsBaoError(code: .unavailable) }
            let result = try await self.makeRequest("POST", "/documents", body)
            return result as? [String: Any] ?? [:]
        }
        // Wire up document update observer — fires for ALL local writes to any open doc.
        // This is the equivalent of JS `doc.on("update", handler)`.
        documentManager.onLocalUpdate = { [weak self] documentId, update in
            self?.queueOutboundUpdate(documentId: documentId, update: update)
        }
        documentManager.commitRetryBackoff = options.commitRetryBackoff

        // Wire blob manager dependencies
        blobManager.makeRequest = { [weak self] method, path, data in
            guard let self = self else { throw JsBaoError(code: .unavailable) }
            return try await self.makeRequest(method, path, data)
        }
        blobManager.makeRawRequest = { [weak self] method, path, data, headers in
            guard let self = self else { throw JsBaoError(code: .unavailable) }
            return try await self.makeRawRequest(method, path, data, headers: headers)
        }
        blobManager.getApiUrl = { [weak self] in self?.options.apiUrl ?? "" }
        blobManager.getAppId = { [weak self] in self?.options.appId ?? "" }
        blobManager.getToken = { [weak self] in self?.authController.getToken() }
        blobManager.getGlobalAdminAppId = { [weak self] in self?.options.globalAdminAppId ?? "" }
        blobManager.getCurrentUserId = { [weak self] in self?.authController.getUserId() }
        blobManager.emitter = events

        // Wire analytics queue
        analyticsQueue.sendMessage = { [weak self] message in
            try await self?.wsManager.send(message)
        }
        analyticsQueue.getConnectionId = { [weak self] in self?.wsManager.connectionId }
        analyticsQueue.getUserId = { [weak self] in self?.authController.getUserId() }
        analyticsQueue.offlineStore = offlineStore
        analyticsQueue.appId = options.appId

        // Wire WebSocket manager delegate
        wsManager.delegate = self
    }

    private func setupSubApis() {
        let request: (String, String, Any?) async throws -> Any = { [weak self] method, path, data in
            guard let self = self else { throw JsBaoError(code: .unavailable) }
            return try await self.makeRequest(method, path, data)
        }

        let cacheFacade = CacheFacade(
            kvCache: kvCache,
            getNetworkMode: { [weak self] in self?.getNetworkMode() ?? .auto },
            makeRequest: request
        )
        self.cache = cacheFacade

        documents = DocumentsAPI(makeRequest: request, blobManager: blobManager)
        collections = CollectionsAPI(makeRequest: request)
        databases = DatabasesAPI(makeRequest: request)
        me = MeAPI(makeRequest: request, cache: cacheFacade)
        session = SessionAPI(makeRequest: request)
        llm = LlmAPI(makeRequest: request)
        gemini = GeminiAPI(makeRequest: request)
        users = UsersAPI(makeRequest: request, cache: cacheFacade)
        groups = GroupsAPI(makeRequest: request)
        ruleSets = RuleSetsAPI(makeRequest: request)
        groupTypeConfigs = GroupTypeConfigsAPI(makeRequest: request)
        // IntegrationsAPI needs the raw HttpClientResponse to surface
        // upstream status / headers / typed error mapping (the proxy
        // envelope puts the upstream status in the body and the proxy's
        // OWN status in the response status). Plumb it directly to
        // httpClient.requestRaw rather than the regular request closure.
        integrations = IntegrationsAPI(
            makeRawRequest: { [weak self] method, path, data in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.httpClient.requestRaw(
                    method: method,
                    path: path,
                    data: data,
                    options: nil
                )
            }
        )
        prompts = PromptsAPI(makeRequest: request)
        workflows = WorkflowsAPI(
            makeRequest: request,
            getConnectionId: { [weak self] in self?.wsManager.connectionId ?? "" },
            logger: logger
        )
    }

    private func setupStorage() {
        Task {
            do {
                let provider: StorageProvider
                let authProvider: StorageProvider
                switch options.storageConfig {
                case .sqlite(let directory):
                    provider = try SQLiteStorageProvider(path: directory)
                    // OfflineStore + JWT persistence both call
                    // `provider.initialize(namespace:)` with different namespaces.
                    // SQLiteStorageProvider re-binds `self.db` on every initialize
                    // call when no explicit path is set, so a single provider
                    // ends up pointing at whichever namespace was initialized
                    // most recently — and writes to yjs_docs / metadata silently
                    // land in the auth-namespace file. Use a dedicated provider
                    // for JWT storage to keep the two DBs from colliding.
                    authProvider = try SQLiteStorageProvider(path: directory)
                case .memory:
                    provider = MemoryStorageProvider()
                    authProvider = MemoryStorageProvider()
                }

                offlineStore.setStorageProvider(provider)
                offlineStore.setAuthStorageProvider(authProvider)
                kvCache.setStorageProvider(provider)

                // Bootstrap auth
                if let token = options.token {
                    authController.bootstrapToken(token)
                } else {
                    // Restore from persisted JWT — and, if it's aged out,
                    // attempt a cookie-based refresh before declaring the
                    // session dead. Access tokens live 1h; the refresh cookie
                    // persisted by URLSession lives 7d.
                    await authController.tryRestoreSession()
                }

                // Set userId on kvCache
                kvCache.setUserId(authController.getUserId())

                // Load local metadata
                if let userId = authController.getUserId() {
                    documentManager.userId = userId
                    try? await offlineStore.ensureMetadataDb(appId: options.appId, userId: userId)
                    await documentManager.loadLocalMetadata()
                }

                // Restore analytics queue
                await analyticsQueue.restoreBuffer()

                // Auto-connect if online
                if options.autoNetwork && isOnline() {
                    try? await connect()
                }
            } catch {
                logger.error("Storage setup failed:", error.localizedDescription)
            }
        }
    }

    // MARK: - WebSocket Message Handling

    func handleWebSocketMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warn("Invalid WebSocket message")
            return
        }

        // The server uses `type` as the message category (what we're
        // switching on) and `action` as a sub-action within that
        // category (e.g. `{type: "invitation", action: "created"}`).
        // This reads as `action` in the local var for historical
        // naming reasons, but it's a message *type* dispatch. Preferring
        // `action` over `type` (the previous implementation) meant
        // every message carrying both fields matched on its sub-action
        // string ("created", "updated", "accepted", …) and silently
        // fell through the switch — so `invitation` events, `docMetadata`
        // events, etc. never reached their subscribers. The JS client at
        // `src/client/JsBaoClient.ts` routes on `data.type` for exactly
        // this reason.
        let action = json["type"] as? String ?? json["action"] as? String ?? ""
        let roomId = json["roomId"] as? String ?? json["documentId"] as? String

        switch action {
        case "syncStep1":
            // Server sends its state vector; respond with our diff (syncStep2).
            // This enables bidirectional sync — the server gets any data we have
            // that it doesn't (e.g., offline edits).
            guard let roomId = roomId,
                  let stateVectorB64 = json["stateVector"] as? String else { return }
            if let responseMsg = documentManager.buildSyncStep2Response(documentId: roomId, serverStateVectorBase64: stateVectorB64) {
                try? await wsManager.send(responseMsg)
            }

        case "syncStep2":
            guard let roomId = roomId, let update = json["update"] as? String else { return }
            documentManager.handleSyncStep2(documentId: roomId, updateBase64: update)

        case "syncComplete":
            guard let roomId = roomId else { return }
            documentManager.handleSyncComplete(documentId: roomId)

        case "update":
            guard let roomId = roomId, let update = json["update"] as? String else { return }
            documentManager.handleUpdate(documentId: roomId, updateBase64: update)
            events.emit(.remoteUpdate, RemoteUpdateEvent(documentId: roomId))

        case "awareness":
            guard let roomId = roomId,
                  let states = json["states"] as? [[String: Any]] else { return }
            documentManager.applyRemoteAwareness(roomId, states: states)
            events.emit(.awareness, AwarenessEvent(documentId: roomId, states: states))

        case "serverDocuments":
            if let docs = json["documents"] as? [[String: Any]] {
                await documentManager.handleServerDocuments(docs)
            }

        case "permission":
            guard let roomId = roomId,
                  let permStr = json["permission"] as? String,
                  let perm = DocumentPermission(rawValue: permStr) else { return }
            documentManager.setPermission(roomId, permission: perm)

        case "workflowStatus":
            // workflowStatus messages are user-scoped, not document-scoped —
            // the server's WorkflowStatusPayload has no `documentId` /
            // `roomId`. The previous handler `guard let roomId` dropped
            // every message before it could be delivered. Decode the full
            // payload (matching JS) and route to the apply flow if needed.
            let event = WorkflowStatusEvent(
                workflowKey: json["workflowKey"] as? String ?? "",
                workflowId: json["workflowId"] as? String ?? "",
                runKey: json["runKey"] as? String ?? "",
                runId: json["runId"] as? String ?? "",
                status: json["status"] as? String ?? "",
                output: json["output"] is NSNull ? nil : json["output"],
                error: json["error"] as? String,
                contextDocId: json["contextDocId"] as? String,
                needsApply: json["needsApply"] as? Bool ?? false,
                meta: json["meta"] as? [String: Any],
                startedByUserId: json["startedByUserId"] as? String
            )
            events.emit(.workflowStatus, event)
            // If the workflow needs client-side apply and a handler is
            // registered, run the claim → apply → confirm flow.
            if event.needsApply {
                Task { [weak self] in
                    await self?.workflows.handleApplyEvent(event)
                }
            } else {
                // Terminal states without needsApply — route to
                // runAndApply/awaitRun waiters so they resolve without
                // hanging until their timeout. Covers `completed`
                // (another client already applied), as well as `failed`
                // / `terminated` / `error`.
                let status = event.status.lowercased()
                if status == "completed"
                    || status == "failed"
                    || status == "terminated"
                    || status == "error" {
                    Task { [weak self] in
                        await self?.workflows.handleTerminalEvent(event)
                    }
                }
            }

        case "invitation":
            events.emit(.invitation, json)

        case "meUpdated":
            events.emit(.meUpdated, json)

        default:
            logger.debug("Unhandled WS message:", action)
        }
    }

    /// Queue and debounce local document updates for sending
    func queueOutboundUpdate(documentId: String, update: [UInt8]) {
        lock.lock()
        var updates = pendingUpdates[documentId] ?? []
        updates.append(update)
        pendingUpdates[documentId] = updates

        // Cancel existing timer
        outboundDebounceTimers[documentId]?.cancel()

        let debounceMs = options.sync.outboundDebounceMs
        outboundDebounceTimers[documentId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(debounceMs) * 1_000_000)
            await self?.flushOutboundUpdates(documentId: documentId)
        }
        lock.unlock()
    }

    private func flushOutboundUpdates(documentId: String) async {
        lock.lock()
        guard let updates = pendingUpdates.removeValue(forKey: documentId), !updates.isEmpty else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Send each update
        for update in updates {
            await documentManager.sendLocalUpdate(documentId: documentId, update: update)
        }
    }
}

// MARK: - WebSocketManagerDelegate

extension JsBaoClient: WebSocketManagerDelegate {
    public func webSocketManagerHasAccessToken() -> Bool {
        authController.getToken() != nil
    }

    public func webSocketManagerBuildConnectionRequest(connectionId: String) -> (url: URL, headers: [String: String]) {
        // The server expects the token as a query parameter, not an Authorization header.
        // This matches the JS client's buildWebSocketRequest() behavior.
        //
        // SECURITY NOTE: Tokens in URL query parameters can leak into server access
        // logs, proxy/CDN logs, and (in WKWebView contexts) browser history. The
        // browser-based JS client has no choice — the WebSocket spec forbids custom
        // headers on the upgrade request from JS — but native clients (Swift) can
        // use Authorization headers. Migrating away from query-param auth requires
        // a coordinated server + JS client change (the server must accept either
        // form during the rollout); tracked as a follow-up rather than fixed here
        // so the Swift client stays protocol-compatible with the existing server.
        var components = URLComponents(string: "\(options.wsUrl)/app/\(options.appId)/ws")!
        var queryItems = [
            URLQueryItem(name: "connectionId", value: connectionId),
        ]
        if let token = authController.getToken() {
            queryItems.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = queryItems

        var headers = options.wsHeaders
        headers["X-Global-Admin-App-Id"] = options.globalAdminAppId

        let url = components.url ?? URL(string: options.wsUrl)!
        return (url, headers)
    }

    public func webSocketManagerOnStatusChange(_ status: ConnectionStatus) {
        events.emit(.status, StatusChangedEvent(status: status))
        if status == .connected {
            lock.lock()
            lastOnlineAt = Date()
            lock.unlock()
        }
    }

    public func webSocketManagerOnConnecting() {
        logger.debug("WebSocket connecting...")
    }

    public func webSocketManagerOnConnected() {
        logger.log("WebSocket connected")
        // Re-subscribe to all open documents
        let docIds = documentManager.listOpenDocuments()
        Task {
            for docId in docIds {
                await startNetworkSync(documentId: docId)
            }
            // Flush analytics
            analyticsQueue.flush()
            // Any per-run waiter installed by runAndApply/awaitRun may
            // have missed its workflowStatus event while we were
            // offline. Re-check each against server state.
            await workflows.recheckPendingRuns()
        }
    }

    public func webSocketManagerOnMessage(_ data: Data) async {
        if let text = String(data: data, encoding: .utf8) {
            await handleWebSocketMessage(text)
        }
    }

    public func webSocketManagerOnMessage(_ text: String) async {
        await handleWebSocketMessage(text)
    }

    public func webSocketManagerOnClose(code: Int?, reason: String?) {
        logger.log("WebSocket closed:", code ?? 0, reason ?? "")
        events.emit(.status, StatusChangedEvent(status: .disconnected))
    }

    public func webSocketManagerOnError(_ error: Error) {
        logger.warn("WebSocket error:", error.localizedDescription)
    }

    public func webSocketManagerOnReconnectScheduled(delayMs: Int) {
        logger.debug("WebSocket reconnect in \(delayMs)ms")
    }

    public func webSocketManagerOnDisconnectInitiated() {
        logger.debug("WebSocket disconnect initiated")
    }

    public func webSocketManagerOnDisconnectResolved() {
        logger.debug("WebSocket disconnect resolved")
    }

    public func webSocketManagerShouldReconnect(code: Int?, reason: String?) -> Bool {
        // Don't reconnect on auth failures
        if code == 4001 || code == 4003 { return false }
        return isOnline()
    }
}

// MARK: - DocumentContext

/// Scoped helper for operations on a single document.
public final class DocumentContext: @unchecked Sendable {
    public let documentId: String
    private weak var client: JsBaoClient?
    private let blobManager: BlobManager
    private let makeRequestFn: (String, String, Any?) async throws -> Any

    public init(
        documentId: String,
        client: JsBaoClient,
        blobManager: BlobManager,
        makeRequest: @escaping (String, String, Any?) async throws -> Any
    ) {
        self.documentId = documentId
        self.client = client
        self.blobManager = blobManager
        self.makeRequestFn = makeRequest
    }

    public func open(options: OpenDocumentOptions = OpenDocumentOptions()) async throws -> YDocument {
        guard let client = client else { throw JsBaoError(code: .unavailable) }
        return try await client.openDocument(documentId, options: options)
    }

    public func close(options: CloseDocumentOptions = CloseDocumentOptions()) async {
        await client?.closeDocument(documentId, options: options)
    }

    public func getDoc() -> YDocument? {
        client?.getDoc(documentId)
    }

    public func isSynced() -> Bool {
        client?.isSynced(documentId) ?? false
    }

    public func blobs() -> DocumentBlobContext {
        DocumentBlobContext(
            documentId: documentId,
            makeRequest: makeRequestFn,
            blobManager: blobManager
        )
    }
}
