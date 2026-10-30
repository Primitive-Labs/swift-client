import Foundation
import YSwift

// The client side of `client.db3`: what the lifecycle (`Db3Lifecycle`) asks
// of the client, answered from its document manager, its record-log state and
// its socket. The JS client's `db3Lifecycle` deps (`JsBaoClient.ts`).

extension JsBaoClient {

    /// The lifecycle's deps over this client. Every closure holds the client weakly.
    func makeDb3LifecycleDeps() -> Db3LifecycleDeps {
        Db3LifecycleDeps(
            emit: { [weak self] payload in self?.eventEmitter.emitErased(payload) },
            socketUp: { [weak self] in
                guard let self else { return false }
                return self.wsManager.isSocketOpen && self.networkingAllowed()
            },
            destroyed: { [weak self] in self?.isDestroyedForDb3 ?? true },
            resolveFormat: { [weak self] id in await self?.db3FormatOf(id) },
            storageRefusal: { [weak self] id in await self?.db3StorageRefusal(id) },
            formatRefusal: { [weak self] id in self?.recordLogState.formatRefusal(id) },
            open: { [weak self] id in try await self?.openDb3ForSubscriptions(id) },
            close: { [weak self] id in await self?.closeDb3ForSubscriptions(id) },
            bind: { [weak self] id in try await self?.bindStoredDb3(id) },
            resync: { [weak self] id in
                Task { await self?.startNetworkSync(documentId: id, explicit: false) }
            },
            unbind: { [weak self] id in await self?.unbindRecordLogDocument(id) },
            isOpen: { [weak self] id in self?.documentManager.isOpen(id) ?? false },
            pendingCreates: { [weak self] in self?.db3PendingCreates() ?? [] },
            isPendingCreate: { [weak self] id in self?.db3IsPendingCreate(id) ?? false },
            createRefusal: { [weak self] id in self?.db3CreateRefusal(id) },
            knownPermission: { [weak self] id in self?.db3PermissionOf(id) },
            forget: { [weak self] id in await self?.evictLocalDocument(id) },
            setRetentionPolicy: { [weak self] policy in self?.retentionPolicy = policy },
            isBound: { [weak self] id in self?.recordLogBinding(id).map { !$0.isClosed } ?? false },
            syncMarks: { [weak self] id in self?.db3SyncMarks(id) },
            storedState: { [weak self] id in try await self?.db3StoredState(id) },
            storedIds: { [weak self] in try await self?.db3StoredIds() ?? [] },
            purge: { [weak self] id, force in await self?.db3Purge(id, force: force) ?? Db3PurgeOutcome(purged: false) },
            unbindAll: { [weak self] in await self?.unbindAllDb3s() },
            boundIds: { [weak self] in self?.recordLogState.bindings.map(\.0) ?? [] },
            identityPending: { [weak self] in self?.db3IdentityOutgoing ?? false },
            logger: logger
        )
    }

    /// A document's format for `client.db3.subscribe`: what the bound store,
    /// the local row or the store's copy says (a held store is a db3), else
    /// the server's answer; `nil` while nothing local knows and the network
    /// cannot be asked.
    func db3FormatOf(_ documentId: String) async -> Int? {
        // A refusal belongs to the lookup that heard it: every call starts with
        // none, so an offline call never answers an earlier lookup's refusal.
        recordLogState.noteFormatRefusal(documentId, nil)
        if recordLogBinding(documentId) != nil { return RecordLogTransport.documentFormat }
        if let known = documentManager.documentFormat(documentId) ?? recordLogState.resolvedFormat(documentId) { return known }
        if (try? await db3StoredState(documentId)) != nil {
            noteDb3(documentId)
            return RecordLogTransport.documentFormat
        }
        guard networkingAllowed(), wsManager.isSocketOpen || isConnected else { return nil }
        // A final refusal of the lookup (403, 404, another 4xx) is kept for
        // the lifecycle, which fails the subscription.
        do {
            guard let resolved = try await lookUpDocumentFormat(documentId) else { return nil }
            recordLogState.noteResolvedFormat(documentId, resolved)
            documentManager.noteDocumentFormat(documentId, resolved)
            return resolved
        } catch {
            logger.debug("[db3] the documents API did not say what format", documentId, "is:", error.localizedDescription)
            recordLogState.noteFormatRefusal(documentId, FormatLookupVerdict.refusal(of: error, db3Id: documentId))
            return nil
        }
    }

    /// Why this client's storage cannot hold a db3 (an in-memory provider), or `nil`.
    func db3StorageRefusal(_ documentId: String) async -> JsBaoError? {
        guard let provider = await offlineStore.getStorageProvider() else {
            return Format2Storage.unavailable(reason: .notPersistent, documentId: documentId)
        }
        do {
            _ = try Format2Storage.host(for: provider, documentId: documentId)
            return nil
        } catch let error as JsBaoError {
            return error
        } catch {
            return JsBaoError(code: .format2StorageUnavailable, message: error.localizedDescription, details: ["documentId": .string(documentId)])
        }
    }

    /// The store host, when this client's storage can hold record-log tables.
    func db3Host() async -> (any Format2SqlHost)? {
        guard let provider = await offlineStore.getStorageProvider() else { return nil }
        return provider as? any Format2SqlHost
    }

    /// Record that `documentId` is a db3: its format, in memory and on its
    /// row when it has one, so an open binds its store and a handshake for it
    /// is `record.open`, never asking the documents API.
    func noteDb3(_ documentId: String) {
        recordLogState.noteResolvedFormat(documentId, RecordLogTransport.documentFormat)
        documentManager.noteDocumentFormat(documentId, RecordLogTransport.documentFormat)
    }

    /// Open a db3 on the socket for its subscriptions: the client's own open,
    /// answering from the local store and syncing in the background.
    ///
    /// Waits first for an identity change in progress (a sign-out, another
    /// user's sign-in), so the open is the new user's; one retired by a
    /// further change, or started by the outgoing user, throws
    /// `CancellationError`.
    func openDb3ForSubscriptions(_ documentId: String) async throws {
        try await db3IdentityRelease.wait(openedUnder: _db3Lifecycle.openIdentity(documentId))
        noteDb3(documentId)
        _ = try await openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: true), door: nil)
    }

    /// Close a db3 on the socket for its last subscription: its session stops,
    /// the room is told it unsubscribed, and its store stays bound.
    func closeDb3ForSubscriptions(_ documentId: String) async {
        if let hold = db3CloseHoldForTest { await hold(documentId) }
        guard documentManager.isOpen(documentId) else { return }
        await closeDocument(documentId, options: CloseDocumentOptions(), door: nil)
    }

    /// The format-3 documents created on this device, not yet committed, and
    /// bound here (a db3 is bound at its create).
    func db3PendingCreates() -> [String] {
        documentManager.listPendingCreates().filter {
            documentManager.documentFormat($0) == RecordLogTransport.documentFormat && recordLogBinding($0) != nil
        }
    }

    func db3IsPendingCreate(_ documentId: String) -> Bool {
        documentManager.isPendingCreate(documentId) && documentManager.documentFormat(documentId) == RecordLogTransport.documentFormat
    }

    /// Why the server refused committing a db3 created here (#4921), or `nil`.
    func db3CreateRefusal(_ documentId: String) -> Db3StateError? {
        guard let meta = documentManager.getLocalMetadata(documentId), meta.commitRefused == true, let error = meta.commitError else { return nil }
        return Db3StateError(code: error.code ?? "DB3_CREATE_FAILED", message: error.message)
    }

    /// Keep a db3 `client.db3.create` makes on this device under the id it
    /// minted (#4921): its metadata row is a pending create that commits
    /// through `POST db3`, and its store is bound as created here, so saves
    /// and queries work at once. `commitNow` starts the commit (an online
    /// create whose request failed in a way worth retrying); otherwise the
    /// next online transition commits it. Answers the db3 as the route will.
    func createPendingDb3(
        _ db3Id: String, title: String, type: String?, tags: [String]?, metadata: JSONValue?, commitNow: Bool
    ) async throws -> Db3Info {
        guard let userId = authController.getUserId(), !userId.isEmpty else {
            throw JsBaoError(code: .invalidArgument, message: "client.db3.create: there is no signed-in user to hold the db3")
        }
        let entry = try await documentManager.createLocalDocument(
            documentId: db3Id, title: title, localOnly: false, tags: tags, docMetadata: metadata,
            documentFormat: RecordLogTransport.documentFormat, db3Create: true, db3Type: type
        )
        do {
            try await bindStoredDb3(db3Id)
        } catch {
            logger.warn("[db3] \(db3Id): binding the new db3's store failed:", error.localizedDescription)
        }
        if commitNow && networkingAllowed() { documentManager.scheduleCommitRetry(documentId: db3Id) }
        _db3Lifecycle.createChanged(db3Id)
        let createdAt = entry.createdAt ?? ISO8601DateFormatter().string(from: Date())
        return Db3Info(
            id: db3Id, title: title, createdBy: userId, createdAt: createdAt, modifiedAt: createdAt, custodian: "user:\(userId)",
            sync: true, type: type, tags: tags ?? [], metadata: metadata, permission: nil, accessSource: nil, grantedAt: nil
        )
    }

    /// A pending db3 create committed (#4921): adopt the server's answer,
    /// read the db3's state again and fire `Db3CreatedEvent`.
    func db3CreateCommitted(_ db3Id: String, info: Db3Info) async {
        await adoptServerCreatedDb3(db3Id, info: info, session: metadataSessionToken)
        _db3Lifecycle.createChanged(db3Id)
        await blobManager.db3Committed(db3Id)
        eventEmitter.emit(Db3CreatedEvent(id: db3Id))
    }

    /// The permission a db3's state reports: the client's last record of it, in `Db3State`'s names.
    func db3PermissionOf(_ documentId: String) -> Db3Permission? {
        let meta = documentManager.getLocalMetadata(documentId)
        switch meta?.lastKnownPermission ?? meta?.permission {
        case "owner": return .owner
        case "admin": return .admin
        case "read-write": return .readWrite
        case "reader", "read": return .reader
        default: return nil
        }
    }

    /// A bound db3's marks, read from its store now; `nil` until its models
    /// are attached to the binding, when no query can read it yet, and while
    /// the binding is the previous user's (another user's token was applied
    /// and `rebindUserScopedStorage()` has not released it yet).
    func db3SyncMarks(_ documentId: String) -> Db3SyncMarks? {
        guard !db3IdentityOutgoing,
              let binding = recordLogBinding(documentId), !binding.isClosed, binding.attached else { return nil }
        let marks = (try? binding.refreshMarks()) ?? binding.marks
        return Db3SyncMarks(
            cursor: marks.cursor, permission: marks.permission, lastCatchUpAt: marks.lastCatchUpAt,
            replacing: marks.replacing, staged: marks.staged, createdLocally: binding.createdLocally
        )
    }

    /// Bind a db3 this device holds without subscribing to it: its store, an
    /// idle session, and a member of every registered model on a bare Y.Doc,
    /// so it answers reads and takes writes from its stored copy. Once
    /// `sessionEnded` answers true, nothing is written and the bind throws
    /// `CancellationError`.
    ///
    /// One bind of a db3 at a time: a caller arriving while another's is in
    /// flight joins it and returns with the models attached. Waits first for
    /// an identity change in progress, as an open does.
    func bindStoredDb3(_ documentId: String, sessionEnded: (@Sendable () -> Bool)? = nil) async throws {
        try await db3IdentityRelease.wait()
        guard recordLogBinding(documentId) == nil, !documentManager.isOpen(documentId) else { return }
        let (task, joined) = recordLogState.storedBind(documentId) { token in
            Task { [weak self] in
                guard let self else { return }
                defer { self.recordLogState.endStoredBind(documentId, token) }
                try await self.bindStoredDb3Once(documentId, sessionEnded: sessionEnded)
            }
        }
        try await task.value
        if joined, sessionEnded?() == true { throw CancellationError() }
    }

    private func bindStoredDb3Once(_ documentId: String, sessionEnded: (@Sendable () -> Bool)?) async throws {
        if let hold = db3BindHoldForTest { await hold(documentId) }
        if sessionEnded?() == true { throw CancellationError() }
        // An open bound it meanwhile, with its models.
        guard recordLogBinding(documentId) == nil, !documentManager.isOpen(documentId) else { return }
        documentManager.noteDocumentFormat(documentId, RecordLogTransport.documentFormat)
        _ = try await bindRecordLogDocument(documentId, sessionEnded: sessionEnded)
        connectToSharedModels(documentId: documentId, doc: YDocument())
    }

    /// Adopt a db3 the server just created for this account (#4806): write its
    /// metadata row from the answer, bind its store, and mark a fresh store
    /// caught up at cursor 0, so it is resident from the answer on: it
    /// answers reads and takes writes before any socket, and its first
    /// subscribe sends them. No pending create is made and nothing is
    /// committed: the server already holds it. A sync-off db3 is never
    /// adopted. `session` is the metadata session the request was made under:
    /// once it ended (a sign-out, another user), nothing is written or bound.
    /// A store that already holds the db3 keeps its catch-up mark and rows.
    ///
    /// Either way the answer says the id is a db3: its format is noted in
    /// memory, so a subscribe opens it without asking the documents API
    /// (which refuses every member of a sync-off db3) and is answered by its
    /// room.
    ///
    /// Only a db3 the signed-in user holds is adopted (#5054, the JS rule): one
    /// created for another user or held by the app is only known as a db3.
    /// `permission` is the level the create asked for, which the answer does
    /// not carry: it is the metadata row's level, and a `.reader` copy's store
    /// is marked read-only once bound, so a save is refused here before any
    /// socket.
    func adoptServerCreatedDb3(
        _ db3Id: String, info: Db3Info, session: UInt64, permission: Db3AliasPermission = .owner
    ) async {
        let sessionEnded: @Sendable () -> Bool = { [weak self] in self?.metadataSessionToken != session }
        guard !sessionEnded(), let userId = authController.getUserId(), !userId.isEmpty else { return }
        recordLogState.noteResolvedFormat(db3Id, RecordLogTransport.documentFormat)
        guard info.sync, info.custodian == "user:\(userId)" else { return }
        var payload: [String: Any] = ["documentId": db3Id, "tags": info.tags]
        if !info.title.isEmpty { payload["title"] = info.title }
        if !info.createdBy.isEmpty { payload["createdBy"] = info.createdBy }
        if !info.createdAt.isEmpty { payload["createdAt"] = info.createdAt }
        if !info.modifiedAt.isEmpty { payload["modifiedAt"] = info.modifiedAt }
        payload["permission"] = info.permission?.rawValue ?? permission.rawValue
        await documentManager.handleServerDocuments([payload], sessionEnded: sessionEnded)
        guard !sessionEnded() else { return }
        do {
            let wasBound = recordLogBinding(db3Id) != nil
            try await bindStoredDb3(db3Id, sessionEnded: sessionEnded)
            if let binding = recordLogBinding(db3Id), !binding.isClosed, !sessionEnded() {
                try binding.markCaughtUpAtCreate()
                // Created with a type: its first open declares nothing (#5020).
                if let type = info.type, !type.isEmpty { try binding.seedType(type) }
                if permission == .reader { try binding.applyPermissionChange(.reader) }
            }
            guard !sessionEnded() else {
                if !wasBound { await discardAdoption(db3Id) }
                return
            }
        } catch is CancellationError {
            return
        } catch {
            logger.warn("[db3] \(db3Id): adopting the db3 the server created failed:", error.localizedDescription)
        }
        _db3Lifecycle.adopted(db3Id)
    }

    /// The account changed while an adoption was binding (4806-C001): unbind
    /// the binding it made and remove what the bind wrote to the store it
    /// reached, which may be the next account's. A store that holds rows, a
    /// cursor or unjudged writes of the db3 keeps them.
    private func discardAdoption(_ db3Id: String) async {
        let store = recordLogBinding(db3Id)?.store
        await unbindRecordLogDocument(db3Id)
        guard let store else { return }
        do {
            let held = try store.storedState()
            guard held.rows == 0, held.cursor == 0, !held.replacing, held.writers.allSatisfy({ $0.pending == 0 }) else { return }
            _ = try store.purge(force: false)
        } catch {
            logger.warn("[db3] \(db3Id): removing an adoption the account change ended failed:", error.localizedDescription)
        }
    }

    /// How many writes to a db3 the room has not judged (0 for any other document).
    func db3PendingWrites(_ documentId: String) async -> Int {
        ((try? await db3StoredState(documentId)) ?? nil)?.writers.reduce(0) { $0 + $1.pending } ?? 0
    }

    /// Whether the db3s bound here are a previous user's: the signed-in user
    /// is not the one the user-scoped storage was bound for, and
    /// `rebindUserScopedStorage()` has not run since.
    var db3IdentityOutgoing: Bool {
        let scoped = documentManager.userId
        guard !scoped.isEmpty, let signedIn = authController.getUserId(), !signedIn.isEmpty else { return false }
        return signedIn != scoped
    }

    /// Whether nothing may be sent for the db3 now: a release of the previous
    /// user's db3s is closing it, or it is the previous user's under a new
    /// user's token.
    func isDb3Releasing(_ documentId: String) -> Bool {
        if db3IdentityRelease.isReleasing(documentId) { return true }
        guard db3IdentityOutgoing else { return false }
        return recordLogBinding(documentId) != nil
            || documentManager.documentFormat(documentId) == RecordLogTransport.documentFormat
    }

    /// An identity change begins (a sign-out, another user's sign-in): every
    /// db3 bound or open here is the previous user's until it settles. End it
    /// with `db3IdentityRelease.end(_:)`.
    func beginDb3IdentityRelease() -> Int {
        var ids = Set(recordLogState.bindings.map(\.0))
        for documentId in documentManager.listOpenDocuments()
        where documentManager.documentFormat(documentId) == RecordLogTransport.documentFormat {
            ids.insert(documentId)
        }
        return db3IdentityRelease.begin(releasing: ids)
    }

    /// The user changed: every db3 state is forgotten, and every open the
    /// outgoing user started that waits for the change is retired (the
    /// release that follows closes the db3 behind it).
    func forgetDb3Identity() {
        db3IdentityRelease.retire(below: _db3Lifecycle.forgetStates())
    }

    /// Unbind every db3 bound here (a logout, another user).
    func unbindAllDb3s() async {
        for (documentId, _) in recordLogState.bindings { await unbindRecordLogDocument(documentId) }
    }

    /// Log, once per client and door, that a document door used on a db3 has
    /// a db3 form.
    func warnDb3Door(_ door: Db3Door, _ documentId: String) {
        guard db3DoorWarnings.claim(door) else { return }
        logger.warn("[db3] \(door.rawValue)('\(documentId)') is deprecated on a db3: \(door.replacement(documentId)) "
            + "(logged once per client)")
    }

    /// Bind every db3 the signed-in user's store holds (and every format-3
    /// pending create), when a user is known.
    func bindStoredDb3s() async {
        guard let userId = authController.getUserId(), !userId.isEmpty else { return }
        await _db3Lifecycle.bindStored()
    }

    /// What the store holds of a db3, bound or not; `nil` when it holds nothing.
    func db3StoredState(_ documentId: String) async throws -> RecordLogStoredState? {
        if let binding = recordLogBinding(documentId), !binding.isClosed {
            return try binding.store.storedState()
        }
        // Signed out, the store is nobody's to read.
        guard let userId = authController.getUserId(), !userId.isEmpty else { return nil }
        guard let host = await db3Host(), try RecordLogStore.hasTables(host: host) else { return nil }
        let state = try RecordLogStore(host: host, documentId: documentId, clientId: recordLogState.clientId, logger: logger).storedState()
        let empty = state.cursor == 0 && state.rows == 0 && state.writers.isEmpty && state.lastCatchUpAt == nil && !state.replacing
        return empty ? nil : state
    }

    /// Purge a db3's store; unforced, refused while it holds unjudged writes.
    /// A forced purge hands what it dropped back as `DOCUMENT_STORE_PURGED`.
    func db3Purge(_ documentId: String, force: Bool) async -> Db3PurgeOutcome {
        guard let host = await db3Host(), (try? RecordLogStore.hasTables(host: host)) == true else {
            return Db3PurgeOutcome(purged: true)
        }
        let store = RecordLogStore(host: host, documentId: documentId, clientId: recordLogState.clientId, logger: logger)
        do {
            let reply = try store.purge(force: force)
            if reply.purged { reportPurged(documentId, reply.handedBack) }
            return Db3PurgeOutcome(purged: reply.purged)
        } catch {
            logger.warn("[db3] purging", documentId, "failed:", error.localizedDescription)
            return Db3PurgeOutcome(purged: false)
        }
    }

    /// Every db3 the store holds a state for; `[]` with no record-log tables.
    func db3StoredIds() async throws -> [String] {
        guard let userId = authController.getUserId(), !userId.isEmpty, let host = await db3Host() else { return [] }
        return try RecordLogStore.storedDocumentIds(host: host)
    }
}

/// A read or save named db3s whose rows have not been loaded on this device:
/// js-bao's `Db3NotResidentError`. `source` says what named them.
func db3NotResidentError(_ documents: [String], source: String? = nil) -> JsBaoError {
    let named = documents.count == 1 ? "The db3 '\(documents[0])' is" : "The db3s \(documents.map { "'\($0)'" }.joined(separator: ", ")) are"
    var details: [String: JSONValue] = ["documents": .array(documents.map { .string($0) })]
    if let source { details["source"] = .string(source) }
    return JsBaoError(
        code: .db3NotResident,
        message: "\(named) not resident on this device\(source.map { " (named by \($0))" } ?? ""): its rows have not been "
            + "loaded here. Subscribe to it (client.db3.subscribe) and await available() first.",
        details: details
    )
}

/// A document door used on a db3, for its once-per-client deprecation line.
enum Db3Door: String, Sendable {
    case openDocument = "client.openDocument"
    case documentsOpen = "client.documents.open"
    case closeDocument = "client.closeDocument"
    case documentsClose = "client.documents.close"

    /// What to use on a db3 instead.
    func replacement(_ documentId: String) -> String {
        switch self {
        case .openDocument, .documentsOpen:
            return "subscribe with client.db3.subscribe('\(documentId)')"
        case .closeDocument, .documentsClose:
            return "end this client's subscription with client.db3.unsubscribe('\(documentId)'), "
                + "or remove the local copy with client.db3.evict('\(documentId)')"
        }
    }
}

/// The doors a client has warned about. `@unchecked Sendable`: the set is
/// read and written under `lock`.
final class Db3DoorWarnings: @unchecked Sendable {
    private let lock = NSLock()
    private var warned: Set<Db3Door> = []

    /// Answers `true` the first time a door is claimed.
    func claim(_ door: Db3Door) -> Bool { lock.withLock { warned.insert(door).inserted } }
}

/// Whether a failed format lookup's HTTP status is the server's final answer
/// about the document, and the code a db3 subscription is refused with (the
/// JS client's `formatLookupVerdict`).
///
/// 403 is final as `DB3_ACCESS_REFUSED`, 404 as `NOT_FOUND`, and any other
/// 4xx but 401 and 429 is final with the server's own code (`.final(nil)`).
/// No status (the request never reached the server), a 5xx, 429 and 401 (the
/// session's problem, which the transport refreshes) say nothing about the
/// document: the lookup is asked again.
enum FormatLookupVerdict: Equatable {
    case retry
    case final(JsBaoErrorCode?)

    static func of(status: Int?) -> FormatLookupVerdict {
        guard let status else { return .retry }
        if status == 403 { return .final(.db3AccessRefused) }
        if status == 404 { return .final(.notFound) }
        if (400..<500).contains(status), status != 401, status != 429 { return .final(nil) }
        return .retry
    }

    /// The error a subscription waiting for `db3Id`'s format fails with, for
    /// a failed lookup: `DB3_ACCESS_REFUSED` or `NOT_FOUND` with `details:
    /// db3Id, status, serverCode`, or the `HttpError` itself for another final
    /// answer; `nil` when the lookup is asked again.
    static func refusal(of error: Error, db3Id: String) -> Error? {
        guard let http = error as? HttpError, case .final(let code) = of(status: http.status) else { return nil }
        guard let code else { return http }
        let details: [String: JSONValue] = [
            "db3Id": .string(db3Id), "status": .number(Double(http.status)), "serverCode": http.serverCode.map { .string($0) } ?? .null,
        ]
        let message = code == .db3AccessRefused
            ? "the server refused this user access to '\(db3Id)'"
            : "no db3 '\(db3Id)' was found"
        return JsBaoError(code: code, message: message, details: details)
    }
}

/// The client's identity changes in progress (a sign-out, another user's
/// sign-in), and the db3s each is releasing (the JS client's `db3Unbinding`
/// and `db3Releasing`). A db3's open and bind wait while any change is in
/// progress; one waiting when a further change begins is retired with
/// `CancellationError`, so a sign-out nested in a sign-in's release never
/// waits on an open that waits on it. So is an open the outgoing user started
/// (`retire(below:)`), whose close the release waits for. A logout during a
/// sign-in's release nests: opens resume once both ended.
///
/// `@unchecked Sendable`: every mutable property is read and written under
/// `lock`, which is never held across a resume.
final class Db3IdentityRelease: @unchecked Sendable {
    private struct Waiter {
        let identity: Int?
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var generation = 0
    private var marked: [Int: Set<String>] = [:]
    private var waiters: [Waiter] = []
    /// The lifecycle identity the user changed to: an open started under an
    /// earlier one is the outgoing user's.
    private var identity = 0

    /// Every db3 a change in progress is releasing.
    var releasing: Set<String> {
        lock.withLock { marked.values.reduce(into: Set<String>()) { $0.formUnion($1) } }
    }

    /// The opens and binds waiting now.
    var waiting: Int {
        lock.withLock { waiters.count }
    }

    func isReleasing(_ documentId: String) -> Bool {
        lock.withLock { marked.values.contains { $0.contains(documentId) } }
    }

    /// A change begins, releasing `ids`; answers its generation. Every open
    /// waiting for an earlier change is retired.
    func begin(releasing ids: Set<String>) -> Int {
        let (started, retired) = lock.withLock { () -> (Int, [Waiter]) in
            generation += 1
            marked[generation] = ids
            defer { waiters = [] }
            return (generation, waiters)
        }
        for waiter in retired { waiter.continuation.resume(throwing: CancellationError()) }
        return started
    }

    /// The user changed to the lifecycle's `identity` (`forgetStates`): every
    /// open waiting that started under an earlier one is retired, and one that
    /// arrives later is refused. Its release closes the db3 behind that open,
    /// so the open must not wait for the release to end.
    func retire(below identity: Int) {
        let retired = lock.withLock { () -> [Waiter] in
            self.identity = max(self.identity, identity)
            let stale = waiters.filter { $0.identity.map { $0 < self.identity } ?? false }
            waiters.removeAll { $0.identity.map { $0 < self.identity } ?? false }
            return stale
        }
        for waiter in retired { waiter.continuation.resume(throwing: CancellationError()) }
    }

    /// The change `generation` settled; once none is in progress, the opens
    /// waiting go ahead.
    func end(_ generation: Int) {
        let ready = lock.withLock { () -> [Waiter] in
            marked[generation] = nil
            guard marked.isEmpty else { return [] }
            defer { waiters = [] }
            return waiters
        }
        for waiter in ready { waiter.continuation.resume() }
    }

    /// Wait while a change is in progress; throws `CancellationError` when a
    /// further one begins meanwhile, or when `identity` (the lifecycle
    /// identity the open started under) is the outgoing user's.
    func wait(openedUnder identity: Int? = nil) async throws {
        let started = lock.withLock { () -> Int? in
            if let identity, identity < self.identity { return -1 }
            return marked.isEmpty ? nil : generation
        }
        guard let started else { return }
        if started < 0 { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Checked and registered in one hold: a `begin` or `retire` either
            // ran before (and is seen here) or runs after (and finds the waiter).
            let verdict = lock.withLock { () -> Result<Void, Error>? in
                if generation != started { return .failure(CancellationError()) }
                if let identity, identity < self.identity { return .failure(CancellationError()) }
                if marked.isEmpty { return .success(()) }
                waiters.append(Waiter(identity: identity, continuation: continuation))
                return nil
            }
            if let verdict { continuation.resume(with: verdict) }
        }
    }
}
