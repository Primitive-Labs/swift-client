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
            logger: logger
        )
    }

    /// A document's format for `client.db3.subscribe`: what the bound store or
    /// the local row says, else the server's answer; `nil` while nothing local
    /// knows and the network cannot be asked.
    func db3FormatOf(_ documentId: String) async -> Int? {
        if recordLogBinding(documentId) != nil { return RecordLogTransport.documentFormat }
        if let known = documentManager.documentFormat(documentId) ?? recordLogState.resolvedFormat(documentId) { return known }
        guard networkingAllowed(), wsManager.isSocketOpen || isConnected else { return nil }
        do {
            guard let resolved = try await lookUpDocumentFormat(documentId) else { return nil }
            recordLogState.noteResolvedFormat(documentId, resolved)
            documentManager.noteDocumentFormat(documentId, resolved)
            return resolved
        } catch {
            logger.debug("[db3] the documents API did not say what format", documentId, "is:", error.localizedDescription)
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

    /// Open a db3 on the socket for its subscriptions: the client's own open,
    /// answering from the local store and syncing in the background.
    func openDb3ForSubscriptions(_ documentId: String) async throws {
        _ = try await openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: true), door: nil)
    }

    /// Close a db3 on the socket for its last subscription: its session stops,
    /// the room is told it unsubscribed, and its store stays bound.
    func closeDb3ForSubscriptions(_ documentId: String) async {
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

    /// A bound db3's marks, read from its store now.
    func db3SyncMarks(_ documentId: String) -> Db3SyncMarks? {
        guard let binding = recordLogBinding(documentId), !binding.isClosed else { return nil }
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
    func bindStoredDb3(_ documentId: String, sessionEnded: (() -> Bool)? = nil) async throws {
        guard recordLogBinding(documentId) == nil, !documentManager.isOpen(documentId) else { return }
        if let hold = db3BindHoldForTest { await hold(documentId) }
        if sessionEnded?() == true { throw CancellationError() }
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
    func adoptServerCreatedDb3(_ db3Id: String, info: Db3Info, session: UInt64) async {
        let sessionEnded = { [weak self] in self?.metadataSessionToken != session }
        guard !sessionEnded(), let userId = authController.getUserId(), !userId.isEmpty else { return }
        recordLogState.noteResolvedFormat(db3Id, RecordLogTransport.documentFormat)
        guard info.sync else { return }
        var payload: [String: Any] = ["documentId": db3Id, "tags": info.tags]
        if !info.title.isEmpty { payload["title"] = info.title }
        if !info.createdBy.isEmpty { payload["createdBy"] = info.createdBy }
        if !info.createdAt.isEmpty { payload["createdAt"] = info.createdAt }
        if !info.modifiedAt.isEmpty { payload["modifiedAt"] = info.modifiedAt }
        if let permission = info.permission?.rawValue ?? (info.custodian == "user:\(userId)" ? DocumentPermission.owner.rawValue : nil) {
            payload["permission"] = permission
        }
        await documentManager.handleServerDocuments([payload], sessionEnded: sessionEnded)
        guard !sessionEnded() else { return }
        do {
            let wasBound = recordLogBinding(db3Id) != nil
            try await bindStoredDb3(db3Id, sessionEnded: sessionEnded)
            if let binding = recordLogBinding(db3Id), !binding.isClosed, !sessionEnded() { try binding.markCaughtUpAtCreate() }
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
