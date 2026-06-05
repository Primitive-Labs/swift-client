import Foundation
import YSwift
import Yniffi
#if canImport(UIKit)
import UIKit
#endif

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
    public private(set) var auth: AuthAPI!
    public private(set) var llm: LlmAPI!
    public private(set) var gemini: GeminiAPI!
    public private(set) var users: UsersAPI!
    public private(set) var groups: GroupsAPI!
    public private(set) var ruleSets: RuleSetsAPI!
    public private(set) var groupTypeConfigs: GroupTypeConfigsAPI!
    public private(set) var integrations: IntegrationsAPI!
    public private(set) var prompts: PromptsAPI!
    public private(set) var workflows: WorkflowsAPI!
    public private(set) var invitations: InvitationsAPI!
    public private(set) var blobBuckets: BlobBucketsAPI!
    public private(set) var cronTriggers: CronTriggersAPI!
    public private(set) var collectionTypeConfigs: CollectionTypeConfigsAPI!
    public private(set) var databaseTypeConfigs: DatabaseTypeConfigsAPI!
    public private(set) var analytics: AnalyticsAPI!

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

    // MARK: Analytics session lifecycle (#963)

    /// Timestamp the current analytics session started. Stamped at init;
    /// the `session_end` event's `duration_ms` is measured against it.
    /// Mirrors js-bao's `sessionStartAt`.
    private var sessionStartAt: Date = Date()
    /// Guards against logging `session_end` more than once (e.g. both a
    /// background notification and `destroy()` firing). Mirrors js-bao's
    /// `sessionEndLogged`.
    private var sessionEndLogged = false
    /// `NotificationCenter` observer tokens for app-lifecycle flush, only
    /// populated on UIKit platforms. Removed in `destroy()` / `deinit`.
    private var lifecycleObservers: [NSObjectProtocol] = []

    // MARK: Per-feature analytics auto-events (#963)

    /// In-memory mirror of the persisted analytics auto-events metadata
    /// (`OfflineStore.AnalyticsMetadataRecord`). Drives the dailyAuth/
    /// returnActive guards. Mirrors js-bao's `analyticsMetadataState`.
    /// Guarded by `lock`.
    private var lastDailyAuthDate: String?
    private var lastReturnActiveAt: Date?
    /// True once the persisted metadata has been hydrated into the in-memory
    /// mirror for the current user. Reset when the user changes.
    private var analyticsMetadataHydrated = false
    /// The user the in-memory metadata mirror was hydrated for. Mirrors
    /// js-bao's `analyticsMetadataUserId`.
    private var analyticsMetadataUserId: String?
    /// Monotonic guard for the `sync_error` rate limit. Mirrors js-bao's
    /// `lastSyncErrorEventAt`. Guarded by `lock`.
    private var lastSyncErrorEventAt: Date?
    /// One-shot guards so each blob upload only logs start/success/failure
    /// once. Keyed by blobId. Mirror js-bao's `blobUpload*Logged` Sets.
    private var blobUploadStartLogged: Set<String> = []
    private var blobUploadSuccessLogged: Set<String> = []
    private var blobUploadFailureLogged: Set<String> = []
    /// Subscriptions for the emitter-driven auto-events (blob lifecycle,
    /// commit failures, auth success). Cancelled on `destroy()` / `deinit`.
    private var analyticsEventSubscriptions: [EventSubscription] = []

    /// One shared cross-document store per registered model, keyed by
    /// `modelName`. Mirrors js-bao's static `BaseModel.dbInstance` +
    /// `connectedDocuments` registry: every open document is connected to
    /// each store, so `Model.query()` spans all open docs by default.
    /// Guarded by `lock`.
    private var sharedModels: [String: MultiDocModel] = [:]

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

        // Analytics session starts now (#963). Reset point would be an
        // auth-success handler, but the Swift client has none today, so
        // the init stamp is the session origin.
        sessionStartAt = Date()
        registerLifecycleObservers()
        registerAnalyticsAutoEventObservers()
    }

    deinit {
        // Safety net for clients dropped without an explicit destroy():
        // the NotificationCenter tokens must be removed so the closures
        // (which capture self weakly) aren't left registered. destroy()
        // already removes them on the normal teardown path.
        removeLifecycleObservers()
        removeAnalyticsAutoEventObservers()
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

    // MARK: - Auth / OAuth config (gap P1)

    /// Returns the raw `/oauth-config` envelope: `appId`, `name`, `mode`,
    /// `waitlistEnabled`, `googleOAuthEnabled`, `googleClientId`,
    /// `hasOAuth`, `redirectUris`, `passkeyEnabled`, `passkeyRpId`,
    /// `passkeyRpName`, `hasPasskey`, `magicLinkEnabled`, `otpEnabled`.
    /// Mirrors js-bao's `client.getAuthConfig()`.
    public func getAuthConfig() async throws -> [String: Any] {
        let result = try await makeRequest("GET", "/oauth-config", nil)
        return result as? [String: Any] ?? [:]
    }

    /// App-level config bundle (`appId`, `name`, `mode`,
    /// `waitlistEnabled`, `hasOAuth`, `hasPasskey`, `magicLinkEnabled`).
    /// Subset of `getAuthConfig()` shaped for the app-launch UI.
    /// Matches js-bao's `client.getAppConfig()`.
    public func getAppConfig() async throws -> [String: Any] {
        let cfg = try await getAuthConfig()
        return [
            "appId": cfg["appId"] ?? "",
            "name": cfg["name"] ?? "",
            "mode": cfg["mode"] ?? "public",
            "waitlistEnabled": cfg["waitlistEnabled"] ?? false,
            "hasOAuth": cfg["hasOAuth"] ?? false,
            "hasPasskey": cfg["hasPasskey"] ?? false,
            "magicLinkEnabled": cfg["magicLinkEnabled"] ?? false,
        ]
    }

    /// Boolean predicate: is OAuth set up + configured for this app?
    /// Mirrors js-bao's `client.checkOAuthAvailable()` — wraps
    /// `getAuthConfig` and checks `hasOAuth && googleClientId`.
    public func checkOAuthAvailable() async -> Bool {
        guard let cfg = try? await getAuthConfig() else { return false }
        let hasOAuth = cfg["hasOAuth"] as? Bool ?? false
        let googleClientId = cfg["googleClientId"] as? String
        return hasOAuth && googleClientId?.isEmpty == false
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

    /// Wait for authentication to be ready. Mirrors js-bao's
    /// `client.waitForAuthReady()` return shape: `(userId, mode)`.
    /// The previous Void return matched neither the JS surface nor
    /// the cross-platform code that switches on `mode`.
    @discardableResult
    public func waitForAuthReady(
        timeout: TimeInterval = 10
    ) async throws -> (userId: String?, mode: NetworkMode) {
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
        let state = authController.getAuthState()
        return (userId: state.userId, mode: state.mode)
    }

    /// Wait for user ID to be available
    public func waitForUserId(timeout: TimeInterval = 10) async throws -> String {
        try await waitForAuthReady(timeout: timeout)
        guard let userId = authController.getUserId() else {
            throw AuthError(code: .unauthorized, message: "Not authenticated")
        }
        return userId
    }

    // MARK: - Predicates + getters (P2)

    /// `true` iff `documentId` is the app's root doc. Mirrors js-bao's
    /// `client.isRootDocument(documentId)`. Local-only — reads
    /// `rootDocId` straight from the JWT payload (no network, no
    /// async).
    public func isRootDocument(_ documentId: String) -> Bool {
        guard let root = rootDocIdFromJwt() else { return false }
        return root == documentId
    }

    /// Sync read of `rootDocId` from the parsed JWT payload, matching
    /// js-bao's `payload.user.rootDocId || payload.rootDocId` lookup.
    /// `nil` if no token is loaded or neither field is set. Internal
    /// helper used by `getRootDocId(refresh:)` and `isRootDocument`.
    private func rootDocIdFromJwt() -> String? {
        guard let payload = authController.getJwtPayload() else { return nil }
        if let user = payload["user"] as? [String: Any],
           let root = user["rootDocId"] as? String, !root.isEmpty {
            return root
        }
        if let root = payload["rootDocId"] as? String, !root.isEmpty {
            return root
        }
        return nil
    }

    /// Y.Doc state hash for an open document. Used for cache-validity
    /// checks (the WebSocket sync protocol echoes this hash). Throws
    /// `notFound` if the doc isn't open. Matches js-bao's
    /// `client.getDocHash(documentId)`.
    public func getDocHash(documentId: String) throws -> String {
        guard let hash = documentManager.getDocHash(documentId: documentId) else {
            throw JsBaoError(
                code: .notFound,
                message: "Document `\(documentId)` is not open"
            )
        }
        return hash
    }

    /// Top-level convenience wrapper around
    /// `documents.getDocumentPermission(documentId:)`. js-bao exposes
    /// this on the client root, which is the call site cross-platform
    /// code tends to use.
    public func getDocumentPermission(_ documentId: String) -> DocumentPermission? {
        documentManager.getPermission(documentId)
    }

    /// Discover the `PrimitiveSchema`s present in an open doc, keyed
    /// by model name. Walks the `_meta_*` Y.Maps the SchemaSync layer
    /// reads.
    ///
    /// **Swift-specific shape**: js-bao calls this with just a doc id
    /// and enumerates every top-level shared type. The current Yrs FFI
    /// on Swift doesn't expose `Doc.root_refs()`, so callers have to
    /// supply the candidate `modelNames` list. Names without `_meta_*`
    /// data simply don't appear in the result.
    ///
    /// Returns `nil` if the doc isn't open.
    public func getDocumentSchema(
        documentId: String,
        modelNames: [String]
    ) -> [String: PrimitiveSchema]? {
        guard let doc = documentManager.getDocument(documentId) else { return nil }
        return SchemaDiscovery.discoverSchema(
            doc: doc, modelNames: modelNames
        ).models
    }

    // MARK: - Model mappings + default doc (P2)
    //
    // Swift's `BaoModel<T>` and `DynamicModel` take the YDocument
    // explicitly, so the JS-style "default doc + model registry" isn't
    // strictly needed — but cross-platform code that calls
    // `setDefaultDocumentId` / `addDocumentModelMapping` should still
    // work. We store the mappings on the client and expose them to
    // callers that want to consult the registry; nothing else in Swift
    // reads them automatically.

    private var modelToDocumentId: [String: String] = [:]
    private var defaultDocumentId: String?

    /// Register `modelName → documentId` so a later
    /// `getDocumentModelMapping(modelName)` returns this doc. Throws
    /// `notFound` if the doc isn't open. Mirrors js-bao's
    /// `client.addDocumentModelMapping(modelName, documentId)`.
    public func addDocumentModelMapping(
        modelName: String, documentId: String
    ) throws {
        guard documentManager.isOpen(documentId) else {
            throw JsBaoError(
                code: .notFound,
                message: "Document `\(documentId)` is not open. " +
                         "Open the document before mapping a model to it."
            )
        }
        lock.lock()
        modelToDocumentId[modelName] = documentId
        lock.unlock()
    }

    /// Remove a `modelName → documentId` mapping. No-op if none exists.
    public func clearDocumentModelMapping(modelName: String) {
        lock.lock()
        modelToDocumentId.removeValue(forKey: modelName)
        lock.unlock()
    }

    /// Resolve a `modelName` to its registered doc, or the default
    /// doc if no per-model mapping exists. Returns `nil` if neither
    /// is set. Matches js-bao's `getDocumentIdForModel` /
    /// `getDocumentModelMapping`.
    public func getDocumentModelMapping(modelName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return modelToDocumentId[modelName] ?? defaultDocumentId
    }

    /// Set the doc used as a fallback when no per-model mapping
    /// applies. Throws `notFound` if the doc isn't open.
    public func setDefaultDocumentId(_ documentId: String) throws {
        guard documentManager.isOpen(documentId) else {
            throw JsBaoError(
                code: .notFound,
                message: "Document `\(documentId)` is not open. " +
                         "Open the document before setting it as the default."
            )
        }
        lock.lock()
        defaultDocumentId = documentId
        lock.unlock()
    }

    public func clearDefaultDocumentId() {
        lock.lock()
        defaultDocumentId = nil
        lock.unlock()
    }

    public func getDefaultDocumentId() -> String? {
        lock.lock()
        let id = defaultDocumentId
        lock.unlock()
        return id
    }

    // MARK: - Cross-document model store (parity with js-bao `initJsBao({ models })`)
    //
    // js-bao keeps one process-wide SQLite mirror (`BaseModel.dbInstance`)
    // + a registry of every open `Y.Doc`, so `TodoItem.query()` spans all
    // open documents transparently. Swift's equivalent is one shared store
    // per model, owned here on the client, with every open document
    // auto-connected on `openDocument`/`createDocument` and disconnected on
    // `closeDocument`.
    //
    // App code never touches the store directly — it goes through the
    // codegen'd static facade on the model type:
    //   • reads (cross-doc):  `TodoItem.query()` / `.count()` / `.find(id)`
    //   • reads (one doc):    `TodoItem.query(options: .init(documents:[id]))`
    //   • writes (one doc):   `try TodoItem.create(value, in: docId)` etc.
    // The facade forwards to the `*Shared` methods below on the configured
    // default client (see `configureDefault`). The store type
    // (`MultiDocModel`) is internal plumbing.

    /// Get-or-create the shared cross-document store for `schema`, lazily
    /// registering the model (and connecting every already-open document)
    /// on first use. Internal — app code uses the codegen'd `Model.*` facade.
    @discardableResult
    func sharedModel(for schema: PrimitiveSchema) -> MultiDocModel {
        lock.lock()
        if let existing = sharedModels[schema.name] {
            lock.unlock()
            return existing
        }
        let model = MultiDocModel(schema: schema)
        sharedModels[schema.name] = model
        lock.unlock()
        // Connect docs opened before this model was registered. Done
        // outside `lock` because `connect` takes the document manager's
        // lock; holding both risks a lock-ordering inversion.
        for entry in documentManager.openDocumentsSnapshot() {
            model.connect(docId: entry.documentId, doc: entry.doc)
        }
        return model
    }

    /// The shared store for an already-registered model, or `nil`. Internal.
    func sharedModel(_ modelName: String) -> MultiDocModel? {
        lock.lock()
        defer { lock.unlock() }
        return sharedModels[modelName]
    }

    // MARK: Shared-store CRUD (backs the codegen'd `Model.*` facade)
    //
    // Schema + dict shaped (no generics) so the generated per-type facade
    // does the typed mapping (`Model(row:)`) and supplies `primitiveValues()`.
    // Reads span every open doc by default; pass `options.documents` to scope.
    // Writes target one document and throw if it isn't open.

    /// Cross-document query → raw rows. The facade maps rows to the model type.
    public func queryShared(
        _ schema: PrimitiveSchema,
        filter: DocumentFilter? = nil,
        options: QueryOptions? = nil
    ) -> [[String: Any]] {
        sharedModel(for: schema).query(filter, options: options)
    }

    /// Cross-document paginated query → raw rows + cursors. The facade maps
    /// rows to the model type while preserving `nextCursor`/`prevCursor`/
    /// `hasMore` — so a caller passing `options.cursor`/`options.limit` can
    /// actually obtain the next page. Mirrors js-bao's `BaseModel.query()`
    /// return shape (#946); `queryShared` stays the flat-array convenience.
    public func queryPagedShared(
        _ schema: PrimitiveSchema,
        filter: DocumentFilter? = nil,
        options: QueryOptions? = nil
    ) throws -> PagedQueryResult<[String: Any]> {
        try sharedModel(for: schema).queryPaged(filter, options: options)
    }

    /// Cross-document count.
    public func countShared(_ schema: PrimitiveSchema, filter: DocumentFilter? = nil) -> Int {
        sharedModel(for: schema).count(filter)
    }

    /// First record with `id` across every open doc (raw row), or `nil`.
    public func findShared(_ schema: PrimitiveSchema, id: String) -> [String: Any]? {
        sharedModel(for: schema).find(id: id)?.row
    }

    /// Subscribe to any add/update/delete in any open doc's copy of the model.
    public func subscribeShared(
        _ schema: PrimitiveSchema, _ callback: @escaping () -> Void
    ) -> () -> Void {
        sharedModel(for: schema).subscribe(callback)
    }

    /// Aggregate (group / count / sum / avg / …) across every open document.
    public func aggregateShared(
        _ schema: PrimitiveSchema, options: AggregateOptions
    ) -> [[String: Any]] {
        sharedModel(for: schema).aggregate(options)
    }

    /// Create-or-update a record in document `docId` — insert if it doesn't
    /// exist yet, update in place if it does (one call, mirrors js-bao's
    /// `BaseModel.save`). Throws if the doc isn't open.
    public func saveShared(
        _ schema: PrimitiveSchema, id: String,
        values: [String: PrimitiveValue], in docId: String
    ) throws {
        _ = try requireMember(schema, in: docId).save(id: id, values: values)
    }

    /// First record matching a unique `constraint` and `value` across every
    /// open doc (raw row), or `nil`. Mirrors js-bao's `BaseModel.findByUnique`.
    public func findByUniqueShared(
        _ schema: PrimitiveSchema, constraint: String, value: PrimitiveValue
    ) throws -> [String: Any]? {
        try sharedModel(for: schema).findByUnique(constraint: constraint, value: value)?.row
    }

    /// First record matching `filter` across every open doc (raw row), or
    /// `nil` — `queryShared(...).first`. Mirrors js-bao's `BaseModel.queryOne`.
    public func queryOneShared(
        _ schema: PrimitiveSchema,
        filter: DocumentFilter? = nil,
        options: QueryOptions? = nil
    ) -> [String: Any]? {
        sharedModel(for: schema).query(filter, options: options).first
    }

    /// Insert-or-update a record in document `docId`, matched by the
    /// single-field unique constraint on `field` — mirrors js-bao's
    /// `save({ upsertOn: field })`. Throws if the doc isn't open.
    public func upsertShared(
        _ schema: PrimitiveSchema, id: String,
        values: [String: PrimitiveValue], on field: String, in docId: String
    ) throws {
        _ = try requireMember(schema, in: docId).upsert(values, on: field, id: id)
    }

    /// Delete a record from document `docId`. Throws if the doc isn't open.
    public func deleteShared(_ schema: PrimitiveSchema, id: String, in docId: String) throws {
        try requireMember(schema, in: docId).delete(id: id)
    }

    /// Every connected `(model, document)` member of the shared store, for
    /// the debug inspector. Each entry is the per-doc writer for one model in
    /// one open document — so the inspector can surface cross-document data
    /// without apps binding per-doc models by hand.
    public func inspectableSharedMembers() -> [(modelName: String, documentId: String, model: DynamicModel)] {
        lock.lock()
        let models = sharedModels
        lock.unlock()
        var out: [(modelName: String, documentId: String, model: DynamicModel)] = []
        for (name, shared) in models {
            for docId in shared.connectedDocIds {
                if let member = shared.member(docId: docId) {
                    out.append((modelName: name, documentId: docId, model: member))
                }
            }
        }
        return out
    }

    /// Resolve the per-doc writer for a model. The member only exists while
    /// the document is open (connected to the shared store), so a closed
    /// doc throws — opening is always an explicit step (matches js-bao).
    private func requireMember(_ schema: PrimitiveSchema, in docId: String) throws -> DynamicModel {
        guard let member = sharedModel(for: schema).member(docId: docId) else {
            throw JsBaoError(
                code: .notFound,
                message: "Document `\(docId)` is not open. Open it " +
                         "(client.openDocument) before writing `\(schema.name)` records."
            )
        }
        return member
    }

    /// Pre-register models so the client maintains a shared cross-document
    /// store for each and connects documents opened *after* this call.
    /// Mirrors js-bao's `initJsBao({ models })`. Idempotent. Optional — the
    /// generated `Model.query()` facade lazily registers on first use — but
    /// recommended at startup so a document opened before any query is
    /// already mirrored.
    public func registerModels(_ schemas: [PrimitiveSchema]) {
        for schema in schemas { _ = sharedModel(for: schema) }
    }

    /// `PrimitiveModel.Type` overload: `client.registerModels([TodoRecord.self, …])`.
    public func registerModels(_ types: [any PrimitiveModel.Type]) {
        registerModels(types.map { $0.primitiveSchema })
    }

    /// Connect a freshly-opened document to every registered shared store.
    /// Called from the open/create paths; safe to call repeatedly (a
    /// re-connect re-seeds the doc's rows).
    private func connectToSharedModels(documentId: String, doc: YDocument) {
        lock.lock()
        let models = Array(sharedModels.values)
        lock.unlock()
        for model in models { model.connect(docId: documentId, doc: doc) }
    }

    /// Drop a closing document's rows from every shared store so later
    /// cross-document reads don't return stale state.
    private func disconnectFromSharedModels(documentId: String) {
        lock.lock()
        let models = Array(sharedModels.values)
        lock.unlock()
        for model in models { model.disconnect(docId: documentId) }
    }

    // MARK: - Default client (backs the codegen'd `Model.query()` facade)

    private static let defaultClientLock = NSLock()
    private static var _defaultClient: JsBaoClient?

    /// Configure the process-wide default client that the codegen'd static
    /// query facade (`TodoRecord.query()`, `.count()`, `.findAll()`,
    /// `.subscribe(_:)`) reads. Call once after constructing your client —
    /// in a `PrimitiveApp` host this is wired for you. Replacing it (e.g.
    /// across a sign-out/sign-in) is allowed.
    public static func configureDefault(_ client: JsBaoClient) {
        defaultClientLock.lock()
        _defaultClient = client
        defaultClientLock.unlock()
    }

    /// The configured default client, or `nil` if `configureDefault` was
    /// never called.
    public static var `default`: JsBaoClient? {
        defaultClientLock.lock()
        defer { defaultClientLock.unlock() }
        return _defaultClient
    }

    /// Clear the default client. Mainly for test teardown.
    public static func clearDefault() {
        defaultClientLock.lock()
        _defaultClient = nil
        defaultClientLock.unlock()
    }

    /// The default client or a precondition failure with remediation. Used
    /// by the codegen'd facade — a missing default is a setup bug, so we
    /// fail loudly rather than silently returning no rows (which reads as
    /// "no data" and hides the cause).
    public static func requireDefault(
        file: StaticString = #fileID, line: UInt = #line
    ) -> JsBaoClient {
        guard let client = `default` else {
            preconditionFailure(
                "No default JsBaoClient configured. Call " +
                "JsBaoClient.configureDefault(client) at startup before " +
                "using a generated Model.query()/count()/findAll(). In a " +
                "PrimitiveApp host this is wired during initialize().",
                file: file, line: line
            )
        }
        return client
    }

    // MARK: - Analytics context helpers (P2)
    //
    // js-bao exposes per-feature analytics context bundles so the LLM
    // / Gemini call paths can log structured events. On Swift those
    // sites just delegate to `logAnalyticsEvent` directly today; the
    // bundles below are wrappers that match the JS shape so cross-
    // platform code can call `client.getLlmAnalyticsContext()?.logEvent(...)`
    // identically.

    /// Returns a logger handle for LLM analytics, or `nil` when the
    /// auto-events config for `llm` is fully disabled. The handle has
    /// the same shape as js-bao's: `logEvent(event)` and
    /// `isEnabled(phase?)`.
    public func getLlmAnalyticsContext() -> AnalyticsContext? {
        // Auto-events config isn't a typed option on Swift yet; if it
        // lands, swap this for the real flag-walk. For now always
        // return a context so cross-platform callers don't no-op.
        return AnalyticsContext { [weak self] event in
            self?.logAnalyticsEvent(event)
        }
    }

    /// Returns a logger handle for Gemini analytics — same shape as
    /// `getLlmAnalyticsContext()`.
    public func getGeminiAnalyticsContext() -> AnalyticsContext? {
        return AnalyticsContext { [weak self] event in
            self?.logAnalyticsEvent(event)
        }
    }

    // MARK: - Top-level offline-metadata browsing (gap 14)

    /// List metadata for all docs the local store has persisted.
    /// Returns one entry per documentId. Matches js-bao's
    /// `client.listLocalDocuments()`.
    public func listLocalDocuments() -> [String: LocalMetadataEntry] {
        documentManager.getMetadataIndex()
    }

    /// Evict a single doc's local data from this device. Background;
    /// the call returns once the eviction task is scheduled.
    public func evictLocalDocument(_ documentId: String) async {
        await documentManager.evictLocalData(documentId: documentId)
    }

    /// Storage for the active retention policy. Applied immediately
    /// when set; subsequent doc opens / persists update the
    /// `lastOpenedAt` and `localBytes` fields that enforcement reads.
    private var retentionPolicy: RetentionPolicy = .init()

    /// Apply a retention policy that bounds the local document store.
    ///
    /// - `ttlMs`: docs whose `lastOpenedAt` is older than this are
    ///   evicted on the next enforcement pass.
    /// - `maxDocs`: only the most-recently-opened N docs are kept.
    /// - `maxBytes`: oldest docs are evicted until total `localBytes`
    ///   fits the budget.
    /// - `default`/`preserveOnSignOut`: stored for parity with js-bao's
    ///   shape; not yet enforced (matches JS — those fields are set
    ///   but not consumed by `enforceRetentionPolicy` either).
    ///
    /// Enforcement runs immediately and again as docs open/close
    /// (which is when `lastOpenedAt` / `localBytes` shift).
    public func setRetentionPolicy(_ policy: RetentionPolicy) {
        lock.lock()
        retentionPolicy = policy
        lock.unlock()
        Task { [policy, weak self] in
            await self?.documentManager.enforceRetentionPolicy(
                ttlMs: policy.ttlMs,
                maxDocs: policy.maxDocs,
                maxBytes: policy.maxBytes
            )
        }
    }

    /// Inspect the active retention policy.
    public func getRetentionPolicy() -> RetentionPolicy {
        lock.lock()
        defer { lock.unlock() }
        return retentionPolicy
    }

    /// Mark a doc as deleted locally — wipes the in-memory metadata
    /// entry and removes the persisted offline-store record.
    ///
    /// **Note on JS parity:** js-bao's `client.markMetadataDeleted`
    /// only records a dedup-tombstone timestamp and does NOT wipe
    /// local data (that's done separately via `evictLocalDocument`).
    /// Swift intentionally diverges here: callers want data actually
    /// gone, not just marked. If you only need the dedup signal in
    /// cross-platform code, call this method conditionally on the
    /// platform.
    public func markMetadataDeleted(_ documentId: String) async {
        await documentManager.evictLocalData(documentId: documentId)
    }

    // MARK: - waitFor* family (gap 12)
    //
    // Mirrors the JS client's UX waiters. Implementations poll the
    // underlying state on a short interval rather than installing
    // dedicated subscribers — the JS counterparts use the same
    // pattern internally, just with a Promise/observable wrapper.
    // Polling cap defaults to 200ms; callers that need finer granularity
    // can drop the interval.

    /// Wait until `isSynced(documentId)` reports true (initial sync
    /// completed for the doc). Throws `unavailable` on timeout.
    public func waitForInitialSync(
        documentId: String,
        timeoutMs: Int = 10_000,
        pollMs: Int = 200
    ) async throws {
        try await pollUntil(timeoutMs: timeoutMs, pollMs: pollMs) {
            self.documentManager.isSynced(documentId)
        }
    }

    /// One-shot sync gate: returns as soon as the doc reports synced
    /// once. Alias for `waitForInitialSync` in this Swift surface —
    /// JS treats them slightly differently around reconnect (JS resets
    /// the gate on disconnect; Swift's `isSynced` already does), so
    /// they're behaviorally identical here.
    ///
    /// Deprecated — mirrors js-bao's `@deprecated` on `waitForSync`.
    @available(*, deprecated, message: "Use waitForInitialSync(documentId:timeoutMs:pollMs:) instead.")
    public func waitForSync(
        documentId: String,
        timeoutMs: Int = 10_000,
        pollMs: Int = 200
    ) async throws {
        try await waitForInitialSync(
            documentId: documentId, timeoutMs: timeoutMs, pollMs: pollMs
        )
    }

    /// Continuous sync gate: waits until the doc is synced *and stays
    /// synced* through one poll cycle past the first true reading.
    /// Matches js-bao's `waitForInSync` semantics where the consumer
    /// needs to be sure the doc isn't about to flip back to syncing.
    public func waitForInSync(
        documentId: String,
        timeoutMs: Int = 10_000,
        pollMs: Int = 200
    ) async throws {
        var stableReadings = 0
        let stableTarget = 2  // two consecutive true readings
        try await pollUntil(timeoutMs: timeoutMs, pollMs: pollMs) {
            if self.documentManager.isSynced(documentId) {
                stableReadings += 1
                return stableReadings >= stableTarget
            }
            stableReadings = 0
            return false
        }
    }

    /// Wait until any pending local writes for the doc have been
    /// acknowledged by the server. Implementation: a sync gate, since
    /// `isSynced` flips to true only after both inbound and outbound
    /// sync drains. Mirrors js-bao's
    /// `waitForWriteConfirmation(docId, timeoutMs)`.
    public func waitForWriteConfirmation(
        documentId: String,
        timeoutMs: Int = 10_000,
        pollMs: Int = 200
    ) async throws {
        try await waitForInSync(
            documentId: documentId, timeoutMs: timeoutMs, pollMs: pollMs
        )
    }

    // MARK: - State-vector check (inSync / includesWrites)
    //
    // A live round-trip against the server: send the doc's Yjs state
    // vector and await the `stateVectorCheckResponse` carrying
    // `includesWrites` / `inSync`. Mirrors js-bao's `checkStateVector`.
    // Disconnected → (false, false); no local doc → (true, true);
    // timeout → (false, false). Continuations are parked in a
    // lock-guarded array keyed by documentId, the same pattern
    // `WebSocketManager` uses for its connect/disconnect waiters.

    private struct StateVectorWaiter {
        let id: UUID
        let continuation: CheckedContinuation<(includesWrites: Bool, inSync: Bool), Never>
    }

    private let stateVectorLock = NSLock()
    private var stateVectorWaiters: [String: [StateVectorWaiter]] = [:]

    /// Send the local state vector to the server and await its verdict on
    /// whether the server holds all of this client's writes
    /// (`includesWrites`) and whether both sides are identical (`inSync`).
    /// Mirrors js-bao's `checkStateVector(documentId, timeoutMs)`.
    public func checkStateVector(
        documentId: String,
        timeoutMs: Int = 5_000
    ) async -> (includesWrites: Bool, inSync: Bool) {
        guard wsManager.isSocketOpen else { return (false, false) }
        guard let stateVector = documentManager.encodeStateVectorBase64(documentId) else {
            // No local doc — nothing of ours to lose.
            return (true, true)
        }

        let message: [String: Any] = [
            "type": "stateVectorCheck",
            "documentId": documentId,
            "stateVector": stateVector,
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return (false, false)
        }

        let waiterId = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<(includesWrites: Bool, inSync: Bool), Never>) in
            stateVectorLock.lock()
            stateVectorWaiters[documentId, default: []].append(
                StateVectorWaiter(id: waiterId, continuation: continuation)
            )
            stateVectorLock.unlock()

            // Resolve to a failure verdict if no response lands in time.
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { [weak self] in
                self?.resolveStateVectorWaiter(id: waiterId, documentId: documentId, result: (false, false))
            }

            // Fire the request; a send failure also resolves to failure.
            Task { [weak self] in
                do {
                    try await self?.wsManager.send(jsonString)
                } catch {
                    self?.resolveStateVectorWaiter(id: waiterId, documentId: documentId, result: (false, false))
                }
            }
        }
    }

    /// Resume a single pending waiter (by id) exactly once. The atomic
    /// remove-under-lock guarantees the timeout and the server response
    /// can't both resume the same continuation.
    private func resolveStateVectorWaiter(
        id: UUID,
        documentId: String,
        result: (includesWrites: Bool, inSync: Bool)
    ) {
        stateVectorLock.lock()
        guard var waiters = stateVectorWaiters[documentId],
              let idx = waiters.firstIndex(where: { $0.id == id }) else {
            stateVectorLock.unlock()
            return
        }
        let waiter = waiters.remove(at: idx)
        if waiters.isEmpty {
            stateVectorWaiters.removeValue(forKey: documentId)
        } else {
            stateVectorWaiters[documentId] = waiters
        }
        stateVectorLock.unlock()
        waiter.continuation.resume(returning: result)
    }

    /// Route an incoming `stateVectorCheckResponse` to every waiter parked
    /// on this document.
    private func handleStateVectorCheckResponse(
        documentId: String,
        includesWrites: Bool,
        inSync: Bool
    ) {
        stateVectorLock.lock()
        let waiters = stateVectorWaiters.removeValue(forKey: documentId) ?? []
        stateVectorLock.unlock()
        for waiter in waiters {
            waiter.continuation.resume(returning: (includesWrites, inSync))
        }
    }

    /// Initial-auth-flow handoff. Returns once the auth controller's
    /// bootstrap settles (either authenticated or the offline grace
    /// window confirms the user can keep going). Differs from
    /// `waitForAuthReady` in that `waitForAuthReady` returns on
    /// *online* readiness; `waitForAuthBootstrap` returns on either
    /// online OR offline-with-grant.
    public func waitForAuthBootstrap(timeout: TimeInterval = 10) async throws {
        try await pollUntil(
            timeoutMs: Int(timeout * 1000), pollMs: 100
        ) {
            let state = self.authController.getAuthState()
            return state.authenticated || state.mode == .offline
        }
    }

    /// Common polling loop used by every `waitFor*` above. Returns when
    /// `predicate()` first returns true. Throws `unavailable` if the
    /// timeout elapses first.
    private func pollUntil(
        timeoutMs: Int,
        pollMs: Int,
        predicate: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: UInt64(pollMs) * 1_000_000)
        }
        throw JsBaoError(
            code: .unavailable,
            message: "waitFor* timeout after \(timeoutMs)ms"
        )
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

    /// Set network mode. The optional `reason` is included in the
    /// emitted `networkMode` event so subscribers can distinguish
    /// user-initiated from system-initiated mode changes. Matches
    /// js-bao's `setNetworkMode(mode, opts)` shape.
    public func setNetworkMode(
        _ mode: NetworkMode,
        options: SetNetworkModeOptions = SetNetworkModeOptions()
    ) {
        lock.lock()
        networkMode = mode
        lock.unlock()
        authController.setNetworkMode(mode)
        events.emit(.networkMode, NetworkModeEvent(
            mode: mode,
            isOnline: mode != .offline,
            reason: options.reason ?? "user_set"
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

        // Mirror the doc into every registered cross-document store so
        // `Model.query()` sees it. Covers `openDocumentByAlias` too (it
        // funnels through here).
        connectToSharedModels(documentId: documentId, doc: doc)

        // Start network sync if requested. `deferNetworkSync` opens the
        // document locally without kicking off sync — the caller drives it
        // later via `startNetworkSync(documentId:)`. Mirrors JS `open`'s
        // `deferNetworkSync` short-circuit.
        if options.enableNetworkSync && !options.deferNetworkSync && isOnline() {
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
                    // Bound the wait by `availabilityWaitMs` (JS parity):
                    // resolve with whatever local state exists once the
                    // network-availability budget is exhausted. A value of
                    // 0 means "don't wait for the network" — resolve at once.
                    let waitMs = options.availabilityWaitMs
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
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

        // Drop this doc's rows from every cross-document store before the
        // YDocument is torn down, so later `Model.query()` reads don't
        // surface stale state.
        disconnectFromSharedModels(documentId: documentId)

        await documentManager.closeDocument(documentId: documentId, options: options)
    }

    /// Create a new document
    /// Create a document. Local-first by default — mirrors js-bao's
    /// `DocumentManager.createDocument` flow (#852). The returned
    /// `YDocument` is immediately writable; when `options.localOnly`
    /// is false (the default), a server commit is scheduled in the
    /// background and the `pendingCreate` metadata flag is cleared on
    /// success. On failure the `pendingCreateFailed` event fires and
    /// the metadata's `commitError` carries the reason.
    ///
    /// Before #852, this method blocked on `POST /documents` when
    /// online and returned `(id, nil)` — apps had to pass
    /// `localOnly: true` and call `commitOfflineCreate` manually to
    /// get a usable doc.
    public func createDocument(options: CreateDocumentOptions = CreateDocumentOptions()) async throws -> (documentId: String, doc: YDocument?) {
        // The server's `POST /documents` route validates documentId
        // against `^[0-9A-HJKMNP-TV-Z]{26}$` (Crockford ULID). Pre-#852
        // this method generated a UUID, which the server quietly
        // rejected on the legacy blocking path — switch to the
        // existing in-tree `ULID` helper so the background commit
        // succeeds.
        let documentId = ULID.generate()

        let doc = try await documentManager.createLocalDocument(
            documentId: documentId,
            title: options.title,
            localOnly: options.localOnly,
            tags: options.tags,
            docMetadata: options.metadata
        )

        // A freshly-created doc is immediately writable; connect it to the
        // cross-document stores so writes are visible to `Model.query()`
        // without waiting for an explicit `openDocument`.
        connectToSharedModels(documentId: documentId, doc: doc)

        // Schedule the server commit in the background. `localOnly`
        // docs stay local forever; everything else races up to the
        // server while the caller is already writing into `doc`.
        // `scheduleCommitRetry` mirrors js-bao: it retries with
        // exponential backoff on a transient failure (persisting
        // `commitError` / `commitRetryCount` / `nextCommitAttemptAt`
        // and emitting `documentCreateCommitFailed` each round) rather
        // than stranding the doc in `pendingCreate` after a single blip.
        if !options.localOnly && isOnline() {
            documentManager.scheduleCommitRetry(documentId: documentId)
        }

        return (documentId, doc)
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

    /// Get root document ID from the parsed JWT payload. Matches
    /// js-bao's `authController.getRootDocId()` (reads
    /// `payload.user.rootDocId || payload.rootDocId`), with the offline
    /// identity as a final fallback. No HTTP call — the value is
    /// available immediately after sign-in in any auth flow
    /// (OTP / OAuth / magic link / offline grant). `refresh` is kept
    /// for source compatibility and is a no-op now that there's
    /// nothing to refetch.
    public func getRootDocId(refresh: Bool = false) async throws -> String? {
        if let root = rootDocIdFromJwt() { return root }
        return authController.getOfflineIdentity()?.rootDocId
    }

    /// Open a document by URL alias. Resolves the alias to a
    /// documentId via the server, then opens it via the standard
    /// `openDocument` path. Mirrors js-bao's
    /// `client.openDocumentByAlias(alias)`.
    public func openDocumentByAlias(
        _ alias: String,
        options: OpenDocumentOptions = OpenDocumentOptions()
    ) async throws -> YDocument {
        let escaped = alias.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? alias
        let result = try await makeRequest(
            "GET", "/document-aliases/\(escaped)/resolve", nil
        )
        guard let dict = result as? [String: Any],
              let documentId = dict["documentId"] as? String else {
            throw JsBaoError(
                code: .aliasNotFound,
                message: "Alias `\(alias)` did not resolve to a document"
            )
        }
        return try await openDocument(documentId, options: options)
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

    /// Sync metadata. With no options, refreshes the full doc list.
    /// `options.documentId` restricts to one doc;
    /// `options.payloadType` (`"ids"` | `"full"`) controls the wire
    /// shape; `options.background` runs without blocking. Matches
    /// js-bao's `syncMetadata(opts)` shape.
    public func syncMetadata(
        options: SyncMetadataOptions = SyncMetadataOptions()
    ) async throws {
        var path = "/documents"
        var qs: [String] = []
        if let docId = options.documentId,
           let escaped = docId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            qs.append("documentId=\(escaped)")
        }
        if let payloadType = options.payloadType {
            qs.append("payloadType=\(payloadType)")
        }
        if !qs.isEmpty {
            path += "?\(qs.joined(separator: "&"))"
        }

        if options.background == true {
            // Fire-and-forget; caller wants the sync to run but doesn't
            // want to await its completion.
            Task { [weak self] in
                guard let self = self else { return }
                if let result = try? await self.makeRequest("GET", path, nil),
                   let docs = result as? [[String: Any]] {
                    await self.documentManager.handleServerDocuments(docs)
                }
            }
            return
        }
        let result = try await makeRequest("GET", path, nil)
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

    // MARK: - Analytics session lifecycle (#963)

    /// Log a `session_end` event carrying the session duration. Idempotent
    /// via `sessionEndLogged` so overlapping triggers (background
    /// notification + `destroy()`) only emit once. Mirrors js-bao's
    /// `logSessionEndEvent`.
    private func logSessionEndEvent(reason: String) {
        guard options.analyticsAutoEvents.sessionEnd else { return }
        lock.lock()
        if sessionEndLogged {
            lock.unlock()
            return
        }
        sessionEndLogged = true
        let start = sessionStartAt
        lock.unlock()

        let durationMs = max(0, Int(Date().timeIntervalSince(start) * 1000))
        analyticsQueue.logEvent(
            AnalyticsEventInput(
                action: "session_end",
                feature: "_session",
                context_json: .object([
                    "reason": .string(reason),
                    "duration_ms": .number(Double(durationMs)),
                ])
            )
        )
    }

    /// Register app-lifecycle observers so analytics flush + `session_end`
    /// fire when iOS backgrounds or terminates the app. UIKit-only; a
    /// no-op on Linux / macOS-CLI builds where the import is unavailable.
    private func registerLifecycleObservers() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        let background = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.logSessionEndEvent(reason: "background")
            self.analyticsQueue.flush()
        }
        let terminate = center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.logSessionEndEvent(reason: "destroy")
            self.analyticsQueue.flush()
        }
        // returnActive (#963): app foregrounded after inactivity. Mirrors
        // js-bao's `triggerReturnActiveEvent("visibility")` on the page
        // becoming `visible` — `didBecomeActive` is the UIKit analog.
        let foreground = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.triggerReturnActiveEvent(trigger: "didBecomeActive")
        }
        lock.lock()
        lifecycleObservers = [background, terminate, foreground]
        lock.unlock()
        #endif
    }

    /// Remove any registered lifecycle observers. Safe to call multiple
    /// times; clears the stored tokens.
    private func removeLifecycleObservers() {
        lock.lock()
        let observers = lifecycleObservers
        lifecycleObservers = []
        lock.unlock()
        #if canImport(UIKit)
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        #else
        _ = observers
        #endif
    }

    // MARK: - Per-feature analytics auto-events (#963)

    /// Subscribe to the emitter events that drive the per-feature auto-events:
    /// auth success → `dailyAuth`, blob lifecycle → `blobUploads`, and
    /// commit-failure → `syncErrors`. Mirrors how js-bao hooks
    /// `triggerDailyAuthAutoEvent` from `emitAuthSuccess` and the blob/sync
    /// emitters. `returnActive` is wired separately via the UIKit
    /// `didBecomeActive` notification in `registerLifecycleObservers`.
    private func registerAnalyticsAutoEventObservers() {
        let auto = options.analyticsAutoEvents
        var subs: [EventSubscription] = []

        // dailyAuth — first successful auth of the calendar day. js-bao fires
        // `triggerDailyAuthAutoEvent()` from `emitAuthSuccess`; the Swift
        // analog is the `authSuccess` emitter event from AuthController.
        if auto.dailyAuth {
            subs.append(events.on(.authSuccess) { [weak self] (_: AuthSuccessEvent) in
                self?.triggerDailyAuthAutoEvent()
            })
        }

        // syncErrors — a pending-create commit failed. js-bao calls
        // `maybeLogSyncErrorEvent(documentId, reason)` from its outbound-sync
        // failure paths; the Swift analog with a stable surface is the
        // `documentCreateCommitFailed` emitter event.
        if auto.syncErrorsEnabled {
            subs.append(events.on(.documentCreateCommitFailed) { [weak self] (event: DocumentCreateCommitFailedEvent) in
                self?.maybeLogSyncErrorEvent(documentId: event.documentId, reason: event.reason ?? "commit_failed")
            })
        }

        // blobUploads — start/success/failure, each one-shot per upload.
        // js-bao gates on `blobUploads.{start,success,failure}` and dedupes
        // by queueId/blobId; Swift mirrors that via the blob emitter events.
        if auto.blobUploadsSuccess {
            subs.append(events.on(.blobsUploadCompleted) { [weak self] (event: BlobUploadCompletedEvent) in
                self?.handleBlobUploadComplete(event)
            })
        }
        if auto.blobUploadsFailure {
            subs.append(events.on(.blobsUploadFailed) { [weak self] (event: BlobUploadFailedEvent) in
                self?.handleBlobUploadFailed(event)
            })
        }
        // NOTE: blobUploads.start has no faithful Swift surface yet — the
        // Swift BlobManager does not emit a "started/uploading" progress
        // event the way js-bao's queue does (`blobs:upload-progress` carries
        // download-only `bytesTransferred/totalBytes`, not an upload-start
        // signal). Left unwired; flagged in the report.

        lock.lock()
        analyticsEventSubscriptions = subs
        lock.unlock()
    }

    private func removeAnalyticsAutoEventObservers() {
        lock.lock()
        let subs = analyticsEventSubscriptions
        analyticsEventSubscriptions = []
        lock.unlock()
        for sub in subs { sub.cancel() }
    }

    /// Resolve the current user's ULID for analytics, or `nil` when
    /// unauthenticated. Mirrors js-bao's `resolveAnalyticsUserUlid`.
    private func resolveAnalyticsUserUlid() -> String? {
        authController.getUserId()
    }

    /// Hydrate the in-memory analytics-metadata mirror from the offline store
    /// for the current user, if not already hydrated. Mirrors js-bao's
    /// `ensureAnalyticsMetadataHydrated`. Resets the mirror when the user
    /// changes.
    private func ensureAnalyticsMetadataHydrated(userId: String) async {
        lock.lock()
        if analyticsMetadataHydrated && analyticsMetadataUserId == userId {
            lock.unlock()
            return
        }
        // User changed (or first hydrate) — clear and reload.
        if analyticsMetadataUserId != userId {
            lastDailyAuthDate = nil
            lastReturnActiveAt = nil
        }
        lock.unlock()

        let record = try? await offlineStore.loadAnalyticsMetadata(appId: options.appId, userId: userId)
        lock.lock()
        lastDailyAuthDate = record?.lastDailyAuthDate
        if let raw = record?.lastReturnActiveAt, let ms = Double(raw) {
            lastReturnActiveAt = Date(timeIntervalSince1970: ms / 1000.0)
        } else {
            lastReturnActiveAt = nil
        }
        analyticsMetadataHydrated = true
        analyticsMetadataUserId = userId
        lock.unlock()
    }

    /// Persist the in-memory analytics-metadata mirror. Mirrors js-bao's
    /// `persistAnalyticsMetadata` — writes `nil` (delete) when empty.
    private func persistAnalyticsMetadata(userId: String) async {
        lock.lock()
        let date = lastDailyAuthDate
        let returnAt = lastReturnActiveAt
        lock.unlock()

        var record = AnalyticsMetadataRecord()
        if let date { record.lastDailyAuthDate = date }
        if let returnAt {
            record.lastReturnActiveAt = String(Int(returnAt.timeIntervalSince1970 * 1000))
        }
        let hasValues = record.lastDailyAuthDate != nil || record.lastReturnActiveAt != nil
        do {
            try await offlineStore.persistAnalyticsMetadata(
                appId: options.appId,
                userId: userId,
                metadata: hasValues ? record : nil
            )
        } catch {
            logger.warn("[analytics] failed to persist auto-events metadata", error.localizedDescription)
        }
    }

    /// dailyAuth: emit `user_active_daily` (feature `session`) once per
    /// calendar day per user. Mirrors js-bao's `triggerDailyAuthAutoEvent`.
    private func triggerDailyAuthAutoEvent() {
        guard options.analyticsAutoEvents.dailyAuth else { return }
        guard let userId = resolveAnalyticsUserUlid() else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.ensureAnalyticsMetadataHydrated(userId: userId)
            let today = Self.analyticsDayString(Date())
            self.lock.lock()
            if self.lastDailyAuthDate == today {
                self.lock.unlock()
                return
            }
            self.lastDailyAuthDate = today
            self.analyticsMetadataHydrated = true
            self.analyticsMetadataUserId = userId
            self.lock.unlock()

            self.analyticsQueue.logEvent(
                AnalyticsEventInput(action: "user_active_daily", feature: "session")
            )
            await self.persistAnalyticsMetadata(userId: userId)
        }
    }

    /// returnActive: emit `user_returned` (feature `session`) when the app
    /// foregrounds after at least `minResumeMs` of inactivity. Mirrors
    /// js-bao's `triggerReturnActiveEvent`.
    private func triggerReturnActiveEvent(trigger: String) {
        guard options.analyticsAutoEvents.returnActive else { return }
        guard let userId = resolveAnalyticsUserUlid() else { return }
        let minResumeMs = options.analyticsAutoEvents.minResumeMs
        Task { [weak self] in
            guard let self else { return }
            await self.ensureAnalyticsMetadataHydrated(userId: userId)
            let now = Date()
            self.lock.lock()
            if let last = self.lastReturnActiveAt {
                let elapsedMs = now.timeIntervalSince(last) * 1000
                if elapsedMs < Double(minResumeMs) {
                    self.lock.unlock()
                    return
                }
            }
            self.lastReturnActiveAt = now
            self.analyticsMetadataHydrated = true
            self.analyticsMetadataUserId = userId
            self.lock.unlock()

            self.analyticsQueue.logEvent(
                AnalyticsEventInput(
                    action: "user_returned",
                    feature: "session",
                    context_json: .object(["trigger": .string(trigger)])
                )
            )
            await self.persistAnalyticsMetadata(userId: userId)
        }
    }

    /// syncErrors: emit `sync_error` (feature `sync`), rate-limited to one
    /// event per `syncErrorsMinIntervalMs`. Mirrors js-bao's
    /// `maybeLogSyncErrorEvent`.
    private func maybeLogSyncErrorEvent(documentId: String, reason: String) {
        guard options.analyticsAutoEvents.syncErrorsEnabled else { return }
        let minIntervalMs = options.analyticsAutoEvents.syncErrorsMinIntervalMs
        let now = Date()
        lock.lock()
        if let last = lastSyncErrorEventAt {
            let elapsedMs = now.timeIntervalSince(last) * 1000
            if elapsedMs < Double(minIntervalMs) {
                lock.unlock()
                return
            }
        }
        lastSyncErrorEventAt = now
        lock.unlock()

        analyticsQueue.logEvent(
            AnalyticsEventInput(
                action: "sync_error",
                feature: "sync",
                context_json: .object([
                    "documentId": .string(documentId),
                    "reason": .string(reason),
                ])
            )
        )
    }

    /// blobUploads.success: emit `blob_upload_succeeded` (feature `blobs`)
    /// once per upload. Mirrors js-bao's `handleBlobUploadComplete`.
    private func handleBlobUploadComplete(_ event: BlobUploadCompletedEvent) {
        guard options.analyticsAutoEvents.blobUploadsSuccess else { return }
        let key = event.blobId
        lock.lock()
        if key.isEmpty || blobUploadSuccessLogged.contains(key) {
            lock.unlock()
            return
        }
        blobUploadSuccessLogged.insert(key)
        lock.unlock()

        analyticsQueue.logEvent(
            AnalyticsEventInput(
                action: "blob_upload_succeeded",
                feature: "blobs",
                context_json: .object([
                    "documentId": .string(event.documentId),
                    "blobId": .string(event.blobId),
                    "numBytes": .number(Double(event.numBytes)),
                ])
            )
        )
    }

    /// blobUploads.failure: emit `blob_upload_failed` (feature `blobs`) once
    /// per upload. Mirrors js-bao's `handleBlobUploadFailed`.
    private func handleBlobUploadFailed(_ event: BlobUploadFailedEvent) {
        guard options.analyticsAutoEvents.blobUploadsFailure else { return }
        let key = event.blobId
        lock.lock()
        if key.isEmpty || blobUploadFailureLogged.contains(key) {
            lock.unlock()
            return
        }
        blobUploadFailureLogged.insert(key)
        lock.unlock()

        analyticsQueue.logEvent(
            AnalyticsEventInput(
                action: "blob_upload_failed",
                feature: "blobs",
                context_json: .object([
                    "documentId": .string(event.documentId),
                    "blobId": .string(event.blobId),
                    "willRetry": .bool(event.willRetry),
                    "lastError": .string(String((event.lastError ?? "").prefix(256))),
                ])
            )
        )
    }

    /// UTC `YYYY-MM-DD` day key, matching js-bao's
    /// `new Date().toISOString().slice(0, 10)`.
    private static func analyticsDayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
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
        // Stop listening for app-lifecycle notifications and emit a final
        // `session_end` before the queue drains (#963). The event lands in
        // the buffer that `analyticsQueue.destroy()` flushes below.
        removeLifecycleObservers()
        removeAnalyticsAutoEventObservers()
        logSessionEndEvent(reason: "destroy")
        // Cancel the periodic flush timer and trigger a final flush
        // before closing storage. The flush is async (fires a Task),
        // so we then await any pending persistence to drain — without
        // this, the SQLite close races the in-flight write and a
        // subsequent client opening the same DB hits SQLITE_BUSY.
        analyticsQueue.destroy()
        await analyticsQueue.awaitPendingPersistence()
        // JWT persistence (AuthController.applyToken) also runs in a
        // detached Task — wait for any outstanding write before the
        // storage layer pulls the connection out from under it.
        await authController.awaitPendingPersistence()
        await offlineStore.closeStorage()
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
        documentManager.isOnlineProvider = { [weak self] in self?.isOnline() ?? false }

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
            makeRequest: request,
            emit: { [weak self] event, payload in
                // Forward KvCache refresh events to subscribers (#1042),
                // matching the JS client's `cacheUpdated`/`cacheUpdateFailed`.
                // (The JS me-record re-emit is intentionally not wired here:
                // `.meUpdated` is already emitted from the WS path with a raw
                // json payload — a second emit with the cache value would be a
                // shape mismatch. Tracked as a follow-up.)
                self?.events.emit(event, payload)
            }
        )
        self.cache = cacheFacade

        documents = DocumentsAPI(
            makeRequest: request,
            blobManager: blobManager,
            documentManager: documentManager,
            client: self
        )
        collections = CollectionsAPI(makeRequest: request)
        // Realtime DB subscriptions (`databases.subscribe`). The registry
        // routes inbound `db.change` frames and is re-subscribed on reconnect.
        let dbSubscriptionRegistry = DatabaseSubscriptionRegistry(logger: logger)
        dbSubscriptionRegistry.setOriginContext(
            DatabaseSubscriptionRegistry.OriginContext(
                getConnectionId: { [weak self] in self?.wsManager.connectionId },
                getCurrentUserId: { [weak self] in self?.authController.getUserId() }
            )
        )
        databases = DatabasesAPI(
            makeRequest: request,
            subscriptionRegistry: dbSubscriptionRegistry,
            sendWSMessage: { [weak self] message in
                Task { try? await self?.wsManager.send(message) }
            },
            isWebSocketOpen: { [weak self] in self?.wsManager.isSocketOpen ?? false },
            connectWebSocket: { [weak self] in
                Task { try? await self?.wsManager.connect() }
            },
            logger: logger
        )
        // Raw HTTP closure for endpoints that need to send raw bytes
        // with custom Content-Type (e.g. avatar upload). Defined here
        // so MeAPI and BlobBucketsAPI both reuse the same plumbing.
        let rawRequestForRaw: (String, String, Data?, [String: String]) async throws -> (Data, Int) = {
            [weak self] method, path, data, headers in
            guard let self = self else { throw JsBaoError(code: .unavailable) }
            let options = RequestOptions(rawBody: true, customHeaders: headers)
            let response = try await self.httpClient.requestRaw(
                method: method, path: path, data: data, options: options
            )
            let bodyData: Data
            if let raw = response.data as? Data {
                bodyData = raw
            } else if let text = response.text {
                bodyData = Data(text.utf8)
            } else {
                bodyData = Data()
            }
            return (bodyData, response.status)
        }
        me = MeAPI(
            makeRequest: request,
            cache: cacheFacade,
            makeRawRequest: rawRequestForRaw,
            localMetadata: { [weak self] in self?.documentManager.getMetadataIndex() ?? [:] },
            isOnline: { [weak self] in self?.isOnline() ?? false }
        )
        session = SessionAPI(makeRequest: request)
        auth = AuthAPI(
            getUserId: { [weak self] in self?.authController.getUserId() },
            getToken: { [weak self] in self?.authController.getToken() },
            isAuthenticated: { [weak self] in self?.authController.isAuthenticated() ?? false },
            magicLinkRequest: { [weak self] email, redirectUri in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.authController.magicLinkRequest(email: email, redirectUri: redirectUri)
            },
            magicLinkVerify: { [weak self] token in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.authController.magicLinkVerify(token: token)
            },
            magicLinkVerifyWithInvite: { [weak self] token, inviteToken in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.authController.magicLinkVerify(token: token, inviteToken: inviteToken)
            },
            otpRequest: { [weak self] email in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.authController.otpRequest(email: email)
            },
            otpVerify: { [weak self] email, code in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.authController.otpVerify(email: email, code: code)
            },
            getAuthConfig: { try await request("GET", "/oauth-config", nil) },
            getAppConfig: { try await request("GET", "/oauth-config", nil) },
            logout: { [weak self] wipeLocal in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                try await self.authController.logout(wipeLocal: wipeLocal)
            },
            logoutWithOptions: { [weak self] options in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                try await self.authController.logout(options: options)
            },
            enableOfflineAccess: { [weak self] options in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.authController.enableOfflineAccess(options: options)
            },
            unlockOffline: { [weak self] in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.authController.unlockOffline()
            },
            getOfflineGrantStatus: { [weak self] in
                self?.authController.getOfflineGrantStatus()
                    ?? OfflineGrantStatus(available: false, expiresAt: nil, daysLeft: nil, method: nil)
            },
            renewOfflineGrant: { [weak self] options in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.authController.renewOfflineGrantOnline(options: options)
            },
            revokeOfflineGrant: { [weak self] options in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                try await self.authController.revokeOfflineGrant(options: options)
            },
            hasOfflineGrantStored: { [weak self] in
                self?.authController.isOfflineGrantAvailable() ?? false
            }
        )
        // logout(waitForDisconnect:) tears down networking via this hook.
        authController.onLogoutDisconnect = { [weak self] in await self?.disconnect() }
        llm = LlmAPI(
            makeRequest: request,
            logAnalytics: { [weak self] event in self?.analyticsQueue.logEvent(event) }
        )
        gemini = GeminiAPI(
            makeRequest: request,
            logAnalytics: { [weak self] event in self?.analyticsQueue.logEvent(event) }
        )
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
            logger: logger,
            events: events
        )
        invitations = InvitationsAPI(makeRequest: request)
        // BlobBuckets reuses the same raw HTTP closure defined above
        // for MeAPI — both need raw bodies with custom Content-Type.
        blobBuckets = BlobBucketsAPI(makeRequest: request, makeRawRequest: rawRequestForRaw)
        cronTriggers = CronTriggersAPI(makeRequest: request)
        collectionTypeConfigs = CollectionTypeConfigsAPI(makeRequest: request)
        databaseTypeConfigs = DatabaseTypeConfigsAPI(makeRequest: request)
        // Analytics namespace — a thin facade over the shared
        // `analyticsQueue` (wired in setupDependencies). All five methods
        // fan out to the same queue the top-level `logAnalyticsEvent` /
        // `flushAnalytics` / `setAnalytics*Override` back-compat methods use.
        analytics = AnalyticsAPI(
            logEvent: { [weak self] event in self?.analyticsQueue.logEvent(event) },
            flush: { [weak self] in self?.analyticsQueue.flush() },
            setPlanOverride: { [weak self] plan in self?.analyticsQueue.setPlanOverride(plan) },
            setAppVersionOverride: { [weak self] version in self?.analyticsQueue.setAppVersionOverride(version) },
            resolveUserUlid: { [weak self] in self?.authController.getUserId() }
        )
    }

    private func setupStorage() {
        Task {
            do {
                let provider: StorageProvider
                let authProvider: StorageProvider
                switch options.storageConfig {
                case .sqlite(let directory):
                    // One provider, shared across general + auth namespaces.
                    //
                    // Two providers pointing at the same file would each open
                    // their own SQLite handle. WAL mode allows concurrent
                    // reads, but a JWT write running on the auth provider
                    // while the general provider writes (analytics queue
                    // restore, doc metadata, etc.) hits the file lock and
                    // returns SQLITE_BUSY ("database is locked"). The
                    // historical motivation for two providers was that
                    // `initialize(namespace:)` used to silently re-bind the
                    // open DB when namespaces differed — that was fixed in
                    // the same commit (initialize is now idempotent for the
                    // same path, throws on re-bind), and with `databasePath`
                    // explicitly set, every initialize call resolves to the
                    // same file and the second is a no-op. The kv_store
                    // `store` column already namespaces auth records vs
                    // everything else, so they don't collide on rows either.
                    //
                    // #853: when the app passes `.sqlite()` (no
                    // directory), resolve a stable per-appId path here
                    // rather than letting `SQLiteStorageProvider` fall
                    // back to namespace-derived directories. Without
                    // this, the auth namespace (`auth:<appId>:…`) and
                    // the user namespace (`<appId>:<userId>`) resolved
                    // to different files and the second `initialize`
                    // tripped the re-bind guard mid-`createDocument`.
                    let resolvedPath = directory
                        ?? SQLiteStorageProvider.defaultDatabasePath(appId: options.appId)
                    let sqlite = try SQLiteStorageProvider(path: resolvedPath)
                    provider = sqlite
                    authProvider = sqlite
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

        case "stateVectorCheckResponse":
            // Server's verdict for a `checkStateVector` round-trip. The
            // response is stamped with the originating documentId/roomId
            // by the relay (same as syncComplete), so route it back to the
            // waiter parked on that doc.
            guard let roomId = roomId else { return }
            handleStateVectorCheckResponse(
                documentId: roomId,
                includesWrites: json["includesWrites"] as? Bool ?? false,
                inSync: json["inSync"] as? Bool ?? false
            )

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

        case "workflowStarted":
            // Server-pushed start notification. This is the JS source of
            // truth for `workflowStarted` (see `handleWorkflowStartedMessage`
            // in `src/client/JsBaoClient.ts`, which emits the full frame).
            // Read every field JS carries directly off the inbound frame;
            // optional fields stay nil when the frame omits them.
            let startedEvent = WorkflowStartedEvent(
                workflowKey: json["workflowKey"] as? String ?? "",
                runId: json["runId"] as? String ?? "",
                workflowId: json["workflowId"] as? String,
                runKey: json["runKey"] as? String,
                instanceId: json["instanceId"] as? String,
                contextDocId: json["contextDocId"] as? String,
                meta: json["meta"] as? [String: Any]
            )
            events.emit(.workflowStarted, startedEvent)

        case "invitation":
            events.emit(.invitation, json)

        case "meUpdated":
            events.emit(.meUpdated, json)

        case "docMetadata":
            // Server-pushed metadata change. Carries `action` ∈ {created,
            // updated, deleted, evicted}, plus the new metadata blob (nil
            // on delete/revoke). Emit the typed event for general
            // subscribers; derive `documentDeleted` for the common
            // "detail view needs to pop" case so subscribers don't have
            // to filter the action string themselves.
            guard let docId = roomId else { return }
            let actionStr = json["action"] as? String ?? "updated"
            let metadata = json["metadata"] as? [String: Any]
            let changedFields = json["changedFields"] as? [String]
            let event = DocumentMetadataChangedEvent(
                documentId: docId,
                action: actionStr,
                metadata: metadata,
                changedFields: changedFields,
                source: "server"
            )
            events.emit(.documentMetadataChanged, event)
            if actionStr == "deleted" {
                events.emit(
                    .documentDeleted,
                    DocumentDeletedEvent(documentId: docId, source: "server-push")
                )
            }

        case "db.change":
            // Route to the matching databases.subscribe callback. Frames with
            // no matching registration (arrived before register / after unsub)
            // are debug-logged and dropped inside dispatch.
            databases.subscriptionRegistry?.dispatch(json)

        case "db.subscribed", "db.unsubscribed":
            // Server-side ack. No client action — subscribe() returns a
            // synchronous unsubscribe handle.
            logger.debug("[db-sub] ack received", action,
                         json["databaseId"] as? String ?? "",
                         json["subscriptionKey"] as? String ?? "")

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
            // Re-issue db.subscribe for every live database subscription —
            // the server-side connection mapping is dropped on disconnect.
            databases.resubscribeAll()
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
        events.emit(.connectionClose, ConnectionCloseEvent(code: code, reason: reason))
    }

    public func webSocketManagerOnError(_ error: Error) {
        logger.warn("WebSocket error:", error.localizedDescription)
        events.emit(.connectionError, ConnectionErrorEvent(message: error.localizedDescription))
        events.emit(.error, GenericErrorEvent(
            scope: "websocket", message: error.localizedDescription
        ))
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
