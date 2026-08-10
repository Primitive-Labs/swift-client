import Foundation
// `@preconcurrency` downgrades Sendable-related diagnostics that originate
// from YSwift's own (non-Sendable) types — YSwift predates strict
// concurrency and isn't annotated. It only suppresses warnings sourced
// from that module; genuine Sendable issues in our own types still surface.
// The upstream YSwift fork (#1911) will annotate these properly.
@preconcurrency import YSwift
import Yniffi
#if canImport(UIKit)
import UIKit
#endif

/// Main client for the JsBao platform. Manages WebSocket connections,
/// document collaboration via y-crdt, authentication, offline storage, and REST APIs.
public final class JsBaoClient: @unchecked Sendable {

    // MARK: - Public Properties

    /// The client's event registry.
    ///
    /// Internal since #2367 removed the untyped public `events` surface.
    /// Subscribe through the typed client members instead:
    /// ``stream(for:buffering:replayingLatest:)``,
    /// ``observeOnMainActor(_:handler:)`` and ``nextEvent(_:timeout:where:)``.
    let eventEmitter: EventEmitter

    // MARK: - Sub-APIs
    //
    // None of these is an implicitly-unwrapped optional any more (#2367). A
    // `DocumentsAPI!` in the public surface was a crash-typed declaration
    // leaking a two-phase-init workaround: every one of them is assigned
    // during `init` and none is ever nil for a caller.
    //
    // The ones whose collaborators are all available as locals during phase 1
    // are plain `let`s, built in `init` before `setupDependencies()`. The
    // remaining six — `documents`, `me`, `auth`, `users`, `cache`, `codegen` —
    // reach client-level logic that has no collaborator behind it
    // (`networkingAllowed()`, `networkMode`, `rootDocId`, `logout(...)`, or
    // `self` itself), so Swift's two-phase rule makes a `let` impossible for
    // them. They keep private implicitly-unwrapped storage assigned in
    // `setupSubApis()`, behind a non-optional public computed property.

    public let collections: CollectionsAPI
    public let databases: DatabasesAPI
    public let session: SessionAPI
    public let llm: LlmAPI
    public let gemini: GeminiAPI
    public let groups: GroupsAPI
    public let ruleSets: RuleSetsAPI
    public let groupTypeConfigs: GroupTypeConfigsAPI
    public let integrations: IntegrationsAPI
    public let prompts: PromptsAPI
    public let workflows: WorkflowsAPI
    public let invitations: InvitationsAPI
    /// Sub-API for the notification inbox and push-device registration
    /// (list / unreadCount / markRead / markAllRead / send / registerDevice /
    /// listDevices / unregisterDevice). Live in-app notifications arrive as
    /// the `.notification` event. Mirrors JS `client.notifications.*`.
    public let notifications: NotificationsAPI
    /// Sub-API for the named lock service (tryAcquire / acquire / release /
    /// renew / status / list). Leases are mandatory-TTL and the opaque
    /// `handleId` proves holder identity. Mirrors JS `client.locks.*`.
    public let locks: LocksAPI
    /// Sub-API for typed resource metadata values (get / set / getBatch /
    /// list / delete). Category definitions are admin-scoped and are not
    /// exposed here. Mirrors JS `client.resourceMetadata.*`.
    public let resourceMetadata: ResourceMetadataAPI
    public let blobBuckets: BlobBucketsAPI
    public let cronTriggers: CronTriggersAPI
    public let collectionTypeConfigs: CollectionTypeConfigsAPI
    public let databaseTypeConfigs: DatabaseTypeConfigsAPI
    public let analytics: AnalyticsAPI
    /// Deep-link / universal-link routing (#931). Set
    /// `links.appBaseURL` to your app's public web base URL to enable
    /// the `shareURL(...)` builders.
    public let links: LinksAPI

    // The five that cannot be `let`: private storage, non-optional accessor.

    private var _documents: DocumentsAPI!
    private var _me: MeAPI!
    private var _auth: AuthAPI!
    private var _users: UsersAPI!
    private var _cache: CacheFacade!
    private var _codegen: CodegenAPI!

    /// Document sub-API. Wired during `init`; never nil for callers.
    public var documents: DocumentsAPI { _documents }
    /// Current-user sub-API. Wired during `init`; never nil for callers.
    public var me: MeAPI { _me }
    /// Authentication sub-API. Wired during `init`; never nil for callers.
    public var auth: AuthAPI { _auth }
    /// User-directory sub-API. Wired during `init`; never nil for callers.
    public var users: UsersAPI { _users }
    /// Cache facade for general-purpose caching. Wired during `init`; never
    /// nil for callers.
    public var cache: CacheFacade { _cache }
    /// The surface generated models call into. **App code should use the
    /// generated `Model.*` facade instead** — see ``CodegenAPI``. Wired during
    /// `init`; never nil for callers.
    public var codegen: CodegenAPI { _codegen }

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
    /// Internal (not `private`) so `@testable` integration tests can observe
    /// logged events via `AnalyticsQueue.onEventLogged` — the Swift analog of
    /// the JS tests poking `client.analyticsQueue` (#963 coverage).
    let analyticsQueue: AnalyticsQueue
    private let kvCache: KvCache

    private let lock = NSLock()
    private var networkModeStorage: NetworkMode = .auto
    /// System reachability, driven by the optional `ConnectivityMonitor`
    /// (Phase 2). Separate from `networkMode` (user intent): the monitor
    /// updates this bit and never mutates the mode. Defaults `true`, so with
    /// monitoring off `networkingAllowed()` equals the old `mode != .offline`
    /// and gating behavior is unchanged. Guarded by `lock`.
    private var reachable = true
    /// Latest network-transition reason, surfaced via
    /// `networkStatus.reason` (was always `nil`). Set by
    /// `applyNetworkMode` and `applyReachability`. Guarded by `lock`.
    private var lastReason: String?
    private var lastOnlineAt: Date?

    // MARK: Connectivity monitoring (#1987, Phase 2)

    /// Optional path monitor. Present (and started in `setupStorage`) only when
    /// `autoNetwork` is true. Injected for tests via the internal designated
    /// init; otherwise the real `NWPathConnectivityMonitor`. Never mutates
    /// `networkMode` — it drives the `reachable` bit only.
    private let connectivityMonitor: ConnectivityMonitor?
    /// Serial queue for the reachability debounce.
    private let reachabilityQueue = DispatchQueue(label: "jsbao.reachability")
    /// Pending debounced reachability apply; replaced (and the prior one
    /// cancelled) per transition, cancelled on `destroy()`. Guarded by `lock`.
    private var reachabilityDebounce: DispatchWorkItem?
    /// Latched once the monitor delivers (and applies) its first reachability
    /// snapshot, so the startup auto-connect gate can await it. Guarded by
    /// `lock`.
    private var initialReachabilityReceived = false
    /// Claimed by the first `handleReachabilityChange` callback, which takes
    /// the undebounced path. Separate from `initialReachabilityReceived`
    /// because the latch must be set only AFTER the snapshot is applied,
    /// while the claim has to happen before. Guarded by `lock`.
    private var initialReachabilityClaimed = false

    /// Reason strings for monitor-driven transitions. camelCase, matching the
    /// existing `onlineAuthRequired` vocabulary.
    private enum ConnectivityReason {
        static let lost = "connectivityLost"
        static let restored = "connectivityRestored"
    }
    private var subscribedDocuments: Set<String> = []
    private var outboundDebounceTimers: [String: Task<Void, Never>] = [:]
    private var pendingUpdates: [String: [[UInt8]]] = [:]
    private var isDestroyed = false

    // MARK: Outbound unsynced-flag ordering (#2004)

    /// Number of `queueOutboundUpdate` calls that have already marked the
    /// document unsynced but have not yet inserted their update into
    /// `pendingUpdates`. Guarded by `lock`.
    ///
    /// `flushOutboundUpdates` refuses to clear the flag while this is non-zero:
    /// during that window `pendingUpdates` looks empty even though a local edit
    /// is on its way in, so an "everything drained" clear would leave the flag
    /// false with an unsent edit behind it (the Codex finding on PR #2104).
    private var outboundEnqueuesInProgress: [String: Int] = [:]

    /// Ownership token of the flush currently draining each document's outbound
    /// queue. Guarded by `lock`. Absent means no flush owns the document.
    ///
    /// One flush owns a document's drain at a time: the first to claim the id
    /// owns it, a concurrent flush returns immediately, and the owner re-checks
    /// the queue before it releases ownership, so anything queued meanwhile is
    /// drained by that owner. Without this, two flushes could each hold an
    /// unconfirmed batch and neither could see the other's (#2105).
    ///
    /// The value is a token rather than a bare `Set` membership because
    /// ownership can be revoked underneath a running flush: `closeDocument` and
    /// `destroy` drop the entry while a flush may be awaiting `sendLocalUpdate`.
    /// If the document is then reopened and edited, a *new* flush legitimately
    /// takes ownership — and when the old send finally returns, the old flush
    /// must not touch the new owner's queue, remove its head, release its
    /// ownership, or decide the flag. Comparing the token it acquired against
    /// the current one tells it whether it is still the owner; if not, it exits
    /// without touching any shared state (the Codex finding on PR #2396).
    private var outboundFlushOwner: [String: UInt64] = [:]

    /// Monotonic source of `outboundFlushOwner` tokens. Guarded by `lock`.
    /// Never reused, so a revoked owner can never match a later one.
    private var outboundFlushTokenSeq: UInt64 = 0

    /// Documents whose drain was requested while another flush owned it.
    /// Guarded by `lock`.
    ///
    /// A flush that finds the document already owned returns immediately, which
    /// is only safe if the owner is guaranteed to carry the work the caller
    /// wanted done. It isn't: the owner may be parked in a send that is about to
    /// fail, and a failed send releases ownership without retrying. The request
    /// would then be lost with the batch still queued, no owner, no debounce
    /// timer armed — nothing left to flush it until the next local edit
    /// (PR #2396 review). So a flush that can't claim the document records the
    /// request here instead of dropping it, and the owner consumes the bit at
    /// both of its release points and loops rather than releasing. Membership,
    /// not a count: several requests collapse into one more drain pass, which is
    /// all any of them wanted.
    private var outboundReflushRequested: Set<String> = []

    /// Monotonic sequence handed out under `lock` to each unsynced-flag
    /// decision, so the decisions are *applied* in the order they were made.
    /// Guarded by `lock`.
    private var unsyncedFlagSeq: UInt64 = 0

    /// Serializes applying an unsynced-flag decision to `DocumentManager` and
    /// guards `unsyncedFlagAppliedSeq`. Never taken while `lock` is held (and
    /// `lock` is never taken while this is held), so it adds no cycle: the only
    /// edge is `unsyncedFlagApplyLock` → `DocumentManager.lock`. That edge is
    /// real — this lock is held *across* the `markUnsyncedLocalChanges` call —
    /// so the client does hold a lock when calling into `DocumentManager`, just
    /// a much narrower one than `lock`.
    private let unsyncedFlagApplyLock = NSLock()
    /// Highest decision sequence already applied, per document. Guarded by
    /// `unsyncedFlagApplyLock`. Pruned in `closeDocument`; a stale entry would
    /// be harmless anyway (the sequence is global and monotonic, so a re-opened
    /// document's decisions always outrank it).
    private var unsyncedFlagAppliedSeq: [String: UInt64] = [:]

    /// Test-observability hook: invoked at the end of `queueOutboundUpdate`,
    /// right after the debounce task has been scheduled and the lock released.
    /// Internal (visible only via `@testable import`) — the #2004 ordering test
    /// uses it to hold the tail of the call while a zero-debounce flush runs to
    /// completion. Never set in production code.
    var onOutboundQueuedForTest: ((String) -> Void)?

    /// Test-observability hook: invoked at the very end of
    /// `flushOutboundUpdates`, after the flag decision has been applied.
    /// Internal — the PR #2104 race test uses it to know the flush's clear
    /// check has run. Fires only for the flush that *owns* the drain — on
    /// every one of its exits: queue drained, send failed, or its ownership
    /// revoked mid-send by `closeDocument`/`destroy`. It never fires for a
    /// concurrent flush that returned without draining (#2105). Never set in
    /// production code.
    var onOutboundFlushedForTest: ((String) -> Void)?

    // MARK: Storage-init completion signal (#1780)

    /// Guards `storageReady` + `storageReadyWaiters`.
    private let storageReadyLock = NSLock()
    /// Latched `true` once `setupStorage()`'s init task has run to completion —
    /// token restored (or none), the user-scoped managers bound, and local
    /// metadata loaded — whether it succeeded or failed. Never resets.
    private var storageReady = false
    /// Continuations parked in `awaitStorageReady()` before the signal fired,
    /// keyed so a cancelled waiter can remove only its own.
    private var storageReadyWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

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

    /// Public entry point. Delegates to the internal designated init with no
    /// injected monitor (the real `NWPathConnectivityMonitor` is used when
    /// `autoNetwork` is true).
    public convenience init(options: JsBaoClientOptions) {
        self.init(options: options, connectivityMonitor: nil)
    }

    /// Internal designated init. `connectivityMonitor` injects a fake
    /// `ConnectivityMonitor` for tests; when `nil` and `autoNetwork` is true,
    /// the real `NWPathConnectivityMonitor` is created. When `autoNetwork` is
    /// false no monitor is started (parity with the bundled consumer).
    internal init(
        options: JsBaoClientOptions,
        connectivityMonitor injectedMonitor: ConnectivityMonitor?
    ) {
        self.options = options
        // Wired with its own logger so a stalled `stream(for:)` consumer's
        // high-water warning reaches the app's log. Held in a local as well as
        // the stored property so `KvCache`'s emitter closure can capture it
        // below — an escaping closure cannot capture `self` from an initializer
        // before the instance is fully initialized.
        let eventEmitter = EventEmitter(
            logger: createLogger(level: options.logLevel, scope: "EventEmitter")
        )
        self.eventEmitter = eventEmitter

        // Resolve the monitor: an injected fake wins; otherwise the real
        // NWPathMonitor-backed monitor, but only when autoNetwork is on.
        if let injectedMonitor {
            self.connectivityMonitor = injectedMonitor
        } else if options.autoNetwork {
            self.connectivityMonitor = NWPathConnectivityMonitor()
        } else {
            self.connectivityMonitor = nil
        }

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
            emitter: eventEmitter,
            refreshProxy: options.auth.refreshProxy,
            persistConfig: options.auth
        )

        // WebSocket manager — created BEFORE the HTTP client so the HTTP
        // layer can forward the live connection id as `X-JB-Connection-Id`.
        // (`HttpClientConfig` is immutable; the previous `{ nil }` placeholder
        // could never be "set after wsManager init", so Swift HTTP writes were
        // silently unattributed — JS forwards the id on every request, which
        // is what makes `db.change` frames round-trip with `isOrigin: true`
        // for the writer's own connection, #737.)
        let wsManager = WebSocketManager(
            logger: logger,
            maxReconnectDelayMs: Int(options.maxReconnectDelay * 1000)
        )
        self.wsManager = wsManager

        // HTTP client. Held in a local as well as the stored property so the
        // blob manager below can be constructed with it — an actor has no
        // synchronous setter, so its transport has to arrive at construction.
        let httpClient = HttpClient(config: HttpClientConfig(
            apiUrl: options.apiUrl,
            appId: options.appId,
            getToken: { [weak authController] in authController?.getToken() },
            getConnectionId: { [weak wsManager] in wsManager?.connectionId },
            getGlobalAdminAppId: { options.globalAdminAppId },
            logger: logger,
            // Route the 401 (and pre-expiry) refresh through AuthController's
            // single-flight refresh so N concurrent 401s coalesce into one
            // POST /auth/refresh, and the logout race guard applies. The
            // refresh implementation, JWT parsing, and proxy handling all live
            // in AuthController now (which owns `options.auth.refreshProxy`).
            refreshAccessToken: { [weak authController] in
                await authController?.refreshAccessToken(cause: "http") ?? .network(nil)
            }
        ))
        self.httpClient = httpClient

        // Document manager
        self.documentManager = DocumentManager(logger: logger)

        // Blob manager. Its collaborators are supplied here rather than
        // assigned by `setupDependencies()` afterwards (#2172): the manager is
        // an actor, so there is no synchronous way to attach them later — the
        // same construction move D2 made for `KvCache` and D3 for
        // `AnalyticsQueue`. They capture the locals `weak` (or capture the
        // `Sendable` `options` value directly) because an escaping closure
        // cannot capture `self` from an initializer before the instance is
        // fully initialized. The seventh setter, `getCurrentUserId`, is gone —
        // it was assigned and never read.
        let authController = self.authController
        self.blobManager = BlobManager(
            logger: logger,
            uploadConcurrency: options.blobUploadConcurrency,
            transport: httpClient,
            getApiUrl: { options.apiUrl },
            getAppId: { options.appId },
            getToken: { [weak authController] in authController?.getToken() },
            getGlobalAdminAppId: { options.globalAdminAppId },
            emit: { [weak eventEmitter] payload in eventEmitter?.emitErased(payload) }
        )

        // Analytics queue. Its collaborators are supplied here rather than
        // assigned by `setupDependencies()` afterwards (#1993, Phase D3): the
        // queue is an actor, so there is no synchronous way to attach them
        // later. They are captured `weak` from the locals for the same reason
        // `KvCache`'s emitter is — an escaping closure cannot capture `self`
        // from an initializer before the instance is fully initialized.
        let analyticsQueue = AnalyticsQueue(
            logger: logger,
            appId: options.appId,
            offlineStore: offlineStore,
            sendMessage: { [weak wsManager] message in try await wsManager?.send(message) },
            getConnectionId: { [weak wsManager] in wsManager?.connectionId },
            getUserId: { [weak authController] in authController?.getUserId() }
        )
        self.analyticsQueue = analyticsQueue

        // KV cache. The emitter is supplied here rather than injected by
        // `CacheFacade` later (#1993, Phase D2): `KvCache` is an actor, so
        // there is no synchronous way to attach it after construction.
        // Forwards `cacheUpdated`/`cacheUpdateFailed` to subscribers (#1042),
        // matching the JS client. `weak` so the cache never keeps the emitter
        // (and through it the client's subscribers) alive, which is the
        // lifetime the previous `[weak self]` closure had.
        self.kvCache = KvCache(emit: { [weak eventEmitter] payload in
            // (The JS me-record re-emit is intentionally not wired here:
            // `.meUpdated` is already emitted from the WS path — a second
            // emit with the cache value would be a shape mismatch. Tracked
            // as a follow-up.)
            eventEmitter?.emitErased(payload)
        })

        // Sub-APIs whose collaborators are all available as locals here. Built
        // in phase 1 as `let`s (#2367) so the public surface carries no
        // implicitly-unwrapped optional. Every closure captures a local
        // weakly — never `self`, which is not usable yet.
        self.collections = CollectionsAPI(transport: httpClient)
        self.session = SessionAPI(transport: httpClient)
        self.links = LinksAPI()
        self.groups = GroupsAPI(transport: httpClient)
        self.ruleSets = RuleSetsAPI(transport: httpClient)
        self.groupTypeConfigs = GroupTypeConfigsAPI(transport: httpClient)
        // IntegrationsAPI needs the full HttpClientResponse to surface
        // upstream status / headers / typed error mapping (the proxy
        // envelope puts the upstream status in the body and the proxy's
        // OWN status in the response status), so it uses
        // `Transport.requestRaw`, which does not throw on a non-2xx status.
        self.integrations = IntegrationsAPI(transport: httpClient)
        self.prompts = PromptsAPI(transport: httpClient)
        self.invitations = InvitationsAPI(transport: httpClient)
        self.notifications = NotificationsAPI(transport: httpClient)
        self.locks = LocksAPI(transport: httpClient)
        self.resourceMetadata = ResourceMetadataAPI(transport: httpClient)
        // Blob upload/download go through `Transport.requestData`, which
        // returns the untouched response bytes.
        self.blobBuckets = BlobBucketsAPI(transport: httpClient)
        self.cronTriggers = CronTriggersAPI(transport: httpClient)
        self.collectionTypeConfigs = CollectionTypeConfigsAPI(transport: httpClient)
        self.databaseTypeConfigs = DatabaseTypeConfigsAPI(transport: httpClient)
        // `prepared(_:)` runs on the calling thread — the same lowering
        // `makeAnalyticsContext()` does — so the event's `timestamp` is the
        // instant the LLM/Gemini call site logged it. Handing the raw event to
        // the actor instead would have stamped it whenever the unstructured
        // task happened to run (#2244).
        self.llm = LlmAPI(
            transport: httpClient,
            logAnalytics: { [analyticsQueue] event in
                let prepared = analyticsQueue.prepared(event)
                Task { await analyticsQueue.logEvent(prepared) }
            }
        )
        self.gemini = GeminiAPI(
            transport: httpClient,
            logAnalytics: { [analyticsQueue] event in
                let prepared = analyticsQueue.prepared(event)
                Task { await analyticsQueue.logEvent(prepared) }
            }
        )
        self.workflows = WorkflowsAPI(
            transport: httpClient,
            getConnectionId: { [weak wsManager] in wsManager?.connectionId ?? "" },
            logger: logger,
            events: eventEmitter
        )
        // Analytics namespace — a thin facade over the shared
        // `analyticsQueue`. All five methods fan out to the same queue.
        self.analytics = AnalyticsAPI(
            queue: analyticsQueue,
            resolveUserUlid: { [weak authController] in authController?.getUserId() }
        )
        // Realtime DB subscriptions (`databases.subscribe`). The registry
        // routes inbound `db.change` frames and is re-subscribed on reconnect.
        let dbSubscriptionRegistry = DatabaseSubscriptionRegistry(logger: logger)
        dbSubscriptionRegistry.setOriginContext(
            DatabaseSubscriptionRegistry.OriginContext(
                getConnectionId: { [weak wsManager] in wsManager?.connectionId },
                getCurrentUserId: { [weak authController] in authController?.getUserId() }
            )
        )
        self.databases = DatabasesAPI(
            transport: httpClient,
            subscriptionRegistry: dbSubscriptionRegistry,
            sendWSMessage: { [weak wsManager] message in
                Task { try? await wsManager?.send(message) }
            },
            isWebSocketOpen: { [weak wsManager] in wsManager?.isSocketOpen ?? false },
            connectWebSocket: { [weak wsManager] in
                Task { try? await wsManager?.connect() }
            },
            logger: logger
        )

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
        let (data, response) = try await NetworkSession.data(from: url)
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

    // MARK: - Auth / OAuth config

    // The untyped `getAuthConfig()` / `getAppConfig()` readers were removed in
    // #2367: `client.auth.getAuthConfig()` and `client.auth.getAppConfig()`
    // return the typed `AuthConfigInfo` / `AppConfigInfo` for the same
    // endpoint.

    /// Boolean predicate: is OAuth set up + configured for this app?
    /// Mirrors js-bao's `client.checkOAuthAvailable()` — reads
    /// `client.auth.getAuthConfig()` and checks `hasOAuth && googleClientId`.
    public func checkOAuthAvailable() async -> Bool {
        guard let cfg = try? await auth.getAuthConfig() else { return false }
        return cfg.hasOAuth && cfg.googleClientId?.isEmpty == false
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

    /// Force reconnect the WebSocket, returning once the reconnect has been
    /// initiated.
    public func forceReconnectAsync() async {
        await wsManager.forceReconnect()
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
    /// helper used by `rootDocId` and `isRootDocument`.
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
    private var defaultDocumentIdStorage: String?

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
        lock.withLock {
            modelToDocumentId[modelName] = documentId
        }
    }

    /// Remove a `modelName → documentId` mapping. No-op if none exists.
    public func clearDocumentModelMapping(modelName: String) {
        lock.withLock {
            _ = modelToDocumentId.removeValue(forKey: modelName)
        }
    }

    /// Resolve a `modelName` to its registered doc, or the default
    /// doc if no per-model mapping exists. Returns `nil` if neither
    /// is set. Matches js-bao's `getDocumentIdForModel` /
    /// `getDocumentModelMapping`.
    public func getDocumentModelMapping(modelName: String) -> String? {
        return lock.withLock {
            modelToDocumentId[modelName] ?? defaultDocumentIdStorage
        }
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
        lock.withLock {
            defaultDocumentIdStorage = documentId
        }
    }

    public func clearDefaultDocumentId() {
        lock.withLock {
            defaultDocumentIdStorage = nil
        }
    }

    /// The fallback document id used when a model does not name one.
    public var defaultDocumentId: String? {
        lock.withLock { defaultDocumentIdStorage }
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
        // Fast path returns an already-registered store without the connect
        // sweep; only a freshly-created store connects the open documents.
        var newlyCreated = false
        let created: MultiDocModel = lock.withLock {
            if let existing = sharedModels[schema.name] {
                return existing
            }
            let model = MultiDocModel(schema: schema)
            sharedModels[schema.name] = model
            newlyCreated = true
            return model
        }
        guard newlyCreated else { return created }
        // Connect docs opened before this model was registered. Done
        // outside `lock` because `connect` takes the document manager's
        // lock; holding both risks a lock-ordering inversion.
        for entry in documentManager.openDocumentsSnapshot() {
            created.connect(docId: entry.documentId, doc: entry.doc)
        }
        return created
    }

    /// The shared store for an already-registered model, or `nil`. Internal.
    func sharedModel(_ modelName: String) -> MultiDocModel? {
        return lock.withLock { sharedModels[modelName] }
    }

    /// Every connected `(model, document)` member of the shared store, for
    /// the debug inspector. Each entry is the per-doc writer for one model in
    /// one open document — so the inspector can surface cross-document data
    /// without apps binding per-doc models by hand.
    public func inspectableSharedMembers() -> [(modelName: String, documentId: String, model: DynamicModel)] {
        let models = lock.withLock { sharedModels }
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
    func requireMember(_ schema: PrimitiveSchema, in docId: String) throws -> DynamicModel {
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
        let models = lock.withLock { Array(sharedModels.values) }
        for model in models { model.connect(docId: documentId, doc: doc) }
    }

    /// Drop a closing document's rows from every shared store so later
    /// cross-document reads don't return stale state.
    private func disconnectFromSharedModels(documentId: String) {
        let models = lock.withLock { Array(sharedModels.values) }
        for model in models { model.disconnect(docId: documentId) }
    }

    // MARK: - Default client (backs the codegen'd `Model.query()` facade)

    private static let defaultClientLock = NSLock()
    // Every access to `_defaultClient` goes through `defaultClientLock`
    // (see the accessors below), so the mutable static is safe despite not
    // being concurrency-checked — hence `nonisolated(unsafe)`.
    nonisolated(unsafe) private static var _defaultClient: JsBaoClient?

    /// Configure the process-wide default client that the codegen'd static
    /// query facade (`TodoRecord.query()`, `.count()`, `.findAll()`,
    /// `.subscribe(_:)`) reads. Call once after constructing your client —
    /// in a `PrimitiveApp` host this is wired for you. Replacing it (e.g.
    /// across a sign-out/sign-in) is allowed.
    public static func configureDefault(_ client: JsBaoClient) {
        defaultClientLock.withLock {
            _defaultClient = client
        }
    }

    /// The configured default client, or `nil` if `configureDefault` was
    /// never called.
    public static var `default`: JsBaoClient? {
        defaultClientLock.withLock { _defaultClient }
    }

    /// Clear the default client. Mainly for test teardown.
    public static func clearDefault() {
        defaultClientLock.withLock {
            _defaultClient = nil
        }
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
    // platform code can call `client.llmAnalyticsContext?.logEvent(...)`
    // identically.

    /// Returns a logger handle for LLM analytics, or `nil` when the
    /// auto-events config for `llm` is fully disabled. The handle has
    /// the same shape as js-bao's: `logEvent(event)` and
    /// `isEnabled(phase?)`.
    public var llmAnalyticsContext: AnalyticsContext? {
        // Auto-events config isn't a typed option on Swift yet; if it
        // lands, swap this for the real flag-walk. For now always
        // return a context so cross-platform callers don't no-op.
        makeAnalyticsContext()
    }

    /// Returns a logger handle for Gemini analytics — same shape as
    /// `llmAnalyticsContext`.
    public var geminiAnalyticsContext: AnalyticsContext? {
        makeAnalyticsContext()
    }

    /// The handle both analytics-context accessors hand out.
    ///
    /// `AnalyticsContext.logEvent` is a synchronous app-facing shape, so it
    /// enqueues without waiting — the same contract the deprecated
    /// `logAnalyticsEvent` has, and deprecated for the same reason beside its
    /// `logEventAsync` twin (#2244). Both talk to the queue directly rather
    /// than through the deprecated client method (#1993, Phase D3), and both
    /// capture the queue strongly because the handle outlives the call and
    /// holding the queue does not retain the client.
    ///
    /// Both lower the event through `prepareAnalyticsEvent` on the caller's
    /// thread: that is where the `Any` graph stops, where the event's
    /// `timestamp` is taken, and where a non-JSON-representable event is
    /// dropped *and logged* rather than disappearing — on both of its two
    /// rejection paths, the encoding and `prepared(_:)`.
    private func makeAnalyticsContext() -> AnalyticsContext {
        // `AnalyticsContext`'s logger closures carry the typed `[String:
        // JSONValue]` shape (#2367); `AnalyticsQueue.prepared(_:)` is still the
        // untyped `[String: Any]` boundary (same precedent as
        // `AnalyticsQueue.swift:148`'s doc comment describes), so lower back to
        // `Any` here before handing the event to the queue.
        AnalyticsContext(
            logEvent: { [analyticsQueue, logger] event in
                guard let prepared = Self.prepareAnalyticsEvent(
                    event, queue: analyticsQueue, logger: logger
                ) else { return }
                Task { await analyticsQueue.logEvent(prepared) }
            },
            logEventAsync: { [analyticsQueue, logger] event in
                guard let prepared = Self.prepareAnalyticsEvent(
                    event, queue: analyticsQueue, logger: logger
                ) else { return }
                await analyticsQueue.logEvent(prepared)
            }
        )
    }

    /// Lower a typed analytics event to the queue's untyped shape and prepare
    /// it, or return `nil` after saying why it could not ship.
    ///
    /// The lowering can fail — `JSONEncoder` rejects a non-finite
    /// `JSONValue.number` by default — and a `try?` there would have dropped
    /// the event without a word, contradicting the "dropped *and logged*"
    /// contract the accessor's doc comment states. Now both rejection paths
    /// (encoding here, `prepared(_:)` below) are equally visible.
    ///
    /// `static` so the closures keep capturing only the queue and the logger,
    /// neither of which retains the client.
    private static func prepareAnalyticsEvent(
        _ event: [String: JSONValue],
        queue: AnalyticsQueue,
        logger: Logger
    ) -> AnalyticsQueue.PreparedEvent? {
        let lowered: Any
        do {
            lowered = try JSONCoding.jsonObject(from: event)
        } catch {
            logger.warn("[analytics] dropping event that failed to encode:", error.localizedDescription)
            return nil
        }
        guard let eventAny = lowered as? [String: Any] else {
            logger.warn("[analytics] dropping event that did not encode to a JSON object")
            return nil
        }
        return queue.prepared(eventAny)
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
    private var retentionPolicyStorage: RetentionPolicy = .init()

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
    public var retentionPolicy: RetentionPolicy {
        get { lock.withLock { retentionPolicyStorage } }
        set {
            lock.withLock {
                retentionPolicyStorage = newValue
            }
            Task { [newValue, weak self] in
                await self?.documentManager.enforceRetentionPolicy(
                    ttlMs: newValue.ttl.map(\.wholeMilliseconds),
                    maxDocs: newValue.maxDocs,
                    maxBytes: newValue.maxBytes
                )
            }
        }
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
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.2
    ) async throws {
        try await pollUntil(timeout: timeout, pollInterval: pollInterval) {
            self.documentManager.isSynced(documentId)
        }
    }

    /// Wait until the client and server hold identical document state.
    /// Polls the live `checkStateVector` round trip until it reports
    /// `inSync`, throwing on timeout. Mirrors js-bao's `waitForInSync`.
    /// Because it depends on a real server round trip, it correctly does
    /// NOT confirm while the socket is down or a local edit is still in the
    /// outbound debounce — `checkStateVector` reports `(false, false)` then.
    public func waitForInSync(
        documentId: String,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.2
    ) async throws {
        try await awaitStateVector(
            documentId: documentId,
            timeout: timeout,
            pollInterval: pollInterval,
            operation: "waitForInSync"
        ) { $0.inSync }
    }

    /// Wait until the server confirms it holds all of this client's writes.
    /// Polls the live `checkStateVector` round trip until it reports
    /// `includesWrites`, throwing on timeout. Mirrors js-bao's
    /// `waitForWriteConfirmation`. Because it depends on a real server round
    /// trip, it correctly does NOT confirm a write that's still in the 50ms
    /// outbound debounce or unsendable because the socket is down —
    /// `checkStateVector` reports `(false, false)` then.
    public func waitForWriteConfirmation(
        documentId: String,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.2
    ) async throws {
        try await awaitStateVector(
            documentId: documentId,
            timeout: timeout,
            pollInterval: pollInterval,
            operation: "waitForWriteConfirmation"
        ) { $0.includesWrites }
    }

    /// Poll the live `checkStateVector` round trip until `satisfied` reports
    /// true or the caller's `timeout` elapses, throwing `.unavailable` on
    /// timeout. Each inner round trip is bounded by the caller's *remaining*
    /// time, not `checkStateVector`'s default 5s: when the socket is open but
    /// the server never answers a `stateVectorCheck`, an unbounded inner call
    /// would block for the full 5s before the outer deadline was re-checked,
    /// so a short-timeout waiter (e.g. `waitForInSync(timeout: 0.3)`) could
    /// block for ~5s instead of the requested 300ms (issue #1979).
    private func awaitStateVector(
        documentId: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        operation: String,
        satisfied: (_ verdict: (includesWrites: Bool, inSync: Bool)) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            // Bound the round trip by the time the caller still has, so a
            // silent server can't stretch the wait past `timeout`.
            if satisfied(await checkStateVector(documentId: documentId, timeout: remaining)) {
                return
            }
            // Sleep the poll interval, but never past the deadline.
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            let sleep = min(max(0, pollInterval), left)
            if sleep > 0 {
                try await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
            }
        }
        throw JsBaoError(
            code: .unavailable,
            message: "\(operation) timeout for \(documentId)"
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
        timeout: TimeInterval = 5
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
            stateVectorLock.withLock {
                stateVectorWaiters[documentId, default: []].append(
                    StateVectorWaiter(id: waiterId, continuation: continuation)
                )
            }

            // Resolve to a failure verdict if no response lands in time.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
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
        let resolved: StateVectorWaiter? = stateVectorLock.withLock {
            guard var waiters = stateVectorWaiters[documentId],
                  let idx = waiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            let waiter = waiters.remove(at: idx)
            if waiters.isEmpty {
                stateVectorWaiters.removeValue(forKey: documentId)
            } else {
                stateVectorWaiters[documentId] = waiters
            }
            return waiter
        }
        resolved?.continuation.resume(returning: result)
    }

    /// Route an incoming `stateVectorCheckResponse` to every waiter parked
    /// on this document.
    private func handleStateVectorCheckResponse(
        documentId: String,
        includesWrites: Bool,
        inSync: Bool
    ) {
        let waiters = stateVectorLock.withLock {
            stateVectorWaiters.removeValue(forKey: documentId) ?? []
        }
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
            timeout: timeout, pollInterval: 0.1
        ) {
            let state = self.authController.getAuthState()
            return state.authenticated || state.mode == .offline
        }
    }

    /// Common polling loop used by every `waitFor*` above. Returns when
    /// `predicate()` first returns true. Throws `unavailable` if the
    /// timeout elapses first.
    private func pollUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        // The predicate is invoked synchronously on this method's own
        // executor, once per poll iteration, and is never stored or sent
        // to another task — so it doesn't need to be `@Sendable`. Dropping
        // `@Sendable` lets a caller's predicate mutate captured state without
        // a false concurrent-mutation diagnostic (the closure never escapes
        // to concurrent execution).
        predicate: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: UInt64(max(0, pollInterval) * 1_000_000_000))
        }
        throw JsBaoError(
            code: .unavailable,
            message: "waitFor* timeout after \(timeout)s"
        )
    }

    /// The current auth state.
    public var authState: AuthState {
        authController.getAuthState()
    }

    /// The current user's id, or `nil` when unauthenticated.
    public var userId: String? {
        authController.getUserId()
    }

    /// Check if user is authenticated
    public func isAuthenticated() -> Bool {
        authController.isAuthenticated()
    }

    /// How the access token is persisted: `mode` is `"persisted"` or
    /// `"memory"`, and a persisted token also reports its storage-key
    /// `prefix`.
    public var authPersistenceInfo: [String: JSONValue] {
        var info: [String: JSONValue] = [:]
        if options.auth.persistJwtInStorage {
            info["mode"] = .string("persisted")
            info["prefix"] = .string(options.auth.storageKeyPrefix ?? "default")
        } else {
            info["mode"] = .string("memory")
        }
        return info
    }

    /// Logout.
    ///
    /// Convenience overload mirroring the original `wipeLocal`-only signature.
    /// Forwards to `logout(options:)`.
    public func logout(wipeLocal: Bool = false) async throws {
        try await logout(options: LogoutOptions(wipeLocal: wipeLocal))
    }

    /// Logout with the full JS option surface.
    ///
    /// Mirrors JS `logout(options)` (src/client/JsBaoClient.ts):
    ///  * `revokeOffline` — also revoke the stored offline access grant.
    ///  * `wipeLocal` — delete all locally cached document data and the KV
    ///    cache on the way out.
    ///  * `clearOfflineIdentity` — drop the in-memory offline identity
    ///    (defaults to `true`, matching JS).
    ///  * `waitForDisconnect` — await WebSocket teardown before returning;
    ///    when `false` (the default) the socket is still torn down here, just
    ///    not awaited inside the auth controller.
    ///
    /// (`redirectTo` is web-only `window.location` navigation and has no
    /// native analog — apps drive their own navigation after logout, so it is
    /// intentionally not modeled on `LogoutOptions`.)
    public func logout(options: LogoutOptions) async throws {
        try await authController.logout(options: options)
        if options.wipeLocal {
            await documentManager.evictAllLocalData()
            await kvCache.clearAll()
        }
        await disconnect()
    }

    // MARK: - OAuth

    /// Start an OAuth flow. Returns the authorization URL to open in a browser.
    ///
    /// This is the raw building block for apps that drive their own auth UI.
    /// For the one-call native experience (system browser sheet + callback +
    /// code exchange), use `signInWithGoogle(presentationAnchor:)` instead
    /// (see GoogleSignIn.swift, issue #928).
    ///
    /// - Parameters:
    ///   - redirectUri: The OAuth redirect URI (must be allow-listed for the app).
    ///   - continueUrl: Optional URL threaded through the state bag to return to
    ///     after the flow completes.
    ///   - waitlist: Optional waitlist enrollment carried through the state bag.
    ///     Mirrors JS `startOAuthFlow(continueUrl, { waitlist })` — the callback
    ///     enrolls the user in the app's waitlist (#466).
    ///   - inviteToken: Optional invite token threaded through the state bag.
    ///     Mirrors JS `startOAuthFlow(continueUrl, { inviteToken })` — the
    ///     callback accepts the named invitation server-side and resolves
    ///     deferred grants to the new user even when the OAuth email differs
    ///     from the invited email (#466).
    public func startOAuthFlow(
        redirectUri: String,
        continueUrl: String? = nil,
        waitlist: OAuthWaitlist? = nil,
        inviteToken: String? = nil
    ) async throws -> URL {
        try await authController.startOAuthFlow(
            redirectUri: redirectUri,
            continueUrl: continueUrl,
            waitlist: waitlist,
            inviteToken: inviteToken
        )
    }

    /// Handle the OAuth callback after the user authorizes. Exchanges the code
    /// for a token and applies it (emitting `.authSuccess` / `.authState`).
    ///
    /// Mirrors JS `handleOAuthCallback` sequencing (src/client/JsBaoClient.ts):
    /// after the exchange, reconnect the WebSocket if it isn't OPEN. When the
    /// socket IS open, JS sends an in-band auth-refresh frame; the Swift
    /// `WebSocketManager` has no in-band refresh yet, so we force a reconnect
    /// to re-authenticate the connection with the new token.
    ///
    /// Returns the typed server response (`{token, isNewUser}`) so callers
    /// can read `isNewUser`.
    @discardableResult
    public func handleOAuthCallback(code: String, state: String) async throws -> OAuthCallbackResult {
        let result = try await authController.handleOAuthCallback(code: code, state: state)
        if !wsManager.isSocketOpen {
            try? await connect()
        } else {
            await wsManager.forceReconnect()
        }
        return result
    }

    // MARK: - Sign in with Apple

    /// Exchange a native Sign in with Apple credential for a session token
    /// (`POST /auth/apple/callback`) and apply it (cause `"apple"`, emitting
    /// `.authSuccess` / `.authState`), then re-authenticate the WebSocket —
    /// the same post-exchange sequencing as `handleOAuthCallback`.
    ///
    /// Internal: the public entry point is the one-call
    /// `signInWithApple(presentationAnchor:)` (AppleSignIn.swift); unlike
    /// Google's raw OAuth building blocks there is no JS-client counterpart
    /// to mirror, so the wire method stays internal.
    @discardableResult
    func handleAppleCallback(
        identityToken: String,
        rawNonce: String,
        user: String,
        email: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        inviteToken: String? = nil
    ) async throws -> OAuthCallbackResult {
        let result = try await authController.handleAppleCallback(
            identityToken: identityToken,
            rawNonce: rawNonce,
            user: user,
            email: email,
            firstName: firstName,
            lastName: lastName,
            inviteToken: inviteToken
        )
        if !wsManager.isSocketOpen {
            try? await connect()
        } else {
            await wsManager.forceReconnect()
        }
        return result
    }

    // MARK: - Magic Link

    /// Request a magic link email for the given address.
    public func magicLinkRequest(email: String, redirectUri: String) async throws -> Bool {
        try await authController.magicLinkRequest(email: email, redirectUri: redirectUri)
    }

    /// Verify a magic link token received from the email callback.
    ///
    /// `inviteToken` mirrors JS `magicLinkVerify(token, { inviteToken })`
    /// (#466): when present, the named invitation is accepted server-side
    /// during verify and deferred grants resolve to the signing-in user, even
    /// when the magic-link email differs from the invited email.
    public func magicLinkVerify(
        token: String,
        inviteToken: String? = nil
    ) async throws -> MagicLinkVerifyResult {
        try await authController.magicLinkVerify(token: token, inviteToken: inviteToken)
    }

    // MARK: - OTP

    /// Request a one-time password sent to the given email.
    public func otpRequest(email: String) async throws -> Bool {
        try await authController.otpRequest(email: email)
    }

    /// Verify a one-time password code.
    ///
    /// `inviteToken` mirrors JS `otpVerify(email, code, { inviteToken })`
    /// (#466 / #1110): when present, the named invitation is accepted
    /// server-side during verify and deferred grants resolve to the
    /// signing-in user, even when the signup email differs from the
    /// invited email.
    public func otpVerify(
        email: String,
        code: String,
        inviteToken: String? = nil
    ) async throws -> OtpVerifyResult {
        try await authController.otpVerify(email: email, code: code, inviteToken: inviteToken)
    }

    // MARK: - Token Management

    /// Update the auth token externally (e.g. after a custom auth flow).
    public func updateToken(_ token: String?, cause: String? = nil) {
        authController.updateToken(token, cause: cause)
    }

    /// The decoded claims of the current JWT, or `nil` when there is no
    /// token (or it cannot be decoded).
    public var jwtPayload: [String: JSONValue]? {
        guard let claims = authController.getJwtPayload() else { return nil }
        // The claims come straight out of `JSONSerialization` on the token's
        // payload segment, so every value is already JSON-representable and
        // the lowering cannot fail in practice. `try?` keeps the property
        // non-throwing rather than promising something the type can't.
        return try? JSONValue.typedRow(from: claims, subject: "JWT payload")
    }

    // MARK: - Network Mode

    /// Reporting-only connectivity check. In `.auto` mode this now reflects
    /// real socket connectivity (`true` only when the transport is connected),
    /// matching the JS client's `isOnline()`; explicit `.online`/`.offline`
    /// stay unconditionally `true`/`false`. This does NOT gate networking —
    /// reconnect/sync/request gating goes through the internal
    /// `networkingAllowed()` (mode-based), so a reporting change here never
    /// suppresses the reconnect loop.
    public func isOnline() -> Bool {
        networkStatus.isOnline
    }

    /// Internal networking gate — "may networking be attempted right now?".
    /// Mode-based so an unexpected socket close in `.auto` (reachable still
    /// `true`) keeps returning `true` and the reconnect loop survives. With
    /// monitoring off `reachable` stays `true`, so this equals the old
    /// `mode != .offline` and no gating behavior changes.
    internal func networkingAllowed() -> Bool {
        lock.withLock { (networkModeStorage == .online) || (networkModeStorage == .auto && reachable) }
    }

    /// The single reporting formula shared by `networkStatus.isOnline`
    /// and the emitted `NetworkModeEvent.isOnline`, so the two always agree
    /// (JS-identical blend of mode + transport).
    internal func reportedOnline(mode: NetworkMode, transport: ConnectionStatus) -> Bool {
        (mode == .online) || (mode == .auto && transport == .connected)
    }

    /// Snapshot the reported-online value from the current mode + live
    /// transport. Reads the client `lock` and the WS manager's own lock
    /// separately (never nested) — snapshot-only, so a value emitted here may
    /// briefly precede an async transport change.
    private func computeReportedOnline() -> Bool {
        let mode = lock.withLock { networkModeStorage }
        return reportedOnline(mode: mode, transport: wsManager.connectionStatus)
    }

    // MARK: - Events

    /// Observe every occurrence of one event as an async sequence.
    ///
    /// The payload type names the event, so there is no separate event argument
    /// to get wrong:
    ///
    /// ```swift
    /// .task {
    ///     for await status in client.stream(for: StatusChangedEvent.self) {
    ///         isConnected = status.status == .connected
    ///     }
    /// }
    /// ```
    ///
    /// **Isolation is the consuming task's own.** An `AsyncStream`'s elements are
    /// always delivered where they are awaited, so inside a SwiftUI `.task` the
    /// loop body already runs on the main actor with no hop. For a callback that
    /// cannot hold a `for await` loop, use ``observeOnMainActor(_:handler:)``.
    ///
    /// **Ordering** is per-stream FIFO: one stream sees its own event in emit
    /// order. Two streams give no order *relative to each other* — if you need
    /// one event ordered against another, await them in a single task or use one
    /// `observeOnMainActor` callback per event.
    ///
    /// **Lifetime.** The subscription lives as long as the stream does, which is
    /// `AsyncStream`'s own rule: it ends once both the stream value and every
    /// iterator taken from it are released. In the normal form —
    /// `for await event in client.stream(for: …)` — the stream value is a
    /// temporary the loop owns, so ending the loop, cancelling the enclosing
    /// task, or leaving the scope all unsubscribe.
    ///
    /// Storing the stream in a variable changes that, exactly as it does for a
    /// plain `AsyncStream`: with `let events = client.stream(for: …)`, breaking
    /// out of `for await … in events` leaves `events` holding the subscription,
    /// and events keep filling its buffer until that variable is released. If you
    /// need to hold a stream and stop early, cancel the task doing the iterating
    /// and release the variable. Under the default `.unbounded` policy a stream
    /// left in this state logs a debug warning naming the event once it passes
    /// 1,000 undrained elements.
    ///
    /// The stream finishes when the client is deinitialized, so a `for await`
    /// loop exits rather than hanging.
    ///
    /// A one-shot event that already fired is not redelivered — a stream opened
    /// after `documentLoaded` waits for the next document. Pair the stream with
    /// the matching getter (or `replayingLatest:` below) when the current value
    /// matters.
    ///
    /// - Parameters:
    ///   - type: The payload type to observe.
    ///   - buffering: What to do with elements a slow consumer has not drained.
    ///     The default `.unbounded` never drops an event, which is what
    ///     connection and document-lifecycle events need. Pass
    ///     `.bufferingNewest(1)` for the high-frequency events where only the
    ///     latest value matters — `AwarenessEvent`, `BlobUploadProgressEvent`,
    ///     `SyncPerfEvent`, `DocumentSyncStateChangedEvent`. Under `.unbounded` a
    ///     consumer that stops draining grows the buffer; the client logs a
    ///     debug warning naming the event once a stream passes 1,000 undrained
    ///     elements.
    ///   - replayingLatest: Deliver the event's most recent value immediately, if
    ///     one is retained. Off by default. Retained only for the client-global
    ///     state-like events whose payload type reports
    ///     ``JsBaoEventPayload/isReplayable`` — `StatusChangedEvent`,
    ///     `NetworkModeEvent`, `AuthStateEvent`. Because a `.task` starts after
    ///     the view appears, a status stream without replay commonly misses the
    ///     connection that already happened. Asking for replay on any other
    ///     event is harmless — there is simply nothing retained to deliver.
    public func stream<E: JsBaoEventPayload>(
        for type: E.Type,
        buffering: AsyncStream<E>.Continuation.BufferingPolicy = .unbounded,
        replayingLatest: Bool = false
    ) -> AsyncStream<E> {
        eventEmitter.makeStream(
            for: type,
            buffering: buffering,
            replayingLatest: replayingLatest
        )
    }

    /// Observe one event with a handler that runs on the main actor.
    ///
    /// For callers that cannot hold a `for await` loop — an `ObservableObject`
    /// that wires its subscriptions in `init`, for example. The handler's
    /// isolation is in the name: it always runs on the main actor, so no
    /// `Task { @MainActor in … }` wrapper is needed at the call site.
    ///
    /// ```swift
    /// statusSubscription = client.observeOnMainActor(StatusChangedEvent.self) { [weak self] event in
    ///     self?.isConnected = event.status == .connected
    /// }
    /// ```
    ///
    /// Hold the returned ``EventSubscription`` for as long as you want the
    /// handler live — dropping it cancels the subscription. Delivery is one hop
    /// onto the main actor per event, so events observed this way are not ordered
    /// against events observed through ``stream(for:buffering:replayingLatest:)``.
    /// Use `stream(for:)` for anything off the main actor.
    ///
    /// **Ordering.** Two `observeOnMainActor` handlers on the *same* client —
    /// including handlers for different event types — run in emit order. The hop
    /// is enqueued synchronously inside the emit, onto the main queue, which
    /// delivers in enqueue order.
    ///
    /// **Cancellation.** `cancel()` (or dropping the subscription) called *on the
    /// main actor* is immediate: no handler runs after it returns, including for
    /// an event that was already emitted and is waiting for its hop. Cancelling
    /// from another thread also stops any hop that has not started running yet;
    /// the only call it cannot stop is one already executing on the main actor.
    ///
    /// The result is deliberately not `@discardableResult`: dropping it cancels
    /// the subscription immediately, so the unused-result warning is the only
    /// mechanical protection against a handler that silently never fires.
    ///
    /// **Timing.** The handler runs one hop after the emit, so a `Date()` taken
    /// inside it includes that hop. When the timestamp has to be the emit's own,
    /// use ``observeOnMainActor(_:withDelivery:)`` and read
    /// ``EventDelivery/emittedAt``.
    public func observeOnMainActor<E: JsBaoEventPayload>(
        _ type: E.Type,
        handler: @escaping @Sendable @MainActor (E) -> Void
    ) -> EventSubscription {
        // Wraps the metadata form and discards the metadata, so isolation,
        // ordering and cancellation cannot drift apart between the two.
        observeOnMainActor(type, withDelivery: { event, _ in handler(event) })
    }

    /// Observe one event on the main actor, with the emit's delivery metadata.
    ///
    /// Same subscription as ``observeOnMainActor(_:handler:)`` — same main-actor
    /// isolation, same emit ordering, same cancellation — with an
    /// ``EventDelivery`` describing *when the client emitted* rather than when
    /// the handler got to run:
    ///
    /// ```swift
    /// subscription = client.observeOnMainActor(DocumentLoadedEvent.self, withDelivery: { event, delivery in
    ///     rows.append(Row(at: delivery.emittedAt, order: delivery.sequence, id: event.documentId))
    /// })
    /// ```
    ///
    /// Delivery is one hop onto the main actor, so a handler that stamps its own
    /// `Date()` measures that hop as well as the client's work. Anything
    /// building a timeline — a debug inspector, a latency report — should take
    /// its timestamp from ``EventDelivery/emittedAt`` and sort on
    /// ``EventDelivery/sequence``. Comparing the two is itself useful: the gap
    /// is the cost of the hop, which is largest exactly when the main thread is
    /// the thing being investigated.
    ///
    /// A distinct argument label rather than an overload of the same name:
    /// two same-arity `observeOnMainActor` overloads would make a call site
    /// whose closure takes anonymous parameters ambiguous.
    ///
    /// As with the no-metadata form, the result is deliberately not
    /// `@discardableResult` — dropping it cancels the subscription.
    public func observeOnMainActor<E: JsBaoEventPayload>(
        _ type: E.Type,
        withDelivery handler: @escaping @Sendable @MainActor (E, EventDelivery) -> Void
    ) -> EventSubscription {
        // The gate is what makes cancellation reach a hop that is already
        // enqueued: cancelling only removes the emitter callback, so without it
        // a handler could still mutate its owner's UI after that owner cancelled
        // or re-keyed the subscription.
        let gate = MainActorDeliveryGate()
        let inner = eventEmitter.subscribe(type) { event, delivery in
            // `DispatchQueue.main.async`, not `Task { @MainActor in … }`. The
            // main queue is FIFO, so hops enqueued from inside successive emits
            // run in emit order. Separate unstructured `Task`s only get serial
            // *execution* on the main actor — the runtime does not promise FIFO
            // *scheduling* of independent tasks, and two enqueued at different
            // priorities can run out of emit order.
            DispatchQueue.main.async {
                guard !gate.isCancelled else { return }
                MainActor.assumeIsolated { handler(event, delivery) }
            }
        }
        // Captured strongly: `inner` is the only reference to the emitter-side
        // subscription, and `EventSubscription.deinit` cancels.
        return EventSubscription {
            gate.cancel()
            inner.cancel()
        }
    }

    /// Wait for the next occurrence of one event.
    ///
    /// ```swift
    /// let loaded = try await client.nextEvent(DocumentLoadedEvent.self) { $0.documentId == docId }
    /// ```
    ///
    /// - Parameters:
    ///   - type: The payload type to wait for.
    ///   - timeout: Seconds to wait before throwing.
    ///   - predicate: Optional filter; the first event it accepts is returned.
    ///     Events it rejects are ignored and the wait continues.
    /// - Returns: The first matching event.
    /// - Throws: `JsBaoError` with code `.unavailable` if `timeout` elapses
    ///   first. An event that already fired is not redelivered, so start the
    ///   wait before triggering the work you are waiting on.
    public func nextEvent<E: JsBaoEventPayload>(
        _ type: E.Type,
        timeout: TimeInterval = 10,
        where predicate: (@Sendable (E) -> Bool)? = nil
    ) async throws -> E {
        try await eventEmitter.waitForNextEvent(
            type,
            timeout: timeout,
            predicate: predicate
        )
    }

    // MARK: - Network

    /// The current network mode. Setting it is equivalent to calling
    /// ``setNetworkMode(_:options:)`` with default options.
    public var networkMode: NetworkMode {
        get { lock.withLock { networkModeStorage } }
        set { setNetworkMode(newValue) }
    }

    /// Detailed network status — mode, transport, reachability and the
    /// reason for the last transition.
    public var networkStatus: NetworkStatus {
        // Reads the STORAGE, not the `networkMode` property: that property's
        // getter takes `lock` itself, and `lock` is a non-recursive `NSLock`,
        // so going through it here would deadlock. Before #2367 renamed it,
        // `networkMode` *was* the storage and this read was direct.
        let (mode, lastOnline, reason) = lock.withLock {
            (networkModeStorage, lastOnlineAt, lastReason)
        }
        let transport = wsManager.connectionStatus
        return NetworkStatus(
            mode: mode,
            transport: transport,
            isOnline: reportedOnline(mode: mode, transport: transport),
            lastOnlineAt: lastOnline,
            reason: reason
        )
    }

    /// Switch to online mode.
    ///
    /// Awaited form of the `setNetworkMode(.online)` auth handoff —
    /// exactly like JS, where `goOnline()` is just
    /// `setNetworkMode("online")`. Use this when the caller wants to
    /// observe the full handoff (refresh attempt → connect, or
    /// `.authOnlineRequired` + offline revert) before continuing.
    public func goOnline() async {
        applyNetworkMode(.online, options: SetNetworkModeOptions())
        await runOnlineAuthHandoff()
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
    ///
    /// Setting `.online` kicks the same auth handoff JS's
    /// `setNetworkMode("online")` runs (#1059 / #1113): the mode flips
    /// to `.online` first (emitting `networkMode`, same as JS), then —
    /// asynchronously, since this method is synchronous — if there is
    /// no valid token a refresh is attempted before connecting. When
    /// re-authentication fails, `.authOnlineRequired` fires (JS
    /// `auth:onlineAuthRequired`, payload `{}`) and the mode reverts to
    /// `.offline` (emitting a second `networkMode`), never connecting
    /// without a token. `goOnline()` runs the identical handoff,
    /// awaited.
    public func setNetworkMode(
        _ mode: NetworkMode,
        options: SetNetworkModeOptions = SetNetworkModeOptions()
    ) {
        applyNetworkMode(mode, options: options)
        if mode == .online {
            Task { [weak self] in
                await self?.runOnlineAuthHandoff()
            }
        }
    }

    /// Flip the stored mode and emit `networkMode` — the synchronous
    /// core shared by `setNetworkMode` and `goOnline` (which must not
    /// double-kick the online auth handoff).
    private func applyNetworkMode(
        _ mode: NetworkMode,
        options: SetNetworkModeOptions = SetNetworkModeOptions()
    ) {
        let reason = options.reason ?? "user_set"
        let enteredAuto: Bool = lock.withLock {
            let wasAuto = networkModeStorage == .auto
            networkModeStorage = mode
            lastReason = reason
            return mode == .auto && !wasAuto
        }
        authController.setNetworkMode(mode)
        eventEmitter.emit(NetworkModeEvent(
            mode: mode,
            isOnline: computeReportedOnline(),
            reason: reason
        ))
        // Transitioning INTO `.auto` must reconcile the socket to the current
        // reachability bit: `applyReachability` only reacts to reachability
        // *changes*, so a pin→`.auto` switch would otherwise leave the socket
        // out of step with a bit that changed while pinned.
        if enteredAuto {
            reconcileAutoSocket()
        }
    }

    /// Drive the socket to match the current `reachable` bit right after the
    /// client enters `.auto`. Without this, an offline client that became
    /// reachable while pinned never reconnects (no fresh monitor event follows
    /// the mode switch), and a connected client that became unreachable while
    /// pinned is never paused.
    ///
    /// This is mode→socket reconciliation only — it NEVER writes `networkMode`
    /// (the monitor never mutates mode, Fork A). It mirrors `applyReachability`'s
    /// decide-under-lock / act-outside discipline and reuses the SAME restore
    /// (`runOnlineAuthHandoff`) and pause (`setShouldConnect(false)`) paths the
    /// monitor uses, so both routes stay consistent.
    private func reconcileAutoSocket() {
        enum Action { case restore, pause }
        let action: Action? = lock.withLock {
            if isDestroyed { return nil }
            guard networkModeStorage == .auto else { return nil }
            return reachable ? .restore : .pause
        }
        guard let action else { return }
        switch action {
        case .restore:
            // Token refresh → connect, via the desired-connection path (see
            // `runOnlineAuthHandoffImpl`). In `.auto` its failure branch pauses
            // without mutating mode (Fork A).
            Task { [weak self] in await self?.runOnlineAuthHandoff() }
        case .pause:
            // Stop the reconnect loop + close the socket, matching the monitor's
            // `.pause` branch.
            Task { [weak self] in await self?.pauseSocketForReachabilityLoss() }
        }
    }

    /// The deferred pause action shared by `applyReachability` and
    /// `reconcileAutoSocket` — the body of the unstructured `Task` both queue.
    ///
    /// Revalidates before acting (#2078). Both callers decide under `lock` and
    /// act outside it, so by the time this task is scheduled the client may
    /// have transitioned again: the app pinned `.online`, or reachability came
    /// back and the restore handoff already reconnected. Pausing on that stale
    /// decision would close the socket and leave `shouldConnect == false` after
    /// the NEWER transition, stranding the client offline with reconnect
    /// disabled. The guard is `networkingAllowed()` — the exact mirror of the
    /// restore path's `guard networkingAllowed() else { return }` — so the
    /// latest state wins on both sides: pause only while networking is still
    /// disallowed (`.offline`, or `.auto` and still unreachable).
    internal func pauseSocketForReachabilityLoss() async {
        guard !networkingAllowed() else { return }
        await setShouldConnect(false)
    }

    // MARK: - Connectivity monitoring (#1987, Phase 2)

    /// Wire the injected/real monitor to `handleReachabilityChange`. Called
    /// from `setupStorage` only when `autoNetwork` is true.
    private func startConnectivityMonitor() {
        connectivityMonitor?.start { [weak self] reachable in
            self?.handleReachabilityChange(reachable)
        }
    }

    /// Debounce a raw reachability callback (which may arrive on any queue)
    /// before applying it. Each transition replaces the pending work item, so
    /// flapping within the window coalesces to a single reaction. Intervals
    /// mirror the JS listeners: 100 ms for a loss, 300 ms for a restore.
    ///
    /// The FIRST snapshot skips the debounce entirely. `NWPathMonitor` emits
    /// the current path almost immediately after `start(queue:)`, and the
    /// startup gate (`awaitInitialReachability`) blocks the first connect
    /// attempt until that snapshot is applied — so debouncing it would cost
    /// every cold start on a working network the full 300 ms restore window
    /// for nothing. The debounce exists to coalesce flapping, and the first
    /// snapshot has no predecessor to flap against. It still runs through
    /// `applyReachability` before latching, so the gate reads the real path
    /// state rather than the `reachable = true` default.
    private func handleReachabilityChange(_ reachable: Bool) {
        let isFirst: Bool = lock.withLock {
            if isDestroyed { return false }
            if initialReachabilityClaimed { return false }
            initialReachabilityClaimed = true
            return true
        }
        if isFirst {
            applyReachability(
                reachable,
                reason: reachable ? ConnectivityReason.restored : ConnectivityReason.lost
            )
            signalInitialReachability()
            return
        }

        let delayMs = reachable ? 300 : 100
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyReachability(
                reachable,
                reason: reachable ? ConnectivityReason.restored : ConnectivityReason.lost
            )
            self.signalInitialReachability()
        }
        let scheduled: DispatchWorkItem? = lock.withLock {
            if isDestroyed { return nil }
            reachabilityDebounce?.cancel()
            reachabilityDebounce = work
            return work
        }
        guard let scheduled else { return }
        reachabilityQueue.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: scheduled)
    }

    /// Apply a settled reachability value. Decides under `lock`, acts outside
    /// it (the #1910 discipline). `networkMode` is NEVER written here — the
    /// socket is driven only in `.auto`; explicit `.online`/`.offline` record
    /// the bit but stay user-pinned.
    internal func applyReachability(_ reachable: Bool, reason: String) {
        enum Action { case noop, pause, restore }
        let decision: (action: Action, mode: NetworkMode)? = lock.withLock {
            if isDestroyed { return nil }
            if self.reachable == reachable { return nil } // dedup
            self.reachable = reachable
            self.lastReason = reason
            let act: Action = (networkModeStorage == .auto)
                ? (reachable ? .restore : .pause)
                : .noop
            return (act, networkModeStorage)
        }
        guard let decision else { return }

        // Reporting/observability event — mode UNCHANGED, isOnline recomputed
        // (reads the WS manager outside the client lock).
        eventEmitter.emit(NetworkModeEvent(
            mode: decision.mode,
            isOnline: computeReportedOnline(),
            reason: reason
        ))

        switch decision.action {
        case .noop:
            break
        case .pause:
            // Stop the reconnect loop + close the socket. `networkingAllowed()`
            // is now false (reachable false in `.auto`), so the reconnect
            // delegate also returns false.
            Task { [weak self] in await self?.pauseSocketForReachabilityLoss() }
        case .restore:
            // Reuse the online-auth handoff (token refresh → connect). In
            // `.auto` its failure branch pauses without mutating mode (Fork A).
            Task { [weak self] in await self?.runOnlineAuthHandoff() }
        }
    }

    /// Latch the first-snapshot flag so the startup gate stops awaiting.
    private func signalInitialReachability() {
        lock.withLock { initialReachabilityReceived = true }
    }

    /// Test seam: whether the startup gate's first-snapshot latch is set. Lets
    /// a test assert the first snapshot is applied without waiting out a
    /// debounce interval.
    internal var initialReachabilityLatched: Bool {
        lock.withLock { initialReachabilityReceived }
    }

    /// Await the monitor's first applied reachability snapshot (or a timeout),
    /// so a down path at startup means no auto-connect. Polls rather than
    /// parking a continuation to avoid a leaked continuation if the monitor
    /// never fires.
    private func awaitInitialReachability(timeoutMs: Int) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while true {
            let received = lock.withLock { initialReachabilityReceived }
            if received || Date() >= deadline { return }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        }
    }

    /// In-flight online-auth handoff, for coalescing. Concurrent
    /// `.online` entries (two quick `setNetworkMode(.online)` calls, or
    /// `setNetworkMode(.online)` racing `goOnline()`) await the same
    /// task instead of running two handoffs — the refresh is already
    /// single-flight in `AuthController` and `connect()` tolerates
    /// concurrent entry, but a doubled *failed* handoff would emit
    /// `.authOnlineRequired` twice. JS can't race here (its handoff
    /// runs inline in `setNetworkMode`).
    private var pendingOnlineHandoff: Task<Void, Never>?

    /// The `setNetworkMode("online")` auth handoff (#1059 / #1113),
    /// mirroring JS: with no token, attempt a refresh before connecting;
    /// on failure emit `.authOnlineRequired`, revert to offline
    /// (`networkMode` fires again with reason "onlineAuthRequired"),
    /// and disconnect — never connect without a token. With a usable
    /// token, just connect.
    internal func runOnlineAuthHandoff() async {
        // Single-flight: check the in-flight handoff and register a new one in
        // ONE lock hold (matching AuthController's refresh coalescing), then
        // await outside the lock. Only the caller that started the task clears
        // `pendingOnlineHandoff` — a coalesced caller just awaits and returns,
        // exactly as the raw-lock version did.
        enum HandoffStart {
            case existing(Task<Void, Never>)
            case started(Task<Void, Never>)
        }
        let start: HandoffStart = lock.withLock {
            if let inFlight = pendingOnlineHandoff {
                return .existing(inFlight)
            }
            let task = Task<Void, Never> { [weak self] in
                await self?.runOnlineAuthHandoffImpl()
            }
            pendingOnlineHandoff = task
            return .started(task)
        }

        switch start {
        case .existing(let inFlight):
            await inFlight.value
        case .started(let task):
            await task.value
            lock.withLock { pendingOnlineHandoff = nil }
        }
    }

    private func runOnlineAuthHandoffImpl() async {
        // The mode may have been flipped away (e.g. an immediate
        // `setNetworkMode(.offline)`) before this fire-and-forget task
        // ran — JS runs the handoff inline so it can't race like this.
        // The guard is `networkingAllowed()` (mode-based) rather than
        // `mode == .online` so the same handoff also serves the Phase 2
        // reachability-restore path (`.auto` + reachable), not only explicit
        // `.online`.
        guard networkingAllowed() else { return }
        if authController.getToken() == nil {
            let outcome = await authController.refreshAccessToken(
                cause: "networkMode:online"
            )
            if outcome != .success {
                eventEmitter.emit(AuthOnlineRequiredEvent())
                // Fork A = A — mode-at-decision-point (not a coalescing-unsafe
                // flag): revert to `.offline` ONLY when the current mode is the
                // explicit `.online`. A reachability-driven restore runs in
                // `.auto`, where we pause the socket (`setShouldConnect(false)`)
                // WITHOUT mutating the mode — the monitor never writes mode.
                if networkMode == .online {
                    applyNetworkMode(
                        .offline,
                        options: SetNetworkModeOptions(reason: "onlineAuthRequired")
                    )
                    await disconnect()
                } else {
                    await setShouldConnect(false)
                }
                return
            }
        }
        // Re-check right before connecting: the `await` above is a suspension
        // point, so a `goOffline()` could have landed while we were refreshing.
        //
        // Connect through the desired-connection path (`setShouldConnect(true)`)
        // rather than `connect()` directly. `connect()` only sets
        // `shouldConnect = true` on the path where it actually starts a new
        // socket — on the already-connected early-return it does NOT touch
        // `shouldConnect`. So if a still-in-flight reachability-loss disconnect
        // has left `shouldConnect == false`, a bare `connect()` would early-out
        // and the pending disconnect would then close the socket with reconnect
        // still disabled, stranding an `.auto`+reachable client offline.
        // `setShouldConnect(true)` instead waits for any in-flight disconnect to
        // finish, then sets `shouldConnect = true` under the manager's lock
        // before connecting — so the restore's intent is recorded atomically and
        // serialized after the loss disconnect, and always wins. (JS runs the
        // handoff inline, so it can't hit this window.)
        guard networkingAllowed() else { return }
        await setShouldConnect(true)

        // Re-drive any documents created while offline. `createDocument` only
        // schedules the background server commit when already online, and
        // nothing else re-triggers it on the online transition — so offline
        // creates would otherwise sit in `pendingCreate` indefinitely. Mirrors
        // js-bao's `autoCommitPendingCreates("online", …)`.
        for documentId in listPendingCreates() {
            documentManager.scheduleCommitRetry(documentId: documentId)
        }
    }

    // MARK: - Offline Access

    /// Enable offline access by requesting a grant from the server and storing it securely.
    /// Requires online connectivity.
    public func enableOfflineAccess(options: EnableOfflineAccessOptions = EnableOfflineAccessOptions()) async throws -> EnableOfflineAccessResult {
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

    /// The status of the offline access grant.
    public var offlineGrantStatus: OfflineGrantStatus {
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

    /// The offline identity, available after `unlockOffline` succeeds.
    public var offlineIdentity: OfflineIdentity? {
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

        // Sample "does this doc already hold data?" here — before anything
        // else in this method can write into the ydoc. The sync decision
        // below consumes it.
        //
        // `connectToSharedModels` no longer writes anything: since #2587
        // `_meta_<model>` is written on the save path, matching js-bao's
        // `BaseModel.save`, so registering models before opening leaves the
        // ydoc byte-empty. Keep the sample here anyway — the ordering is the
        // invariant (JS decides `hasLocal` first and connects the local query
        // engine after), and sampling after a connect that regains a write
        // would report a brand-new empty doc as "has local data" and make
        // `.localIfAvailableElseNetwork` return an empty document instead of
        // waiting for server state (#2475).
        let effectiveHasLocal = documentManager.ydocHasData(documentId)

        // Mirror the doc into every registered cross-document store so
        // `Model.query()` sees it. Covers `openDocumentByAlias` too (it
        // funnels through here).
        connectToSharedModels(documentId: documentId, doc: doc)

        // Mirror JS `openDocument`'s `requestSyncPerf` option: flag the doc
        // so subsequent syncStep1 messages carry `requestPerf: true` and
        // the server replies with `syncPerf` telemetry frames (#996).
        if options.requestSyncPerf {
            documentManager.setSyncPerfRequested(documentId, true)
        }

        // Start network sync if requested. `deferNetworkSync` opens the
        // document locally without kicking off sync — the caller drives it
        // later via `startNetworkSync(documentId:)`. Mirrors JS `open`'s
        // `deferNetworkSync` short-circuit.
        //
        // The same condition was recorded per document by
        // `DocumentManager.openDocument` (JS `startNetworkModeByDoc`), so
        // later client-driven sync triggers — the post-commit re-sync for a
        // pending create — honor the caller's choice too.
        if options.enableNetworkSync && !options.deferNetworkSync && networkingAllowed() {
            // Decide whether to block on the sync handshake before returning
            // (JS parity — JsBaoClient.ts `canResolveEarly`/`needsNetworkWait`):
            //   .network                                   → always wait
            //   .localIfAvailableElseNetwork + ydoc HAS data → resolve now, sync in background
            //   .localIfAvailableElseNetwork + ydoc EMPTY    → wait for network
            //   .local                                       → never wait
            // The else-network half was previously unimplemented: only
            // `.network` ever waited, so a doc with no local copy (first
            // open on a second device, fresh install) returned an EMPTY
            // YDocument immediately and callers raced the `.sync` event —
            // surfacing as "Story not found" flashes in StoryLens.
            //
            // `effectiveHasLocal` was read at the top of this method, before
            // any write into the ydoc — matching the JS evaluation order
            // (`canResolveEarly` decides `hasLocal` first). It must not be
            // re-read here: `startNetworkSync` is an await suspension, and a
            // fast server `syncComplete` landing in that window would flip
            // the answer to "has data" and skip the wait.
            await startNetworkSync(documentId: documentId)
            let needsNetworkWait =
                options.waitForLoad == .network
                || (options.waitForLoad == .localIfAvailableElseNetwork && !effectiveHasLocal)
            if needsNetworkWait && !documentManager.isSynced(documentId) {
                let syncDocId = documentId
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    // One `SubscriptionHolder` owns everything this wait has to
                    // settle: the `.sync` subscription, the availability-timeout
                    // task, and the resume-once claim. It cannot be a captured
                    // `var` — the handler can fire on the WebSocket's thread
                    // before `subscribe` has returned here, so reading a plain
                    // local would race the assignment. That race is the second
                    // `EventSubscription` entry in #1910's ThreadSanitizer
                    // baseline.
                    let wait = SubscriptionHolder()
                    wait.set(self.eventEmitter.subscribe(SyncEvent.self) { event in
                        guard event.documentId == syncDocId, event.synced else { return }
                        if wait.claim() { cont.resume() }
                    })

                    // Retry tick — mirrors js-bao's `waitForAvailability`
                    // (350ms `setInterval` → re-`sendSyncStep1`). A freshly
                    // `documents.create`'d doc is `pendingCreate` (committed to
                    // the server in the background), so the initial `syncStep1`
                    // above reaches the server before the doc exists there — no
                    // `syncComplete` comes back. Re-send `syncStep1` every 350ms
                    // until the background commit lands and the server can
                    // answer (or the timeout below fires). Without this, a
                    // `.network` open of a just-created doc always burned the
                    // full `availabilityWaitMs` (~30s) regardless of how fast
                    // the commit actually completed.
                    Task { [weak self] in
                        while !wait.isSettled {
                            try? await Task.sleep(nanoseconds: 350 * 1_000_000)
                            if wait.isSettled { break }
                            guard let self else { break }
                            if self.networkingAllowed() {
                                await self.startNetworkSync(documentId: syncDocId, explicit: false)
                            }
                        }
                    }

                    // Bound the wait by `availabilityWait` (JS parity):
                    // resolve with whatever local state exists once the
                    // network-availability budget is exhausted. A value of
                    // 0 means "don't wait for the network" — resolve at once.
                    let wait_ = options.availabilityWait
                    wait.set(timeoutTask: Task {
                        try? await Task.sleep(nanoseconds: UInt64(max(0, wait_) * 1_000_000_000))
                        if wait.claim() { cont.resume() }
                    })
                }
            }
        }

        return doc
    }

    /// Close a document
    public func closeDocument(_ documentId: String, options: CloseDocumentOptions = CloseDocumentOptions()) async {
        lock.withLock {
            subscribedDocuments.remove(documentId)
            outboundDebounceTimers[documentId]?.cancel()
            outboundDebounceTimers.removeValue(forKey: documentId)
            pendingUpdates.removeValue(forKey: documentId)
            // Drop the flush-ownership entry with the queue it guards (#2105).
            // A retained entry would silently stop every future flush for this
            // document if it were reopened. An owner still mid-send has had its
            // token revoked, so it exits without touching the (possibly
            // reopened) document's state when its send returns.
            outboundFlushOwner.removeValue(forKey: documentId)
            // Nothing is left to re-flush for a closed document, and a stale bit
            // would make the first flush after a reopen take a pointless extra
            // drain pass.
            outboundReflushRequested.remove(documentId)
        }

        // Drop this document's flag-decision watermark alongside its queue state
        // so the map doesn't grow one entry per document for the client's
        // lifetime. Guarded by its own lock, so it can't go in the block above.
        // A decision still in flight may re-add the entry; that's harmless — the
        // sequence is global and monotonic, so no later decision is ever dropped.
        unsyncedFlagApplyLock.withLock {
            _ = unsyncedFlagAppliedSeq.removeValue(forKey: documentId)
        }

        // Drop this doc's rows from every cross-document store before the
        // YDocument is torn down, so later `Model.query()` reads don't
        // surface stale state.
        disconnectFromSharedModels(documentId: documentId)

        await documentManager.closeDocument(documentId: documentId, options: options)
    }

    /// Create a new document
    /// Create a document. Local-first by default — mirrors js-bao's
    /// `DocumentManager.createDocument` flow (#852). The created
    /// `YDocument` is immediately writable (fetch it via
    /// `getDoc(documentId)`); when `options.localOnly` is false (the
    /// default), a server commit is scheduled in the background and the
    /// `pendingCreate` metadata flag is cleared on success. On failure
    /// the `pendingCreateFailed` event fires and the metadata's
    /// `commitError` carries the reason.
    ///
    /// Returns `{ metadata }` — the freshly-written local metadata for
    /// the new document — matching js-bao's
    /// `createDocument(options): Promise<{ metadata }>` exactly (#1108).
    /// The document id rides inside `metadata.documentId`. Before #1108
    /// this returned a Swift-only `(documentId, doc)` tuple.
    @discardableResult
    public func createDocument(options: CreateDocumentOptions = CreateDocumentOptions()) async throws -> CreateDocumentResult {
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
        if !options.localOnly && networkingAllowed() {
            documentManager.scheduleCommitRetry(documentId: documentId)
        }

        // Return the freshly-written local metadata as `{ metadata }`,
        // matching js-bao's return shape (#1108). The open doc stays
        // reachable via `getDoc(documentId)`, exactly like JS.
        let entry = documentManager.getLocalMetadata(documentId)
        let metadataValue = try entry.map { entry -> JSONValue in
            let any = try JSONCoding.jsonObject(from: entry)
            return try JSONCoding.decode(JSONValue.self, from: any)
        }
        return CreateDocumentResult(metadata: metadataValue)
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
    ///
    /// Throws `JsBaoError(code: .notFound)` if the document isn't open — a
    /// recoverable, caller-inducible condition (e.g. a lifecycle race between
    /// close/evict and a write). This mirrors the JS client, whose write path
    /// (`runLocalTransaction`) throws rather than crashing; before #1984 this
    /// method called `fatalError`, taking the host app down.
    public func transactAndSync<T>(_ documentId: String, _ changes: @escaping (YrsTransaction) -> T) throws -> T {
        guard let doc = documentManager.getDocument(documentId) else {
            throw JsBaoError(
                code: .notFound,
                message: "Document `\(documentId)` is not open"
            )
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
    ///
    /// Throws `JsBaoError(code: .notFound)` if the document isn't open — see
    /// `transactAndSync` for the rationale (JS-parity, no more `fatalError`; #1984).
    @discardableResult
    public func transactAndSyncAsync<T: Sendable>(_ documentId: String, _ changes: @escaping @Sendable (YrsTransaction) -> T) async throws -> T {
        guard let doc = documentManager.getDocument(documentId) else {
            throw JsBaoError(
                code: .notFound,
                message: "Document `\(documentId)` is not open"
            )
        }

        // `YDocument` isn't `Sendable`, but every access below runs under
        // the doc's exclusive FFI lock (`withExclusiveAccess`), which
        // serializes it against observer registration on other threads
        // (#1126) — a guarantee the compiler can't see. Alias it as
        // `nonisolated(unsafe)` so the cross-thread capture into the
        // `DispatchQueue.global` closure is allowed while keeping the lock
        // discipline that actually makes it safe.
        nonisolated(unsafe) let unsafeDoc = doc
        let result: (T, [UInt8]) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Use raw YrsDoc to bypass syncQueue entirely. Raw access
                // still must hold the doc's FFI lock — an observer
                // registration (model connect, doc open) on another thread
                // while one of these transactions is live panics in yrs and
                // aborts the process (#1126).
                let payload: (T, [UInt8]) = unsafeDoc.withExclusiveAccess {
                    let rawDoc = unsafeDoc.document

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

                    return (result, update)
                }

                continuation.resume(returning: payload)
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
    /// js-bao's `rootDocId: string | null` — a pure synchronous
    /// cached read of `payload.user.rootDocId || payload.rootDocId`,
    /// with the offline identity as a final fallback (exactly the JS
    /// `authController.getRootDocId()` lookup). No HTTP call — the
    /// value is available immediately after sign-in in any auth flow
    /// (OTP / OAuth / magic link / offline grant). The pre-#1109
    /// `async throws` + `refresh:` surface is gone: there is nothing
    /// to refetch.
    public var rootDocId: String? {
        if let root = rootDocIdFromJwt() { return root }
        return authController.getOfflineIdentity()?.rootDocId
    }

    /// Build the alias-resolve request path, percent-encoding the alias as a
    /// single path segment through the shared escaper (#2076) so a `/` (or any
    /// reserved character) in the alias can't split it into extra path
    /// segments. `internal` for unit testing.
    static func aliasResolvePath(alias: String) -> String {
        "/document-aliases/\(URLEncoding.encodeComponent(alias))/resolve"
    }

    /// Open a document by URL alias. Resolves the alias to a
    /// documentId via the server, then opens it via the standard
    /// `openDocument` path. Mirrors js-bao's
    /// `client.openDocumentByAlias(alias)`.
    public func openDocumentByAlias(
        _ alias: String,
        options: OpenDocumentOptions = OpenDocumentOptions()
    ) async throws -> YDocument {
        // `documentId` is optional in the response type so that a 2xx body
        // without it still surfaces as `aliasNotFound` (what the old
        // dictionary cast did) rather than a decoding error.
        struct AliasResolution: Decodable, Sendable { let documentId: String? }
        let result: AliasResolution? = try await httpClient.requestOptional(
            method: .get, path: Self.aliasResolvePath(alias: alias)
        )
        guard let documentId = result?.documentId else {
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
        // A caller asking for sync explicitly hands the timing back to the
        // client: a document opened with `deferNetworkSync` becomes
        // `immediate` from here on, so its post-commit re-sync runs like any
        // other document's. JS `startNetworkSync` sets the same mode on the
        // same path. Client-driven callers below pass `explicit: false` —
        // re-subscribing after a reconnect must not silently retag a document
        // whose sync the caller still owns.
        await startNetworkSync(documentId: documentId, explicit: true)
    }

    func startNetworkSync(documentId: String, explicit: Bool) async {
        if explicit {
            documentManager.setStartNetworkMode(documentId, .immediate)
            // An explicit call is the caller taking over the timing, so it
            // outranks a cycle the client itself started: release any
            // outstanding claim before taking one below. JS does the same —
            // `requestManualSync`'s `triggerSync` deletes the
            // `pendingSyncOperations` entry immediately before sending
            // (`documentManager.ts:2083`). Without this, a claim the client
            // took (a connect sweep, or a syncStep1 whose answer was lost)
            // silently swallows the caller's request for up to the 10s
            // staleness window.
            documentManager.completePendingSyncOperation(documentId)
        }
        // One syncStep1->syncComplete cycle in flight per document (JS
        // parity: `sendSyncStep1` skips while `hasPendingSyncOperation`).
        // Without this, the 350ms availability-retry loop floods the
        // document DO with duplicate syncStep1 frames that starve the
        // in-flight sync cycle (#2584). The claim is released by
        // syncComplete, transport close, document close, a failed send
        // below - or by aging out (the `staleAfter` watchdog stand-in).
        guard documentManager.beginPendingSyncOperation(documentId) else {
            logger.debug("startNetworkSync: sync already in progress for", documentId)
            return
        }
        guard let message = documentManager.buildSyncStep1Message(documentId: documentId) else {
            documentManager.completePendingSyncOperation(documentId)
            return
        }

        lock.withLock {
            _ = subscribedDocuments.insert(documentId)
        }

        do {
            try await wsManager.send(message)
        } catch {
            logger.warn("Failed to send syncStep1 for", documentId, error.localizedDescription)
            // No frame went out, so no syncComplete will release the claim.
            documentManager.completePendingSyncOperation(documentId)
        }
    }

    // MARK: - Awareness

    /// Set awareness state for a document (e.g. cursor position, selection, user info).
    ///
    /// Broadcasts the state to the server keyed by this client's
    /// `connectionId` (the wire key remote peers store the local state
    /// under — JS `sendAwarenessState` does the same) and emits a local
    /// `.awareness` delta event (`added` on the first set, `updated`
    /// after), mirroring JS `setLocalAwarenessState` (#996).
    public func setAwareness(_ documentId: String, state: [String: JSONValue]) {
        let result = documentManager.setLocalAwarenessState(documentId, state: state)
        guard result.exists else { return }

        // Wire format is `[clientId, state]` tuples, keyed by connectionId.
        // (Previously Swift sent a bare `[state]`, which JS peers could not
        // destructure — #996.)
        let localKey = connectionId
        // `state` is the typed `[String: JSONValue]` shape (#2367); lower it
        // back to the `Any` graph `JSONSerialization` needs to encode the frame.
        // This method cannot throw, and encoding only fails on a value
        // `JSONEncoder` rejects (a non-finite `.number`) — but publishing an
        // empty state to every peer is a visible behavior change, not a no-op,
        // so it is logged rather than swallowed.
        var stateAny: [String: Any] = [:]
        do {
            stateAny = try JSONCoding.jsonObject(from: state) as? [String: Any] ?? [:]
        } catch {
            logger.warn(
                "[awareness] setAwareness(\(documentId)) state could not be encoded (\(error)); "
                    + "publishing an empty state to peers"
            )
        }
        let message: [String: Any] = [
            "type": "awareness",
            "documentId": documentId,
            "states": [[localKey, stateAny]],
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: message),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            Task {
                try? await wsManager.send(jsonString)
            }
        }

        eventEmitter.emit(AwarenessEvent(
            documentId: documentId,
            added: result.previousState == nil ? [localKey] : [],
            updated: result.previousState != nil ? [localKey] : [],
            removed: []
        ))
    }

    /// Remove awareness states for specific clients.
    ///
    /// Broadcasts `[clientId, null]` removal tuples to the server and emits
    /// a local `.awareness` delta event with the requested IDs in
    /// `removed`, mirroring JS `removeAwarenessStates` (#996).
    public func removeAwareness(documentId: String, clientIds: [String]) {
        // Clearing our own wire key also clears the local state (JS parity).
        let removeLocal = clientIds.contains(connectionId)
        documentManager.removeAwarenessClients(
            documentId,
            clientIds: clientIds,
            removeLocal: removeLocal
        )

        // Send removal as [clientId, null] tuples
        let states: [[Any]] = clientIds.map { [$0, NSNull()] }
        let message: [String: Any] = [
            "type": "awareness",
            "documentId": documentId,
            "states": states,
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: message),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            Task {
                try? await wsManager.send(jsonString)
            }
        }

        // JS emits the full requested list in `removed` (not just the IDs
        // that were actually present) — mirror that.
        eventEmitter.emit(AwarenessEvent(
            documentId: documentId,
            added: [],
            updated: [],
            removed: clientIds
        ))
    }

    /// Get all awareness states for a document (local + remote).
    /// Returns a dictionary keyed by client ID.
    public func getAwarenessStates(documentId: String) -> [String: [String: JSONValue]] {
        guard let snapshot = documentManager.getAwarenessSnapshot(documentId) else { return [:] }
        var states = snapshot.remoteStates
        if let localState = snapshot.localState {
            states[connectionId] = localState
        }
        return states
    }

    // MARK: - HTTP API (typed escape hatches)

    /// Call an endpoint the client does not wrap, decoding the response into
    /// your own `Decodable` type.
    ///
    /// Same authentication, token refresh, 401 retry, and error mapping the
    /// wrapped endpoints get, with the response decoded into a real Swift type.
    ///
    /// ```swift
    /// struct Health: Decodable { let ok: Bool }
    /// let health: Health = try await client.request(method: .get, path: "/health")
    /// ```
    ///
    /// Throws `HttpError` on a non-2xx status (with the server's `code` /
    /// `message` extracted), and on a 2xx response whose body is empty or
    /// does not decode as `Response`. Use ``requestJSON(method:path:body:options:)``
    /// when the shape is genuinely dynamic, and
    /// ``requestData(method:path:body:options:)`` for bytes.
    public func request<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: Body,
        options: RequestOptions? = nil
    ) async throws -> Response {
        try await httpClient.request(method: method, path: path, body: body, options: options)
    }

    /// No request body. (A `Body?` of `nil` cannot infer `Body`, so the
    /// no-body form is its own overload — same as on `Transport`.)
    public func request<Response: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        options: RequestOptions? = nil
    ) async throws -> Response {
        try await httpClient.request(method: method, path: path, options: options)
    }

    /// Call an endpoint whose response shape you do not want to model, and
    /// get a `JSONValue` back rather than an `Any` graph.
    ///
    /// Use this when the response really is dynamic: `JSONValue` carries the
    /// same information an `Any` graph would but is `Codable`,
    /// `Sendable`, and `Equatable`, so it crosses concurrency boundaries and
    /// re-encodes losslessly. Returns `nil` for a 2xx response with an empty
    /// body or a JSON `null`; a malformed body throws.
    ///
    /// ```swift
    /// let me = try await client.requestJSON(method: .get, path: "/me")
    /// let userId = me?["userId"]?.stringValue
    /// ```
    ///
    /// Note the number rule described on ``JSONValue``: every JSON number
    /// decodes as `Double`, so integers beyond 2^53 lose precision. Model
    /// those fields with a typed struct and ``request(method:path:options:)``.
    public func requestJSON<Body: Encodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: Body,
        options: RequestOptions? = nil
    ) async throws -> JSONValue? {
        try await httpClient.requestOptional(method: method, path: path, body: body, options: options)
    }

    /// No request body.
    public func requestJSON(
        method: HTTPMethod,
        path: String,
        options: RequestOptions? = nil
    ) async throws -> JSONValue? {
        try await httpClient.requestOptional(method: method, path: path, options: options)
    }

    /// Send and receive raw bytes — file uploads and downloads.
    ///
    /// Returns the response bytes **untouched** with the status, and does not throw on a non-2xx
    /// status (inspect the returned status). Takes `RequestOptions`, so a
    /// timeout and custom headers are both available.
    public func requestData(
        method: HTTPMethod,
        path: String,
        body: Data? = nil,
        options: RequestOptions? = nil
    ) async throws -> (Data, Int) {
        try await httpClient.requestData(method: method, path: path, body: body, options: options)
    }

    // MARK: - HTTP API (deprecated `Any` surface)

    /// The last untyped hop inside `JsBaoClient` itself.
    ///
    /// A few call sites still need the loosely-typed JSON graph because the
    /// surface *they* feed is untyped — `DocumentManager.handleServerDocuments`
    /// / `createRemoteDocument` exchange `[String: Any]` documents. They read
    /// the graph through this one private hop rather than a public untyped
    /// entry point, which #2367 removed.
    private func legacyJSONGraph(_ method: String, _ path: String, _ data: Any? = nil) async throws -> Any? {
        try await httpClient.request(method: method, path: path, data: data)
    }

    // MARK: - Configuration

    /// The API base URL this client was configured with.
    public var apiUrl: String { options.apiUrl }

    /// The app id this client was configured with.
    public var appId: String { options.appId }

    /// The global-admin app id this client was configured with.
    public var globalAdminAppId: String { options.globalAdminAppId }

    /// Set log level
    public func setLogLevel(_ level: LogLevel) {
        logger.setLevel(level)
    }

    // `BlobManager` is an actor (#2172), so reading and writing its upload
    // concurrency are both effectful. The read is an `async` property rather
    // than a synchronous one: a synchronous snapshot would answer from a
    // stale image.

    /// Set blob upload concurrency, returning once the setting is in effect.
    public func setBlobUploadConcurrencyAsync(_ value: Int) async {
        await blobManager.setUploadConcurrency(value)
    }

    /// The app-wide maximum number of concurrent blob uploads.
    public var blobUploadConcurrency: Int {
        get async { await blobManager.getUploadConcurrency() }
    }

    // MARK: - Offline Data

    /// Evict all local data
    public func evictAllLocal(force: Bool = false) async {
        await documentManager.evictAllLocalData()
        await kvCache.clearAll()
        await blobManager.clearCache()
    }

    /// Get offline info for a document
    public func getOfflineInfo(_ documentId: String) -> [String: Any] {
        return [
            "hasLocalCopy": hasLocalCopy(documentId),
            "isSynced": isSynced(documentId),
        ]
    }

    /// Build the `syncMetadata` request path, routing both query values
    /// through the shared `URLQuery` builder (#2076). `payloadType` was
    /// previously appended unescaped. `internal` for unit testing.
    static func syncMetadataPath(documentId: String?, payloadType: String?) -> String {
        var query = URLQuery()
        query.appendIfPresent("documentId", documentId)
        query.appendIfPresent("payloadType", payloadType)
        return "/documents\(query.queryString)"
    }

    /// Sync metadata. With no options, refreshes the full doc list.
    /// `options.documentId` restricts to one doc;
    /// `options.payloadType` (`"ids"` | `"full"`) controls the wire
    /// shape; `options.background` runs without blocking. Matches
    /// js-bao's `syncMetadata(opts)` shape.
    public func syncMetadata(
        options: SyncMetadataOptions = SyncMetadataOptions()
    ) async throws {
        let path = Self.syncMetadataPath(
            documentId: options.documentId,
            payloadType: options.payloadType
        )

        if options.background == true {
            // Fire-and-forget; caller wants the sync to run but doesn't
            // want to await its completion.
            Task { [weak self] in
                guard let self = self else { return }
                if let result = try? await self.legacyJSONGraph("GET", path, nil),
                   let docs = result as? [[String: Any]] {
                    await self.documentManager.handleServerDocuments(docs)
                }
            }
            return
        }
        let result = try await legacyJSONGraph("GET", path, nil)
        guard let docs = result as? [[String: Any]] else { return }
        await documentManager.handleServerDocuments(docs)
    }

    // MARK: - Analytics

    // The analytics queue became an `actor` in #1993 Phase D3, so its work is
    // `async`. Each member below keeps its synchronous shape for one release —
    // a synchronous caller cannot add an `await`, so removing it outright would
    // be a break with no local fix — and gains an `Async` twin that does the
    // work on the caller's task. See `AnalyticsAPI` for why the twins carry a
    // distinct name instead of being same-name `async` overloads.

    /// Log an analytics event, returning once it is buffered.
    public func logAnalyticsEventAsync(_ event: [String: Any]) async {
        guard let prepared = analyticsQueue.prepared(event) else { return }
        await analyticsQueue.logEvent(prepared)
    }

    /// Flush pending analytics events, returning once the batch has reached the
    /// socket (or, on a send failure, once it has been re-buffered and
    /// persisted).
    public func flushAnalyticsAsync() async {
        await analyticsQueue.flushAndWait()
    }

    /// Override the plan field on all subsequent analytics events, returning
    /// once the override is in effect.
    public func setAnalyticsPlanOverrideAsync(_ plan: String?) async {
        await analyticsQueue.setPlanOverride(plan)
    }

    /// Override the app version field on all subsequent analytics events,
    /// returning once the override is in effect.
    public func setAnalyticsAppVersionOverrideAsync(_ version: String?) async {
        await analyticsQueue.setAppVersionOverride(version)
    }

    // MARK: - Analytics session lifecycle (#963)

    /// Log a `session_end` event carrying the session duration. Idempotent
    /// via `sessionEndLogged` so overlapping triggers (background
    /// notification + `destroy()`) only emit once. Mirrors js-bao's
    /// `logSessionEndEvent`.
    ///
    /// `async` since #1993 Phase D3 so the callers that must not lose the event
    /// — `destroy()` above all — can await it landing in the buffer before the
    /// final flush drains it.
    private func logSessionEndEvent(reason: String) async {
        guard options.analyticsAutoEvents.sessionEnd else { return }
        let start: Date? = lock.withLock {
            if sessionEndLogged { return nil }
            sessionEndLogged = true
            return sessionStartAt
        }
        guard let start else { return }

        let durationMs = max(0, Int(Date().timeIntervalSince(start) * 1000))
        await analyticsQueue.logEvent(
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
            // One task for both steps, so the `session_end` event is in the
            // buffer before the flush drains it.
            Task {
                await self.logSessionEndEvent(reason: "background")
                await self.analyticsQueue.flushAndWait()
            }
        }
        let terminate = center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.logSessionEndEvent(reason: "destroy")
                await self.analyticsQueue.flushAndWait()
            }
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
        lock.withLock {
            lifecycleObservers = [background, terminate, foreground]
        }
        #endif
    }

    /// Remove any registered lifecycle observers. Safe to call multiple
    /// times; clears the stored tokens.
    private func removeLifecycleObservers() {
        let observers = lock.withLock { () -> [NSObjectProtocol] in
            let current = lifecycleObservers
            lifecycleObservers = []
            return current
        }
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
            subs.append(eventEmitter.subscribe(AuthSuccessEvent.self) { [weak self] _ in
                self?.triggerDailyAuthAutoEvent()
            })
        }

        // syncErrors — a pending-create commit failed. js-bao calls
        // `maybeLogSyncErrorEvent(documentId, reason)` from its outbound-sync
        // failure paths; the Swift analog with a stable surface is the
        // `documentCreateCommitFailed` emitter event.
        if auto.syncErrorsEnabled {
            subs.append(eventEmitter.subscribe(DocumentCreateCommitFailedEvent.self) { [weak self] event in
                self?.maybeLogSyncErrorEvent(documentId: event.documentId, reason: event.reason ?? "commit_failed")
            })
        }

        // blobUploads — start/success/failure, each one-shot per upload.
        // js-bao gates on `blobUploads.{start,success,failure}` and dedupes
        // by queueId/blobId; Swift mirrors that via the blob emitter events.
        if auto.blobUploadsSuccess {
            subs.append(eventEmitter.subscribe(BlobUploadCompletedEvent.self) { [weak self] event in
                self?.handleBlobUploadComplete(event)
            })
        }
        if auto.blobUploadsFailure {
            subs.append(eventEmitter.subscribe(BlobUploadFailedEvent.self) { [weak self] event in
                self?.handleBlobUploadFailed(event)
            })
        }
        // NOTE: blobUploads.start has no faithful Swift surface yet — the
        // Swift BlobManager does not emit a "started/uploading" progress
        // event the way js-bao's queue does (`blobs:upload-progress` carries
        // download-only `bytesTransferred/totalBytes`, not an upload-start
        // signal). Left unwired; flagged in the report.

        lock.withLock {
            analyticsEventSubscriptions = subs
        }
    }

    private func removeAnalyticsAutoEventObservers() {
        let subs = lock.withLock { () -> [EventSubscription] in
            let current = analyticsEventSubscriptions
            analyticsEventSubscriptions = []
            return current
        }
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
        let alreadyHydrated = lock.withLock { () -> Bool in
            if analyticsMetadataHydrated && analyticsMetadataUserId == userId {
                return true
            }
            // User changed (or first hydrate) — clear and reload.
            if analyticsMetadataUserId != userId {
                lastDailyAuthDate = nil
                lastReturnActiveAt = nil
            }
            return false
        }
        guard !alreadyHydrated else { return }

        let record = try? await offlineStore.loadAnalyticsMetadata(appId: options.appId, userId: userId)
        lock.withLock {
            lastDailyAuthDate = record?.lastDailyAuthDate
            if let raw = record?.lastReturnActiveAt, let ms = Double(raw) {
                lastReturnActiveAt = Date(timeIntervalSince1970: ms / 1000.0)
            } else {
                lastReturnActiveAt = nil
            }
            analyticsMetadataHydrated = true
            analyticsMetadataUserId = userId
        }
    }

    /// Persist the in-memory analytics-metadata mirror. Mirrors js-bao's
    /// `persistAnalyticsMetadata` — writes `nil` (delete) when empty.
    private func persistAnalyticsMetadata(userId: String) async {
        let (date, returnAt) = lock.withLock { (lastDailyAuthDate, lastReturnActiveAt) }

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
            let alreadyLogged = self.lock.withLock { () -> Bool in
                if self.lastDailyAuthDate == today { return true }
                self.lastDailyAuthDate = today
                self.analyticsMetadataHydrated = true
                self.analyticsMetadataUserId = userId
                return false
            }
            guard !alreadyLogged else { return }

            await self.analyticsQueue.logEvent(
                AnalyticsEventInput(action: "user_active_daily", feature: "session")
            )
            await self.persistAnalyticsMetadata(userId: userId)
        }
    }

    /// returnActive: emit `user_returned` (feature `session`) when the app
    /// foregrounds after at least `minResume` of inactivity. Mirrors
    /// js-bao's `triggerReturnActiveEvent`.
    private func triggerReturnActiveEvent(trigger: String) {
        guard options.analyticsAutoEvents.returnActive else { return }
        guard let userId = resolveAnalyticsUserUlid() else { return }
        let minResumeMs = options.analyticsAutoEvents.minResume.wholeMilliseconds
        Task { [weak self] in
            guard let self else { return }
            await self.ensureAnalyticsMetadataHydrated(userId: userId)
            let now = Date()
            let withinCooldown = self.lock.withLock { () -> Bool in
                if let last = self.lastReturnActiveAt {
                    let elapsedMs = now.timeIntervalSince(last) * 1000
                    if elapsedMs < Double(minResumeMs) {
                        return true
                    }
                }
                self.lastReturnActiveAt = now
                self.analyticsMetadataHydrated = true
                self.analyticsMetadataUserId = userId
                return false
            }
            guard !withinCooldown else { return }

            await self.analyticsQueue.logEvent(
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
    /// event per `syncErrorsMinInterval`. Mirrors js-bao's
    /// `maybeLogSyncErrorEvent`.
    private func maybeLogSyncErrorEvent(documentId: String, reason: String) {
        guard options.analyticsAutoEvents.syncErrorsEnabled else { return }
        let minIntervalMs = options.analyticsAutoEvents.syncErrorsMinInterval.wholeMilliseconds
        let now = Date()
        let withinCooldown = lock.withLock { () -> Bool in
            if let last = lastSyncErrorEventAt {
                let elapsedMs = now.timeIntervalSince(last) * 1000
                if elapsedMs < Double(minIntervalMs) {
                    return true
                }
            }
            lastSyncErrorEventAt = now
            return false
        }
        guard !withinCooldown else { return }

        let logged = AnalyticsEventInput(
            action: "sync_error",
            feature: "sync",
            context_json: .object([
                "documentId": .string(documentId),
                "reason": .string(reason),
            ])
        )
        let queue = analyticsQueue
        Task { await queue.logEvent(logged) }
    }

    /// blobUploads.success: emit `blob_upload_succeeded` (feature `blobs`)
    /// once per upload. Mirrors js-bao's `handleBlobUploadComplete`.
    private func handleBlobUploadComplete(_ event: BlobUploadCompletedEvent) {
        guard options.analyticsAutoEvents.blobUploadsSuccess else { return }
        let key = event.blobId
        let alreadyLogged = lock.withLock { () -> Bool in
            if key.isEmpty || blobUploadSuccessLogged.contains(key) { return true }
            blobUploadSuccessLogged.insert(key)
            return false
        }
        guard !alreadyLogged else { return }

        let logged = AnalyticsEventInput(
            action: "blob_upload_succeeded",
            feature: "blobs",
            context_json: .object([
                "documentId": .string(event.documentId),
                "blobId": .string(event.blobId),
                "numBytes": .number(Double(event.numBytes)),
            ])
        )
        let queue = analyticsQueue
        Task { await queue.logEvent(logged) }
    }

    /// blobUploads.failure: emit `blob_upload_failed` (feature `blobs`) once
    /// per upload. Mirrors js-bao's `handleBlobUploadFailed`.
    private func handleBlobUploadFailed(_ event: BlobUploadFailedEvent) {
        guard options.analyticsAutoEvents.blobUploadsFailure else { return }
        let key = event.blobId
        let alreadyLogged = lock.withLock { () -> Bool in
            if key.isEmpty || blobUploadFailureLogged.contains(key) { return true }
            blobUploadFailureLogged.insert(key)
            return false
        }
        guard !alreadyLogged else { return }

        let logged = AnalyticsEventInput(
            action: "blob_upload_failed",
            feature: "blobs",
            context_json: .object([
                "documentId": .string(event.documentId),
                "blobId": .string(event.blobId),
                "willRetry": .bool(event.willRetry),
                "lastError": .string(String((event.lastError ?? "").prefix(256))),
            ])
        )
        let queue = analyticsQueue
        Task { await queue.logEvent(logged) }
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

    // MARK: - Document Context

    /// Get a scoped document context
    public func document(_ documentId: String) -> DocumentContext {
        DocumentContext(
            documentId: documentId,
            client: self,
            blobManager: blobManager,
            transport: httpClient
        )
    }

    // MARK: - Lifecycle

    /// Destroy the client and clean up resources
    public func destroy() async {
        let alreadyDestroyed = lock.withLock { () -> Bool in
            if isDestroyed { return true }
            isDestroyed = true
            outboundDebounceTimers.values.forEach { $0.cancel() }
            outboundDebounceTimers.removeAll()
            // Release every flush-ownership entry (#2105) so teardown can't
            // leave a document wedged for a client that outlives it. Running
            // flushes see their token revoked and exit on their next check.
            outboundFlushOwner.removeAll()
            outboundReflushRequested.removeAll()
            // Cancel any pending reachability apply so no reaction fires after
            // teardown (an already-enqueued one no-ops via the isDestroyed
            // guard in applyReachability).
            reachabilityDebounce?.cancel()
            reachabilityDebounce = nil
            return false
        }
        guard !alreadyDestroyed else { return }

        // Idempotent; the monitor's own deinit also cancels as a safety net.
        connectivityMonitor?.cancel()
        // Cancel a pending refresh-retry (#2022) first, so no background
        // refresh starts while the rest of the teardown runs.
        authController.destroy()
        await disconnect()
        await documentManager.destroy()
        // Stop listening for app-lifecycle notifications and emit a final
        // `session_end` before the queue drains (#963). The event lands in
        // the buffer that `analyticsQueue.destroy()` flushes below.
        removeLifecycleObservers()
        removeAnalyticsAutoEventObservers()
        await logSessionEndEvent(reason: "destroy")
        // Cancel the periodic flush timer and trigger a final flush
        // before closing storage. The flush is async (fires a Task),
        // so we then await any pending persistence to drain — without
        // this, the SQLite close races the in-flight write and a
        // subsequent client opening the same DB hits SQLITE_BUSY.
        await analyticsQueue.destroy()
        await analyticsQueue.awaitPendingPersistence()
        // JWT persistence (AuthController.applyToken) also runs in a
        // detached Task — wait for any outstanding write before the
        // storage layer pulls the connection out from under it.
        await authController.awaitPendingPersistence()
        await offlineStore.closeStorage()
        eventEmitter.removeAll()
        // End every open `stream(for:)` so a `for await` loop exits instead of
        // waiting on a client that is gone.
        eventEmitter.finishAllStreams()
    }

    // MARK: - Private Setup

    private func setupDependencies() {
        // Wire the auth controller's typed transport (one-shot).
        authController.setTransport(httpClient)

        // Note: HTTP client's getConnectionId is set via config closure at init time

        // Wire document manager dependencies
        documentManager.offlineStore = offlineStore
        documentManager.appId = options.appId
        documentManager.emitter = eventEmitter
        documentManager.sendWebSocketMessage = { [weak self] message in
            try await self?.wsManager.send(message)
        }
        documentManager.createRemoteDocument = { [weak self] body in
            guard let self = self else { throw JsBaoError(code: .unavailable) }
            let result = try await self.legacyJSONGraph("POST", "/documents", body)
            return result as? [String: Any] ?? [:]
        }
        // Wire up document update observer — fires for ALL local writes to any open doc.
        // This is the equivalent of JS `doc.on("update", handler)`.
        documentManager.onLocalUpdate = { [weak self] documentId, update in
            self?.queueOutboundUpdate(documentId: documentId, update: update)
        }
        // A `pendingCreate` doc doesn't exist server-side yet, so the
        // syncStep1 sent at open time never gets a `syncComplete` back and its
        // in-flight claim would refuse every retry until it aged out. The
        // commit is the moment the server can answer: re-send then, exactly as
        // js-bao's `applyPostCommitPolicy` does (#2587, keeping #852's
        // availability-retry loop effective).
        // Only fires for documents whose sync this client drives — the
        // `deferNetworkSync` / `enableNetworkSync: false` opens are filtered
        // out by `DocumentManager.applyPostCommitPolicy`.
        documentManager.onPendingCreateCommitted = { [weak self] documentId in
            Task { [weak self] in
                guard let self, self.networkingAllowed() else { return }
                await self.startNetworkSync(documentId: documentId, explicit: false)
            }
        }
        documentManager.commitRetryBackoff = options.commitRetryBackoff
        documentManager.isOnlineProvider = { [weak self] in self?.networkingAllowed() ?? false }

        // (The blob manager and the analytics queue are wired in `init` — both
        // are actors, so their collaborators are supplied at construction,
        // #2172 and #1993 Phase D3.)

        // Wire WebSocket manager delegate
        wsManager.delegate = self
    }

    /// Builds the six sub-APIs that cannot be `let`s.
    ///
    /// Each one either takes `self` directly (`codegen`) or has closures that
    /// reach client-level logic with no collaborator behind it —
    /// `networkMode`, `networkingAllowed()`,
    /// `rootDocId`, `logout(...)` — so they can only be built once
    /// `self` is usable. They are assigned to private implicitly-unwrapped
    /// storage read through non-optional public properties (#2367).
    private func setupSubApis() {
        self._codegen = CodegenAPI(client: self)

        let cacheFacade = CacheFacade(
            kvCache: kvCache,
            getNetworkMode: { [weak self] in self?.networkMode ?? .auto },
            transport: httpClient
        )
        self._cache = cacheFacade

        self._documents = DocumentsAPI(
            transport: httpClient,
            blobManager: blobManager,
            documentManager: documentManager,
            client: self
        )
        // Avatar upload sends raw bytes with a custom Content-Type; it goes
        // through `Transport.requestData` like every other raw-bytes call
        // site now that `MeAPI` holds the transport.
        self._me = MeAPI(
            transport: httpClient,
            cache: cacheFacade,
            localMetadata: { [weak self] in self?.documentManager.getMetadataIndex() ?? [:] },
            isOnline: { [weak self] in self?.networkingAllowed() ?? false },
            // Background refresh behind a local-first `ownedDocuments` writes
            // the server rows into the same local metadata cache the
            // local-first path reads, so the next call is fresh (#2360).
            syncServerDocuments: { [weak self] docs in
                guard let self = self else { return }
                await self.documentManager.handleServerDocuments(
                    docs.map { LocalFirstListing.serverDocumentPayload($0) }
                )
            },
            // Lets the local-first paths apply the same root filter the
            // server applies to `/me/owned-documents` (#848 / #2360).
            rootDocId: { [weak self] in self?.rootDocId },
            logger: logger
        )
        self._users = UsersAPI(transport: httpClient, cache: cacheFacade)
        self._auth = AuthAPI(
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
            otpVerifyWithInvite: { [weak self] email, code, inviteToken in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.authController.otpVerify(email: email, code: code, inviteToken: inviteToken)
            },
            getAuthConfig: { [httpClient] in
                try await httpClient.request(method: .get, path: "/oauth-config")
            },
            getAppConfig: { [httpClient] in
                try await httpClient.request(method: .get, path: "/oauth-config")
            },
            logout: { [weak self] wipeLocal in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                try await self.logout(wipeLocal: wipeLocal)
            },
            logoutWithOptions: { [weak self] options in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                try await self.logout(options: options)
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
            },
            passkeyAuthStart: { [weak self] in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.authController.passkeyAuthStart()
            },
            passkeyAuthFinish: { [weak self] credential, challengeToken in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.authController.passkeyAuthFinish(
                    credential: credential, challengeToken: challengeToken
                )
            },
            passkeyRegisterStart: { [weak self] in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.authController.passkeyRegisterStart()
            },
            passkeyRegisterFinish: { [weak self] credential, challengeToken, deviceName, inviteToken in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.authController.passkeyRegisterFinish(
                    credential: credential,
                    challengeToken: challengeToken,
                    deviceName: deviceName,
                    inviteToken: inviteToken
                )
            },
            passkeyList: { [weak self] in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.authController.passkeyList()
            },
            passkeyDelete: { [weak self] passkeyId in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.authController.passkeyDelete(passkeyId: passkeyId)
            },
            passkeyUpdate: { [weak self] passkeyId, deviceName in
                guard let self = self else { throw JsBaoError(code: .unavailable) }
                return try await self.authController.passkeyUpdate(
                    passkeyId: passkeyId, deviceName: deviceName
                )
            }
        )
        // logout(waitForDisconnect:) tears down networking via this hook.
        authController.onLogoutDisconnect = { [weak self] in await self?.disconnect() }
        // The refresh-retry backoff hitting its cap gives up on reconnecting
        // and takes the whole client offline (#2022), the same way the JS
        // client's auth controller calls `deps.setNetworkMode("offline")`.
        authController.setClientNetworkMode = { [weak self] mode in
            self?.setNetworkMode(mode)
        }
    }

    private func setupStorage() {
        Task {
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
                // `SQLiteStorageProvider.init(path:)` only stores the path;
                // the connection binds lazily at `initialize()` first-use
                // time, which is where an open failure surfaces. Nothing
                // here throws, so there is no error path to catch.
                let sqlite = SQLiteStorageProvider(path: resolvedPath)
                provider = sqlite
                authProvider = sqlite
            case .memory:
                provider = MemoryStorageProvider()
                authProvider = MemoryStorageProvider()
            }

            await offlineStore.setStorageProvider(provider)
            await offlineStore.setAuthStorageProvider(authProvider)
            await kvCache.setStorageProvider(provider)

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

            // Snapshot the restored user into the user-scoped managers and
            // load that user's local metadata.
            await bindCurrentUserScopedStorage()

            // Restore analytics queue
            await analyticsQueue.restoreBuffer()

            // Storage init is fully settled — token restored (or none) and
            // the user-scoped state (documentManager.userId + metadata)
            // snapshotted. Signal now, BEFORE the optional network
            // auto-connect, so waiters unblock on local readiness without
            // waiting on the network (#1780).
            markStorageReady()

            // Start connectivity monitoring (Phase 2) and await the initial
            // reachability snapshot BEFORE the auto-connect gate, so a down
            // path at startup means no auto-connect.
            if options.autoNetwork {
                startConnectivityMonitor()
                await awaitInitialReachability(timeoutMs: 1500)
            }

            // Auto-connect if networking is allowed.
            if options.autoNetwork && networkingAllowed() {
                try? await connect()
            }
        }
    }

    /// Snapshot the current auth user into the user-scoped managers and load
    /// that user's local metadata. Shared by `setupStorage()` (initial bind)
    /// and `rebindUserScopedStorage()` (post-sign-in rebind, #1780).
    private func bindCurrentUserScopedStorage() async {
        await kvCache.setUserId(authController.getUserId())
        if let userId = authController.getUserId() {
            documentManager.userId = userId
            try? await offlineStore.ensureMetadataDb(appId: options.appId, userId: userId)
            await documentManager.loadLocalMetadata()
        }
    }

    /// Re-scope the user-owned managers to the currently authenticated user,
    /// clearing the previously-bound user's in-memory metadata first. A no-op
    /// when the user is unchanged.
    ///
    /// `setupStorage()` binds document/metadata storage to whoever init
    /// restored. A later sign-in (`otpVerify`) updates only `AuthController`,
    /// so without this the client would keep serving the restored user's local
    /// document state under the new identity — the returned client would
    /// authenticate as B while retaining A's local documents (#1780). Call
    /// after a sign-in that may land a different user than init restored, once
    /// `waitForStorageReady()` confirms the initial bind has finished.
    public func rebindUserScopedStorage() async {
        let newUserId = authController.getUserId() ?? ""
        if documentManager.userId == newUserId { return }
        await documentManager.resetInMemoryUserState(userId: newUserId)
        await kvCache.setUserId(authController.getUserId())
        if !newUserId.isEmpty {
            try? await offlineStore.ensureMetadataDb(appId: options.appId, userId: newUserId)
            await documentManager.loadLocalMetadata()
        }
    }

    /// Wait until storage initialization has fully completed — token restored
    /// (or none), the user-scoped managers bound, and local metadata loaded —
    /// or until `timeout` elapses. Returns `true` if init completed within the
    /// bound, `false` on timeout.
    ///
    /// Unlike `waitForAuthReady`, this covers the whole `setupStorage()` task,
    /// not just token auth-ready (`markAuthReady()` fires mid-task, before the
    /// user-scoped bind). It is also genuinely bounded: the wait is
    /// cancellation-aware, so a slow or stuck startup refresh cannot stall the
    /// caller past `timeout` (#1780 codex P1/P2).
    @discardableResult
    public func waitForStorageReady(timeout: TimeInterval = 10) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.awaitStorageReady()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// Resume all parked waiters and latch the ready flag. Idempotent.
    private func markStorageReady() {
        let waiters: [CheckedContinuation<Void, Never>]? = storageReadyLock.withLock {
            if storageReady { return nil }
            storageReady = true
            let pending = Array(storageReadyWaiters.values)
            storageReadyWaiters.removeAll()
            return pending
        }
        guard let waiters else { return }
        for waiter in waiters { waiter.resume() }
    }

    /// Suspend until `setupStorage()` signals completion. Cancellation-aware:
    /// if the surrounding task is cancelled (e.g. the timeout child in
    /// `waitForStorageReady`), the parked continuation resumes promptly rather
    /// than stranding the caller until storage finishes.
    private func awaitStorageReady() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // `Task.isCancelled` closes the race where cancellation fires
                // before this continuation is parked: the `onCancel` handler
                // would find nothing to resume, so resume here instead.
                let resumeNow = storageReadyLock.withLock { () -> Bool in
                    if storageReady || Task.isCancelled { return true }
                    storageReadyWaiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = storageReadyLock.withLock { storageReadyWaiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }

    // MARK: - WebSocket Message Handling


    /// Download an oversized `syncStep2`/`update` payload the server parked in
    /// R2 (`{type, updateUrl}` instead of inline `update` — sent whenever the
    /// encoded diff exceeds `MAX_UPDATE_SIZE`). Mirrors the JS client's
    /// `handleUpdate` updateUrl branch. Returns nil on any failure; callers
    /// treat that like a dropped frame (a later syncStep1 retry or reconnect
    /// re-requests the state).
    private func downloadRemoteUpdate(from urlString: String, documentId: String) async -> Data? {
        guard let url = URL(string: urlString) else {
            logger.warn("Invalid updateUrl for doc:", documentId, urlString)
            return nil
        }
        do {
            let (data, response) = try await NetworkSession.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                logger.warn("Non-HTTP response downloading update for doc:", documentId)
                return nil
            }
            guard http.statusCode == 200 else {
                logger.warn("Failed to download update for doc:", documentId, "status:", http.statusCode)
                return nil
            }
            // The server stamps X-Compressed on /r2/ responses; it is
            // hardcoded "false" today (compressData is an identity
            // placeholder server-side), so compressed payloads are a
            // protocol we don't speak yet — fail loudly instead of
            // applying garbage bytes.
            if (http.value(forHTTPHeaderField: "X-Compressed") ?? "false") == "true" {
                logger.warn("Compressed update payloads are not supported; dropping update for doc:", documentId)
                return nil
            }
            logger.debug("Downloaded remote update for doc:", documentId, "bytes:", data.count)
            return data
        } catch {
            logger.warn("Failed to download update for doc:", documentId, error.localizedDescription)
            return nil
        }
    }

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
            guard let roomId = roomId else { return }
            if let update = json["update"] as? String {
                documentManager.handleRemoteUpdate(documentId: roomId, updateBase64: update)
            } else if let updateUrl = json["updateUrl"] as? String {
                // Payloads over the server's MAX_UPDATE_SIZE arrive as an R2
                // URL instead of an inline update (JS parity: handleUpdate's
                // updateUrl branch). Await the download here — the message
                // pump processes frames sequentially, so the trailing
                // syncComplete isn't handled until the full state is applied.
                if let data = await downloadRemoteUpdate(from: updateUrl, documentId: roomId) {
                    documentManager.handleRemoteUpdate(documentId: roomId, updateData: data)
                }
            } else {
                // JS parity: "No update and no updateUrl — nothing reached
                // the Y.Doc". Never drop this silently (#2474).
                logger.warn("syncStep2 carried neither update nor updateUrl for doc:", roomId)
            }

        case "syncComplete":
            guard let roomId = roomId else { return }
            documentManager.handleSyncComplete(documentId: roomId)
            reconcileUnsyncedAfterSync(documentId: roomId)

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
            guard let roomId = roomId else { return }
            if let update = json["update"] as? String {
                documentManager.handleRemoteUpdate(documentId: roomId, updateBase64: update)
            } else if let updateUrl = json["updateUrl"] as? String {
                // Large broadcast updates (a peer's >MAX_UPDATE_SIZE upload)
                // are relayed as an R2 URL, same as oversized syncStep2.
                if let data = await downloadRemoteUpdate(from: updateUrl, documentId: roomId) {
                    documentManager.handleRemoteUpdate(documentId: roomId, updateData: data)
                } else {
                    return
                }
            } else {
                logger.warn("update frame carried neither update nor updateUrl for doc:", roomId)
                return
            }
            // `.documentSyncStateChanged` (state "synced") is what a
            // reload-on-remote-write loader subscribes to. It replaced the
            // Swift-only `.remoteUpdate` event, removed in #2367.
            eventEmitter.emit(DocumentSyncStateChangedEvent(documentId: roomId, state: "synced"))

        case "awareness":
            // Wire format: `states` is an array of `[clientId, state]`
            // tuples (see `src/doc-worker/awareness.ts` and the JS client's
            // `sendAwarenessState`); `state == null` means removal. Apply
            // the frame and emit a JS-shaped **delta** event
            // (added/updated/removed client IDs) — #996.
            guard let roomId = roomId,
                  let states = json["states"] as? [[Any]] else { return }
            let delta = documentManager.applyRemoteAwarenessStates(roomId, states: states)
            if !delta.isEmpty {
                eventEmitter.emit(AwarenessEvent(
                    documentId: roomId,
                    added: delta.added,
                    updated: delta.updated,
                    removed: delta.removed
                ))
            }

        case "syncPerf":
            // Server sync-timing telemetry, sent only when our syncStep1
            // carried `requestPerf: true` (see
            // `OpenDocumentOptions.requestSyncPerf`). Same payload shape as
            // JS: `{ documentId, timings, clientTimings? }`. `clientTimings`
            // is derived from the per-phase capture in DocumentManager
            // (`getSyncTimings`), mirroring JS's syncPerf handler.
            guard let roomId = roomId else { return }
            let timingsAny = json["timings"] as? [String: Any] ?? [:]
            let timings = (try? JSONValue.typedRow(from: timingsAny, subject: "syncPerf timings")) ?? [:]

            // Assemble clientTimings exactly like JS: if syncComplete
            // hasn't yet stamped clientTotalMs (the already-in-sync case
            // where syncPerf can arrive first), compute it now from the
            // syncStep1 anchor, then strip the internal `syncStep1SentAt`
            // before emitting.
            var clientTimings: [String: JSONValue]? = nil
            if var raw = documentManager.getSyncTimings(roomId) {
                if let sentAt = raw["syncStep1SentAt"], raw["clientTotalMs"] == nil {
                    raw["clientTotalMs"] = Date().timeIntervalSince1970 * 1000.0 - sentAt
                }
                raw.removeValue(forKey: "syncStep1SentAt")
                // `raw` is `[String: Double]`, so this is a direct wrap —
                // no `JSONValue.typedRow` dynamic-cast chain needed.
                clientTimings = raw.mapValues { JSONValue.number($0) }
            }

            eventEmitter.emit(SyncPerfEvent(
                documentId: roomId,
                timings: timings,
                clientTimings: clientTimings
            ))

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
                meta: (json["meta"] as? [String: Any]).flatMap { try? JSONValue.typedRow(from: $0, subject: "workflowStatus meta") },
                startedByUserId: json["startedByUserId"] as? String
            )
            eventEmitter.emit(event)
            // If the workflow needs client-side apply and a handler is
            // registered via `define(...)`, run the claim → apply → confirm
            // flow. Terminal states are delivered to callers purely through
            // the `.workflowStatus` event above — `workflows.waitFor` (#1975)
            // subscribes to it (and reconciles on reconnect) rather than
            // relying on a client-side terminal dispatch.
            if event.needsApply {
                Task { [weak self] in
                    await self?.workflows.handleApplyEvent(event)
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
                meta: (json["meta"] as? [String: Any]).flatMap { try? JSONValue.typedRow(from: $0, subject: "workflowStarted meta") }
            )
            eventEmitter.emit(startedEvent)

        case "invitation":
            // Server-pushed invitation lifecycle change. JS delivers a
            // fully-typed `InvitationEvent` (`handleInvitationMessage` in
            // `src/client/JsBaoClient.ts`); mirror that here by decoding the
            // frame into the typed struct instead of emitting the raw JSON
            // dict (#1146). Required fields fall back to "" when the frame
            // omits them (it shouldn't); optional fields stay nil.
            let invitationDoc: InvitationEvent.Document?
            if let docJson = json["document"] as? [String: Any] {
                invitationDoc = InvitationEvent.Document(
                    documentId: docJson["documentId"] as? String,
                    title: docJson["title"] as? String,
                    tags: docJson["tags"] as? [String],
                    createdAt: docJson["createdAt"] as? String,
                    lastModified: docJson["lastModified"] as? String,
                    createdBy: docJson["createdBy"] as? String
                )
            } else {
                invitationDoc = nil
            }
            let invitationEvent = InvitationEvent(
                action: json["action"] as? String ?? "",
                invitationId: json["invitationId"] as? String ?? "",
                documentId: json["documentId"] as? String ?? "",
                permission: json["permission"] as? String ?? "",
                title: json["title"] as? String,
                invitedBy: json["invitedBy"] as? String,
                invitedAt: json["invitedAt"] as? String,
                expiresAt: json["expiresAt"] as? String,
                acceptedBy: json["acceptedBy"] as? String,
                document: invitationDoc
            )
            eventEmitter.emit(invitationEvent)

        case "notification":
            // Server-pushed live mirror of a durable in-app notification
            // (#779 / #1601). JS emits a fully-typed `NotificationEvent`
            // (`handleNotificationMessage` in `src/client/JsBaoClient.ts`);
            // mirror that by decoding the frame into the typed struct. Required
            // fields fall back to "" when the frame omits them (it shouldn't);
            // optional fields stay nil. The durable inbox row is the source of
            // truth — fetch it via `client.notifications.list()`.
            let notificationEvent = NotificationEvent(
                notificationId: json["notificationId"] as? String ?? "",
                title: json["title"] as? String ?? "",
                body: json["body"] as? String ?? "",
                iconUrl: json["iconUrl"] as? String,
                deepLink: json["deepLink"] as? String,
                sourceRef: json["sourceRef"] as? String,
                createdAt: json["createdAt"] as? String ?? ""
            )
            eventEmitter.emit(notificationEvent)

        case "meUpdated":
            // The me record carries app-defined custom fields, so the payload is
            // wrapped as a `JSONValue` rather than typed field by field. The
            // whole frame goes in: the event reads `value` out of it for the
            // typed field and keeps the frame for the legacy callback bridge,
            // which must reproduce what subscribers received before. A frame
            // that somehow isn't representable as JSON is dropped rather than
            // emitted half-decoded.
            if let frame = try? JSONCoding.decode(JSONValue.self, from: json) {
                eventEmitter.emit(MeUpdatedEvent(serverFrame: frame))
            } else {
                logger.warn("Dropping meUpdated frame: payload is not representable as JSON")
            }

        case "docMetadata":
            // Server-pushed metadata change. Carries `action` ∈ {created,
            // updated, deleted, evicted}, plus the new metadata blob (nil
            // on delete/revoke). Emit the same general metadata event as
            // JS; subscribers that care about delete/revoke filter
            // `action == "deleted"` themselves.
            guard let docId = roomId else { return }
            let actionStr = json["action"] as? String ?? "updated"
            let metadata = (json["metadata"] as? [String: Any]).flatMap { try? JSONValue.typedRow(from: $0, subject: "docMetadata metadata") }
            let changedFields = json["changedFields"] as? [String]
            let event = DocumentMetadataChangedEvent(
                documentId: docId,
                action: actionStr,
                metadata: metadata,
                changedFields: changedFields,
                source: "server"
            )
            eventEmitter.emit(event)

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

    // MARK: - Outbound unsynced flag

    // The flag lives in `DocumentManager` but every transition is decided from
    // state this class guards with `lock` (`pendingUpdates` +
    // `outboundEnqueuesInProgress`). Deciding and applying can't happen in one
    // critical section without nesting `lock` inside `DocumentManager`'s lock,
    // so instead each decision is stamped with a sequence taken under `lock`
    // and applied newest-decision-wins. That keeps a mark and a concurrent
    // clear applied in the order they were decided, in both interleaving
    // directions, without adding a `lock` → `DocumentManager.lock` ordering
    // edge a future DocumentManager callback could deadlock against.
    //
    // The invariant both decision sites enforce (#2105): the flag is cleared
    // for a document only at a moment when that document has no local update
    // that is queued, mid-enqueue, or drained-but-unconfirmed. The third case
    // used to be invisible — the flush removed the batch from `pendingUpdates`
    // before awaiting the sends — so an overlapping flush could clear the flag
    // over an unsent edit. `flushOutboundUpdates` now keeps each update in
    // `pendingUpdates` until the socket has accepted it, and takes per-document
    // ownership of the drain, so "drained" and "confirmed sent" are the same
    // instant. Anything that later actorizes this path must carry that
    // invariant rather than assume actor isolation subsumes it.
    //
    // Note the `lock` → `DocumentManager.lock` edge is avoided, not the
    // deadlock hazard in general: `unsyncedFlagApplyLock` *is* held across the
    // `markUnsyncedLocalChanges` call, so a future DocumentManager callback
    // fired under DM's own lock that reached `queueOutboundUpdate` would
    // deadlock against `unsyncedFlagApplyLock` much as it would have against
    // `lock` under the nesting alternative. What this buys is a narrower
    // exposure — `unsyncedFlagApplyLock` guards one map and one DM call,
    // whereas `lock` guards every outbound-queue mutation in this class.

    /// Apply an unsynced-flag decision made at `seq`, dropping it if a newer
    /// decision for the same document has already been applied.
    private func applyUnsyncedFlag(_ documentId: String, _ value: Bool, seq: UInt64) {
        unsyncedFlagApplyLock.withLock {
            guard seq > (unsyncedFlagAppliedSeq[documentId] ?? 0) else { return }
            unsyncedFlagAppliedSeq[documentId] = seq
            documentManager.markUnsyncedLocalChanges(documentId, value)
        }
    }

    /// Take the next flag-decision sequence. Caller must hold `lock`.
    private func nextUnsyncedFlagSeqLocked() -> UInt64 {
        unsyncedFlagSeq += 1
        return unsyncedFlagSeq
    }

    /// Outcome of the shared clear guard: either a decision sequence to clear
    /// the flag with, or the reason the clear was refused (logged by the
    /// caller, outside `lock`).
    private enum UnsyncedClearDecision {
        case clear(seq: UInt64)
        case blocked(reason: String)
    }

    /// Byte budget for ONE merged outbound frame — the server's default
    /// `MAX_UPDATE_SIZE` (`JsBaoClient.ts:2406`).
    ///
    /// Merging the whole queue into one frame makes crossing that threshold
    /// routine where a single transaction rarely would, and Swift's outbound
    /// path has no R2 upload flow (JS `transmitLocalUpdate` switches to one
    /// above the threshold — a pre-existing gap, tracked separately in
    /// #2591). The server does not reject an oversize frame — `MAX_UPDATE_SIZE`
    /// only routes storage, SQLite below it and R2 above
    /// (`src/doc-worker/storage/update-io.ts:82`), and there is no inbound WS
    /// size guard — but sending one anyway means every large batch takes the
    /// server's R2 write path and travels as one all-or-nothing frame, and a
    /// failed send leaves the batch queued so the next pass re-merges the same
    /// oversize batch. Capping at the same threshold JS switches upload paths
    /// at keeps the two clients' wire behavior comparable. So a flush merges
    /// only the longest prefix of the queue that fits the budget; the
    /// remainder follows on the next pass.
    static let maxMergedUpdateBytes = 102_400

    /// The prefix of `queued` to merge into this pass's frame. Always at least
    /// one update: a single update already over the budget goes out on its own,
    /// which is exactly what it did before batching existed.
    static func mergeBudgetPrefix(_ queued: [[UInt8]]) -> [[UInt8]] {
        var total = 0
        var count = 0
        for update in queued {
            let next = total + update.count
            if count > 0 && next > maxMergedUpdateBytes { break }
            total = next
            count += 1
        }
        return Array(queued.prefix(Swift.max(1, count)))
    }

    /// What a flush owner's peek at its document's queue found.
    private enum OutboundFlushPeek {
        /// The queued updates to send - merged into ONE wire frame (JS
        /// parity: `flushLocalUpdates` sends `Y.mergeUpdates(queued)`; #2584),
        /// capped at `maxMergedUpdateBytes` per pass.
        case next([[UInt8]])
        /// Nothing queued — try to release ownership and clear the flag.
        case drained
        /// This flush's ownership token was revoked (`closeDocument` /
        /// `destroy`), so it must exit without touching any shared state.
        case revoked
    }

    /// The one place that decides whether the outbound unsynced flag may be
    /// cleared for a document. Both decision sites (`flushOutboundUpdates` and
    /// `reconcileUnsyncedAfterSync`) route through it so their conditions
    /// cannot drift apart. Caller must hold `lock`.
    ///
    /// The flag may clear only when the document has no local update that is
    /// mid-enqueue (marked but not yet appended), queued (which now includes a
    /// batch whose send hasn't been confirmed), or being drained by another
    /// flush.
    private func unsyncedClearDecisionLocked(_ documentId: String) -> UnsyncedClearDecision {
        guard (outboundEnqueuesInProgress[documentId] ?? 0) == 0 else {
            return .blocked(reason: "enqueueInProgress")
        }
        guard pendingUpdates[documentId]?.isEmpty ?? true else {
            return .blocked(reason: "pendingQueued")
        }
        guard outboundFlushOwner[documentId] == nil else {
            return .blocked(reason: "flushInProgress")
        }
        return .clear(seq: nextUnsyncedFlagSeqLocked())
    }

    /// Apply a clear decision taken under `lock`, logging a refusal at debug.
    /// Called outside `lock` (the apply path takes `unsyncedFlagApplyLock`).
    private func applyUnsyncedClearDecision(_ documentId: String, _ decision: UnsyncedClearDecision) {
        switch decision {
        case .clear(let seq):
            applyUnsyncedFlag(documentId, false, seq: seq)
        case .blocked(let reason):
            // The line to grep when "evict says unsynced forever" is reported.
            logger.debug("[outbound] unsynced flag clear suppressed", documentId, reason)
        }
    }

    /// Queue and debounce local document updates for sending
    func queueOutboundUpdate(documentId: String, update: [UInt8]) {
        // Mark the doc unsynced the moment an edit is queued — it holds local
        // state the server doesn't have yet. Cleared only once the send actually
        // reaches the socket (in `flushOutboundUpdates`).
        //
        // This must happen BEFORE the debounce task is scheduled below. With
        // `SyncConfig(outboundDebounceMs: 0)` the flush can run to completion
        // the moment the lock is released — removing the pending update, sending
        // it, and clearing the flag — so a mark made after the critical section
        // would set the flag back with nothing pending left to ever clear it,
        // leaving `documents.evict` rejecting the doc indefinitely (#2004). It
        // also keeps the flag in place for this edit's own send: nothing between
        // the mark and that send's completion clears it — a concurrent flush of
        // an earlier batch can't clear it mid-send either, because that batch
        // stays in `pendingUpdates` until the socket confirms it (#2105).
        //
        // Marking first opens the opposite window — the update isn't in
        // `pendingUpdates` yet, so an already-running flush's "everything
        // drained" check could clear the mark we just made and leave the flag
        // false with an unsent edit queued behind it. `outboundEnqueuesInProgress`
        // closes it: the flush refuses to clear while an enqueue is mid-flight,
        // and the sequence stamp keeps the two decisions applied in the order
        // they were made if the flush's check ran before this one registered.
        let markSeq: UInt64 = lock.withLock {
            outboundEnqueuesInProgress[documentId, default: 0] += 1
            return nextUnsyncedFlagSeqLocked()
        }
        applyUnsyncedFlag(documentId, true, seq: markSeq)

        lock.withLock {
            var updates = pendingUpdates[documentId] ?? []
            updates.append(update)
            pendingUpdates[documentId] = updates

            // The enqueue stops being "in flight" exactly when its update
            // becomes visible in `pendingUpdates` — the same critical section,
            // so a flush never sees both counters low at once.
            let remaining = (outboundEnqueuesInProgress[documentId] ?? 1) - 1
            if remaining > 0 {
                outboundEnqueuesInProgress[documentId] = remaining
            } else {
                outboundEnqueuesInProgress.removeValue(forKey: documentId)
            }

            // Cancel existing timer
            outboundDebounceTimers[documentId]?.cancel()

            let debounce = options.sync.outboundDebounce
            outboundDebounceTimers[documentId] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, debounce) * 1_000_000_000))
                await self?.flushOutboundUpdates(documentId: documentId)
            }
        }

        onOutboundQueuedForTest?(documentId)
    }

    /// Drain a document's queued updates to the socket (#2105).
    ///
    /// Two rules make the clear guard correct by construction:
    ///
    /// 1. **One owner per document.** The first flush to claim the id in
    ///    `outboundFlushOwner` owns the drain; a concurrent flush records its
    ///    request in `outboundReflushRequested` and returns. The owner re-checks
    ///    the queue each iteration and consumes that request at both of its
    ///    release points, so an edit queued mid-drain — or a drain requested
    ///    while the owner sat in a send that then failed — is carried by the
    ///    owner rather than lost. Ownership is a token, and `closeDocument` /
    ///    `destroy` can revoke it while this flush is awaiting a send — so
    ///    every step after an `await` re-checks the token and exits on a
    ///    mismatch, rather than draining a reopened document's queue behind
    ///    its rightful new owner.
    /// 2. **Drain on confirmation, not on dequeue.** An update stays in
    ///    `pendingUpdates` until `sendLocalUpdate` confirms the socket took it,
    ///    so a batch in flight is visible to every clear guard as exactly what
    ///    it is — an unsent local edit. On a failed send the batch stays queued
    ///    and the flag stays set; the next flush (or the post-resync flush in
    ///    `reconcileUnsyncedAfterSync`) carries it.
    ///
    /// Ownership is released in the *same* critical section that decides the
    /// clear. Releasing first would let a new flush take ownership and start a
    /// send while this one evaluated its guard — the original bug in a new form.
    private func flushOutboundUpdates(documentId: String) async {
        let token: UInt64? = lock.withLock {
            guard outboundFlushOwner[documentId] == nil else {
                // Someone else owns the drain. Don't just return — record that a
                // drain was asked for, so the owner makes another pass instead of
                // releasing over the request. Without this, an owner whose send
                // is about to fail drops the request along with its ownership and
                // the queue is left with nothing to flush it.
                outboundReflushRequested.insert(documentId)
                return nil
            }
            outboundFlushTokenSeq += 1
            outboundFlushOwner[documentId] = outboundFlushTokenSeq
            return outboundFlushTokenSeq
        }
        guard let token else { return }

        while true {
            // Peek only while still the owner. If `closeDocument`/`destroy`
            // revoked the token (and a reopen may already have handed it to a
            // new flush), stop here: the queue this reads is no longer ours,
            // and nothing is left to release — the revoker took the entry.
            let peek: OutboundFlushPeek = lock.withLock {
                guard outboundFlushOwner[documentId] == token else { return .revoked }
                guard let queued = pendingUpdates[documentId], !queued.isEmpty else { return .drained }
                return .next(Self.mergeBudgetPrefix(queued))
            }
            switch peek {
            case .revoked:
                onOutboundFlushedForTest?(documentId)
                return

            case .drained:
                // The queue looks drained. Release ownership and decide the
                // clear in the SAME critical section — releasing first would
                // let a new flush take ownership and start a send while this
                // one evaluated its guard, which is the original bug.
                //
                // Release only if the queue is still empty under that lock: an
                // edit appended since the peek above has no flush of its own to
                // fall back on (its flush task ran while we owned the drain and
                // returned immediately), so the owner keeps ownership and
                // drains it rather than leaving it queued with nothing pending.
                //
                // And release only our OWN token: it may have been revoked and
                // re-handed to a new owner since the peek, in which case
                // releasing would drop *their* ownership and let a third flush
                // run alongside them.
                let release = lock.withLock { () -> (revoked: Bool, decision: UnsyncedClearDecision?) in
                    guard outboundFlushOwner[documentId] == token else { return (true, nil) }
                    // Any drain requested while we owned the document is
                    // satisfied by this pass: we are deciding under the same lock
                    // whether anything is queued, and either drain it (below) or
                    // establish there is nothing to drain.
                    outboundReflushRequested.remove(documentId)
                    guard pendingUpdates[documentId]?.isEmpty ?? true else { return (false, nil) }
                    outboundFlushOwner.removeValue(forKey: documentId)
                    return (false, unsyncedClearDecisionLocked(documentId))
                }
                if release.revoked {
                    onOutboundFlushedForTest?(documentId)
                    return
                }
                guard let decision = release.decision else { continue }
                // Everything queued has reached the socket. The clear can still
                // be refused — an enqueue mid-flight between its mark and its
                // insert (#2004) has a flush of its own still to come.
                applyUnsyncedClearDecision(documentId, decision)
                onOutboundFlushedForTest?(documentId)
                return

            case .next(let batch):
                // One wire frame per flush pass, however many edits queued up
                // (JS parity: `Y.mergeUpdates`; see `mergeUpdates` for why this
                // matters to a cold server room - #2584).
                let merged = documentManager.mergeUpdates(batch)
                let sent = await documentManager.sendLocalUpdate(documentId: documentId, update: merged)
                guard sent else {
                    // Leave the batch queued: `pendingUpdates` stays non-empty,
                    // so the clear guard (here and in
                    // `reconcileUnsyncedAfterSync`) keeps the document flagged
                    // unsynced and `evict` keeps refusing it. The owner stops
                    // rather than retrying on its own — there is no backoff
                    // policy here, so the retained batch waits for the next local
                    // edit's flush or for the post-resync flush in
                    // `reconcileUnsyncedAfterSync`.
                    //
                    // Unless a drain was requested while this send was in flight:
                    // that request arrived on a healthy socket (a resync had just
                    // completed) and found the document owned, so it did nothing
                    // but set the bit. Dropping ownership over it would strand
                    // the batch with no owner, no timer, and no pending request —
                    // the liveness hole this bit closes. Take another pass
                    // instead. The bit is consumed here, so the retry count is
                    // bounded by the number of requests actually made.
                    let outcome = lock.withLock { () -> (retry: Bool, retained: Int) in
                        let retained = pendingUpdates[documentId]?.count ?? 0
                        // Only act on our own token — the send we just awaited is
                        // exactly the window in which it can be revoked.
                        guard outboundFlushOwner[documentId] == token else {
                            return (false, retained)
                        }
                        if outboundReflushRequested.remove(documentId) != nil, retained > 0 {
                            return (true, retained)
                        }
                        outboundFlushOwner.removeValue(forKey: documentId)
                        return (false, retained)
                    }
                    if outcome.retry {
                        logger.debug("[outbound] send failed, re-flush requested, retrying",
                                     documentId, "\(outcome.retained)")
                        continue
                    }
                    logger.debug("[outbound] send failed, retaining batch", documentId, "\(outcome.retained)")
                    onOutboundFlushedForTest?(documentId)
                    return
                }

                let stillOwner = lock.withLock { () -> Bool in
                    // `closeDocument`/`destroy` can revoke ownership while the
                    // send above is in flight, and a reopen can hand it to a new
                    // flush. Removing the head then would consume an update that
                    // belongs to the new owner's queue, so leave it alone.
                    guard outboundFlushOwner[documentId] == token else { return false }
                    // Only the owner removes from the head, but `closeDocument`
                    // can drop the whole key mid-send and a later edit can append
                    // a new head behind it. Remove exactly the prefix we just
                    // confirmed (the merged batch), so a close-then-edit race
                    // can't discard an update that never reached the socket.
                    guard var queue = pendingUpdates[documentId],
                          queue.count >= batch.count,
                          queue.prefix(batch.count).elementsEqual(batch, by: ==) else { return true }
                    queue.removeFirst(batch.count)
                    if queue.isEmpty {
                        pendingUpdates.removeValue(forKey: documentId)
                    } else {
                        pendingUpdates[documentId] = queue
                    }
                    return true
                }
                guard stillOwner else {
                    onOutboundFlushedForTest?(documentId)
                    return
                }
            }
        }
    }

    /// Reconcile the outbound-unsynced flag after a (re)sync completes.
    ///
    /// The flush above leaves the flag set when a send fails (socket dropped
    /// mid-flush): the batch stays queued, so the clear guard refuses and
    /// `markUnsyncedLocalChanges(_, false)` never runs. A later reconnect
    /// re-syncs the document through the normal `syncStep1`/`syncStep2`
    /// exchange — which re-delivers the local diff to the server — but that
    /// path never cleared the flag, so `documents.evict`/`evictAll` kept
    /// rejecting the doc without `force` even after the server had caught up
    /// (issue #1979 codex review).
    ///
    /// So once a sync completes, clear the flag — but only when no fresh edit
    /// is still queued for send. A non-empty `pendingUpdates` means a real
    /// local edit hasn't drained yet; clearing then would reintroduce the
    /// original lost-edit-on-evict bug, so we leave it set and let
    /// `flushOutboundUpdates` clear it once that edit reaches the socket.
    ///
    /// Uses the same decide-under-`lock` / apply-by-sequence discipline as the
    /// flush — literally the same guard, `unsyncedClearDecisionLocked` — so the
    /// two decision sites can't drift apart.
    ///
    /// Then flushes anything still queued (#2105). Updates whose send failed
    /// now stay in `pendingUpdates` instead of being dropped, so without this
    /// trigger the queue would stay non-empty forever, the guard above would
    /// never clear, and the flag would stick after a resync — the #1979 bug in
    /// reverse. A resync completing is exactly the moment the socket is known
    /// good, so retry there. One shot, no backoff; re-sending an update the
    /// resync already carried is harmless (Yjs updates are idempotent).
    ///
    /// If a flush already owns the document, that spawned flush doesn't drain
    /// itself — it records the request in `outboundReflushRequested` and the
    /// owner makes another pass. The owner may be parked in the very send whose
    /// failure this retry exists to repair, and a failed send releases ownership
    /// without retrying, so a dropped request would strand the batch (PR #2396
    /// review).
    func reconcileUnsyncedAfterSync(documentId: String) {
        let decision: UnsyncedClearDecision = lock.withLock {
            unsyncedClearDecisionLocked(documentId)
        }
        applyUnsyncedClearDecision(documentId, decision)

        let hasQueuedUpdates = lock.withLock { !(pendingUpdates[documentId]?.isEmpty ?? true) }
        guard hasQueuedUpdates else { return }
        Task { [weak self] in
            await self?.flushOutboundUpdates(documentId: documentId)
        }
    }

    // MARK: - Test observability (outbound queue state)

    /// Number of updates still queued for send. Internal (visible only via
    /// `@testable import`) — the #2105 tests assert that a failed send retains
    /// its batch rather than dropping it. Never called from production code.
    func pendingOutboundUpdateCountForTest(_ documentId: String) -> Int {
        lock.withLock { pendingUpdates[documentId]?.count ?? 0 }
    }

    /// Whether a flush currently owns this document's drain. Internal — the
    /// #2105 tests assert the ownership entry is always released, since a
    /// leaked one would silently disable every future flush for the document.
    func isOutboundFlushInProgressForTest(_ documentId: String) -> Bool {
        lock.withLock { outboundFlushOwner[documentId] != nil }
    }
}

// MARK: - WebSocketManagerDelegate

extension JsBaoClient: WebSocketManagerDelegate {
    func webSocketManagerHasAccessToken() -> Bool {
        authController.getToken() != nil
    }

    func webSocketManagerBuildConnectionRequest(connectionId: String) -> (url: URL, headers: [String: String]) {
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

    func webSocketManagerOnStatusChange(_ status: ConnectionStatus) {
        eventEmitter.emit(StatusChangedEvent(status: status))
        if status == .connected {
            lock.withLock {
                lastOnlineAt = Date()
            }
        }
    }

    func webSocketManagerOnConnecting() {
        logger.debug("WebSocket connecting...")
    }

    func webSocketManagerOnConnected() {
        logger.log("WebSocket connected")
        // Re-subscribe to all open documents — except the ones JS's connect
        // sweep skips too (`JsBaoClient.ts` `[CONNECT] Evaluating sync`):
        //
        //   - `.manual` documents. The caller took over this document's sync
        //     timing (`deferNetworkSync` / `enableNetworkSync: false`), and a
        //     connect it did not ask for must not put a syncStep1 on the wire
        //     — that pulls server state into the ydoc at a moment the caller
        //     did not choose (#2475). `explicit: false` only stops the mode
        //     from being re-tagged; the send has to be skipped here.
        //   - `pendingCreate` documents. The server does not have the document
        //     yet, so a syncStep1 for it can never be answered — it would just
        //     hold the pending-sync claim until it ages out. The open-time
        //     availability retry loop and the post-commit hook drive those.
        let docIds = documentManager.listOpenDocuments().filter { docId in
            if documentManager.startNetworkMode(docId) == .manual {
                logger.debug("Connect sweep: manual start mode, not syncing", docId)
                return false
            }
            if documentManager.isPendingCreate(docId) {
                logger.debug("Connect sweep: pending create, not syncing", docId)
                return false
            }
            return true
        }
        Task {
            for docId in docIds {
                await startNetworkSync(documentId: docId, explicit: false)
            }
            // Flush analytics
            await analyticsQueue.flush()
            // Re-issue db.subscribe for every live database subscription —
            // the server-side connection mapping is dropped on disconnect.
            databases.resubscribeAll()
        }
    }

    func webSocketManagerOnMessage(_ data: Data) async {
        if let text = String(data: data, encoding: .utf8) {
            await handleWebSocketMessage(text)
        }
    }

    func webSocketManagerOnMessage(_ text: String) async {
        await handleWebSocketMessage(text)
    }

    func webSocketManagerOnClose(code: Int?, reason: String?) {
        logger.log("WebSocket closed:", code ?? 0, reason ?? "")
        // No syncComplete is coming for any in-flight cycle on a dead
        // transport; release every claim so the reconnect path's
        // `startNetworkSync` sweep isn't refused (JS parity: ws-close calls
        // `clearPendingSyncOperations`).
        documentManager.clearPendingSyncOperations()
        eventEmitter.emit(StatusChangedEvent(status: .disconnected))
        eventEmitter.emit(ConnectionCloseEvent(code: code, reason: reason))
    }

    func webSocketManagerOnError(_ error: Error) {
        logger.warn("WebSocket error:", error.localizedDescription)
        eventEmitter.emit(ConnectionErrorEvent(message: error.localizedDescription))
        eventEmitter.emit(GenericErrorEvent(
            scope: "websocket", message: error.localizedDescription
        ))
    }

    func webSocketManagerOnReconnectScheduled(delayMs: Int) {
        logger.debug("WebSocket reconnect in \(delayMs)ms")
    }

    func webSocketManagerOnDisconnectInitiated() {
        logger.debug("WebSocket disconnect initiated")
    }

    func webSocketManagerOnDisconnectResolved() {
        logger.debug("WebSocket disconnect resolved")
    }

    func webSocketManagerShouldReconnect(code: Int?, reason: String?) -> Bool {
        // Don't reconnect on auth failures
        if code == 4001 || code == 4003 { return false }
        return networkingAllowed()
    }
}

// MARK: - DocumentContext

/// Scoped helper for operations on a single document.
public final class DocumentContext: @unchecked Sendable {
    public let documentId: String
    private weak var client: JsBaoClient?
    private let blobManager: BlobManager
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(
        documentId: String,
        client: JsBaoClient,
        blobManager: BlobManager,
        transport: any Transport
    ) {
        self.documentId = documentId
        self.client = client
        self.blobManager = blobManager
        self.transport = transport
    }

    public func open(options: OpenDocumentOptions = OpenDocumentOptions()) async throws -> YDocument {
        guard let client = client else { throw JsBaoError(code: .unavailable) }
        return try await client.openDocument(documentId, options: options)
    }

    public func close(options: CloseDocumentOptions = CloseDocumentOptions()) async {
        await client?.closeDocument(documentId, options: options)
    }

    /// The open `YDocument`, or `nil` when the document is not open.
    public var doc: YDocument? {
        client?.getDoc(documentId)
    }

    public func isSynced() -> Bool {
        client?.isSynced(documentId) ?? false
    }

    public func blobs() -> DocumentBlobContext {
        DocumentBlobContext(
            documentId: documentId,
            transport: transport,
            blobManager: blobManager
        )
    }
}
