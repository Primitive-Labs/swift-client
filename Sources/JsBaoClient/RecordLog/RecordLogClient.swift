import Foundation
import YSwift

/// The client's record-log (format-3) state, built on first use.
///
/// A client that never opens a format-3 document builds none of this — no
/// client id, no store, no table in its database.
///
/// `@unchecked Sendable`: every mutable property is read and written under
/// `lock`, which is never held across a call out of this class.
final class RecordLogClientState: @unchecked Sendable {

    private let lock = NSRecursiveLock()
    private var _clientId: String?
    private var _bindings: [String: RecordLogDocumentBinding] = [:]
    private var _sessions: [String: RecordLogSession] = [:]
    /// Each document's writer history, kept while the client keeps its connection id.
    private var _histories: [String: RecordLogWriterHistory] = [:]
    private var _resolvedFormats: [String: Int] = [:]
    private var _resolving: Set<String> = []
    private var _unresolved: Set<String> = []
    private var _connection: RecordLogSocketConnection?
    /// The order each db3's index-list reads are applied in.
    let indexReads = RecordLogIndexReadOrder()

    /// The identity this client's writers are minted under: a ULID minted
    /// lazily once per `JsBaoClient` instance, never persisted. A relaunch is a
    /// new client; an earlier instance's writer with unjudged entries is an
    /// orphan the next open drains.
    var clientId: String {
        lock.withLock {
            if let _clientId { return _clientId }
            let minted = ULID.generate()
            _clientId = minted
            return minted
        }
    }

    func binding(_ documentId: String) -> RecordLogDocumentBinding? { lock.withLock { _bindings[documentId] } }
    func session(_ documentId: String) -> RecordLogSession? { lock.withLock { _sessions[documentId] } }

    /// What `documentId`'s earlier sessions on this connection id left; one per document.
    func history(_ documentId: String) -> RecordLogWriterHistory {
        lock.withLock {
            if let kept = _histories[documentId] { return kept }
            let made = RecordLogWriterHistory()
            _histories[documentId] = made
            return made
        }
    }
    var bindings: [(String, RecordLogDocumentBinding)] { lock.withLock { _bindings.map { ($0.key, $0.value) } } }
    var sessions: [RecordLogSession] { lock.withLock { Array(_sessions.values) } }
    var isEmpty: Bool { lock.withLock { _bindings.isEmpty } }

    func set(_ binding: RecordLogDocumentBinding, _ session: RecordLogSession, for documentId: String) {
        lock.withLock {
            _bindings[documentId] = binding
            _sessions[documentId] = session
        }
    }

    func remove(_ documentId: String) -> (RecordLogDocumentBinding, RecordLogSession)? {
        lock.withLock {
            guard let binding = _bindings.removeValue(forKey: documentId),
                  let session = _sessions.removeValue(forKey: documentId)
            else { return nil }
            return (binding, session)
        }
    }

    /// The format an open learned from the documents API before the document
    /// had a local row to remember it on.
    func resolvedFormat(_ documentId: String) -> Int? { lock.withLock { _resolvedFormats[documentId] } }
    func noteResolvedFormat(_ documentId: String, _ format: Int) { lock.withLock { _resolvedFormats[documentId] = format } }

    /// Documents whose open could not ask the documents API their format: the
    /// handshake asks once, before it goes out.
    func noteUnresolved(_ documentId: String) { lock.withLock { _ = _unresolved.insert(documentId) } }
    func noteResolved(_ documentId: String) { lock.withLock { _ = _unresolved.remove(documentId) } }
    func isUnresolved(_ documentId: String) -> Bool { lock.withLock { _unresolved.contains(documentId) } }

    /// Claim the documents-API question about `documentId` for one caller; a
    /// second caller while it is out answers `false`.
    func beginResolving(_ documentId: String) -> Bool { lock.withLock { _resolving.insert(documentId).inserted } }
    func endResolving(_ documentId: String) { lock.withLock { _ = _resolving.remove(documentId) } }

    func connection(make: () -> RecordLogSocketConnection) -> RecordLogSocketConnection {
        lock.withLock {
            if let _connection { return _connection }
            let made = make()
            _connection = made
            return made
        }
    }

    /// Forget every open document and the client id: the store was reset for
    /// another user, and this client's writers must not be reused for them.
    func resetForAnotherUser() -> [(String, RecordLogDocumentBinding, RecordLogSession)] {
        lock.withLock {
            let open = _bindings.compactMap { id, binding in _sessions[id].map { (id, binding, $0) } }
            _bindings = [:]
            _sessions = [:]
            _histories = [:]
            _clientId = nil
            return open
        }
    }
}

/// The socket every format-3 session sends on: frames go out in the order they
/// were handed over, one at a time, on one lane. Artifacts a receipt reads
/// (a load's manifest and chunks, a segment's) are fetched over HTTP.
///
/// `@unchecked Sendable`: its stored properties are immutable after `init`;
/// the stream continuation and the predicate are themselves thread-safe, and
/// the lane's only mutable state lives in the consuming task, under no lock
/// because one task owns it.
final class RecordLogSocketConnection: RecordLogConnection, @unchecked Sendable {
    private let lane: AsyncStream<String>.Continuation
    private let consumer: Task<Void, Never>
    private let isOpen: @Sendable () -> Bool
    private let fetch: (@Sendable (String) async throws -> Data)?

    init(
        send: @escaping @Sendable (String) async -> Void, isOpen: @escaping @Sendable () -> Bool,
        fetch: (@Sendable (String) async throws -> Data)? = nil
    ) {
        let (stream, lane) = AsyncStream.makeStream(of: String.self)
        self.lane = lane
        self.isOpen = isOpen
        self.fetch = fetch
        self.consumer = Task {
            for await text in stream { await send(text) }
        }
    }

    var fetchesArtifacts: Bool { fetch != nil }

    func fetchArtifact(_ path: String) async throws -> Data {
        guard let fetch else { throw RecordLogReceiptFailure("the connection cannot fetch artifacts") }
        return try await fetch(path)
    }

    deinit {
        lane.finish()
        consumer.cancel()
    }

    func send(_ frame: [String: JSONValue]) {
        lane.yield(RecordLogJSON.text(.object(frame)))
    }

    func connected() -> Bool { isOpen() }
}

/// An artifact read answered something other than 200 (or could not be
/// addressed). Its description shows the grant path without its token.
struct RecordLogArtifactError: Error, CustomStringConvertible {
    let status: Int?
    let path: String
    var description: String {
        "GET \(recordLogShownPath(path)) answered \(status.map(String.init) ?? "nothing (the path could not be resolved)")"
    }
}

// MARK: - The client's format-3 front door

extension JsBaoClient {

    /// Whether `documentId` is open here as a record-log (format-3) document.
    func isRecordLogDocument(_ documentId: String) -> Bool {
        recordLogState.binding(documentId) != nil
    }

    /// The binding of an open format-3 document, or `nil`.
    func recordLogBinding(_ documentId: String) -> RecordLogDocumentBinding? {
        recordLogState.binding(documentId)
    }

    /// The binding `documents.records(documentId)` reads and writes through:
    /// the document must be open, and format 3.
    func modelFreeBinding(_ documentId: String) throws -> RecordLogDocumentBinding {
        if let binding = recordLogBinding(documentId), !binding.isClosed { return binding }
        let format = documentManager.documentFormat(documentId)
        guard documentManager.isOpen(documentId), format != 3 else { throw Self.documentNotOpenForRecords(documentId) }
        let shown = format ?? 1
        throw JsBaoError(
            code: .documentFormatMismatch,
            message: "Document `\(documentId)` is a format \(shown) document; documents.records reads and writes "
                + "a record-log document (documentFormat 3).",
            details: ["documentId": .string(documentId), "documentFormat": .number(Double(shown))]
        )
    }

    /// The binding `documents.records(documentId)` reads through: as
    /// ``modelFreeBinding(_:)``, and a db3 whose rows have not loaded here is
    /// refused `DB3_NOT_RESIDENT` (js-bao's `readableStore`). Writes keep the
    /// open binding and queue.
    func readableModelFreeBinding(_ documentId: String) throws -> RecordLogDocumentBinding {
        let binding = try modelFreeBinding(documentId)
        guard binding.isResident else { throw db3NotResidentError([documentId], source: "documents.records") }
        return binding
    }

    /// A model-free call on a document that is not open.
    static func documentNotOpenForRecords(_ documentId: String) -> JsBaoError {
        JsBaoError(
            code: .notFound,
            message: "Document `\(documentId)` is not open. Open it (client.openDocument) before reading or "
                + "writing its records with documents.records.",
            details: ["documentId": .string(documentId)]
        )
    }

    /// The session of an open format-3 document, or `nil`.
    func recordLogSession(_ documentId: String) -> RecordLogSession? {
        recordLogState.session(documentId)
    }

    private var recordLogConnection: RecordLogSocketConnection {
        recordLogState.connection {
            RecordLogSocketConnection(
                send: { [weak self] text in
                    guard let self else { return }
                    self.recordLogFrameSentForTest?(text)
                    do {
                        try await self.wsManager.send(text)
                    } catch {
                        self.logger.warn("[record-log] a frame could not be sent:", error.localizedDescription)
                    }
                },
                isOpen: { [weak self] in
                    guard let self else { return false }
                    return self.wsManager.isSocketOpen && self.networkingAllowed()
                },
                fetch: { [weak self] path in
                    guard let self else { throw CancellationError() }
                    return try await self.fetchRecordLogArtifact(path)
                }
            )
        }
    }

    /// Fetch one artifact a format-3 room granted, at its origin-relative grant
    /// path resolved against the API URL. The path carries the grant, so no
    /// `Authorization` header is sent; only a 200 answers the bytes.
    func fetchRecordLogArtifact(_ path: String) async throws -> Data {
        if let hook = recordLogArtifactFetchForTest { try await hook(path) }
        guard let url = URL(string: path, relativeTo: URL(string: apiUrl))?.absoluteURL else {
            throw RecordLogArtifactError(status: nil, path: path)
        }
        let data: Data
        let status: Int?
        do {
            let (body, response) = try await NetworkSession.data(from: url)
            data = body
            status = (response as? HTTPURLResponse)?.statusCode
        } catch {
            recordLogArtifactStatusForTest?(path, nil)
            throw error
        }
        recordLogArtifactStatusForTest?(path, status)
        guard status == 200 else {
            logger.debug("[record-log] artifact", recordLogShownPath(path), "answered", status.map(String.init) ?? "no status")
            throw RecordLogArtifactError(status: status, path: path)
        }
        return data
    }

    // MARK: - Resolving the format before the open

    /// Resolve `documentId`'s format before anything about it reaches the wire,
    /// as the JS client does: the local row, else — when the network may be
    /// used — the documents API, remembered for the row the open creates. A
    /// format-3 document needs a storage provider that can host it; one that
    /// cannot is refused here, before a single frame.
    ///
    /// A format of 2 — a large document, no longer served — from the row or
    /// from the server is refused here, before anything is opened or sent.
    ///
    /// Offline with no local row the open proceeds as before, and binds once
    /// the row names format 3. With the socket not up yet (an open that
    /// connects it, a reconnect under way) the question is asked before the
    /// handshake instead: see ``resolveRecordLogBeforeHandshake(_:)``.
    func prepareRecordLogFormat(_ documentId: String) async throws {
        var format = documentManager.documentFormat(documentId) ?? recordLogState.resolvedFormat(documentId)
        let askable = format == nil && !documentManager.isLocalOnly(documentId) && !documentManager.isPendingCreate(documentId)
        if askable, !(networkingAllowed() && (wsManager.isSocketOpen || isConnected)) {
            recordLogState.noteUnresolved(documentId)
        }
        if askable, networkingAllowed(), wsManager.isSocketOpen || isConnected {
            do {
                if let resolved = try await lookUpDocumentFormat(documentId) {
                    recordLogState.noteResolvedFormat(documentId, resolved)
                    documentManager.noteDocumentFormat(documentId, resolved)
                    format = resolved
                }
            } catch let error as HttpError where error.status == 410 {
                throw documentFormatUnsupported(documentId: documentId, message: error.serverMessage)
            } catch {
                logger.debug("[record-log] the documents API did not say what format", documentId, "is:", error.localizedDescription)
            }
        }
        if format == largeDocumentFormat {
            throw documentFormatUnsupported(documentId: documentId)
        }
        guard format == RecordLogTransport.documentFormat else { return }
        _ = try await recordLogHost(documentId)
    }

    /// The store host for this client's storage, or the typed refusal.
    private func recordLogHost(_ documentId: String) async throws -> any Format2SqlHost {
        guard let provider = await offlineStore.getStorageProvider() else {
            throw Format2Storage.unavailable(reason: .notPersistent, documentId: documentId)
        }
        return try Format2Storage.host(for: provider, documentId: documentId)
    }

    // MARK: - Binding

    /// Bind a document the open has resolved as format 3: open its store, mint
    /// this client's writer, attach its session. The models connected next bind
    /// to it in `connectToSharedModels`.
    func bindRecordLogDocumentIfResolved(_ documentId: String) async throws {
        if let resolved = recordLogState.resolvedFormat(documentId) {
            documentManager.noteDocumentFormat(documentId, resolved)
        }
        let format = documentManager.documentFormat(documentId) ?? recordLogState.resolvedFormat(documentId)
        guard format == RecordLogTransport.documentFormat else { return }
        _ = try await bindRecordLogDocument(documentId)
    }

    /// `sessionEnded` fences the store's first writes (its state row and this
    /// client's writer): once it answers true, nothing is written and the
    /// bind throws `CancellationError`.
    @discardableResult
    func bindRecordLogDocument(
        _ documentId: String, sessionEnded: (() -> Bool)? = nil
    ) async throws -> RecordLogDocumentBinding {
        if let existing = recordLogState.binding(documentId) { return existing }
        let host = try await recordLogHost(documentId)
        if sessionEnded?() == true { throw CancellationError() }
        try await checkRecordLogOwner(host: host)
        if sessionEnded?() == true { throw CancellationError() }
        let binding = try RecordLogDocumentBinding(
            host: host, documentId: documentId, clientId: recordLogState.clientId, logger: logger
        )
        // A db3 created here is its own until its room's copy loads.
        binding.createdLocally = documentManager.isPendingCreate(documentId)
        binding.setRefusalReporter { [weak self] event in
            self?.eventEmitter.emit(event)
            self?._db3Lifecycle.writeRefused(event)
        }
        binding.onChange { [weak self, weak binding] notice in
            guard let self, let binding else { return }
            self._db3Lifecycle.rowsChanged(
                documentId, changes: Self.db3RowChanges(notice, binding), origin: notice.origin == .local ? .local : .remote,
                models: notice.models
            )
        }
        binding.onPendingChanged { [weak self] in
            self?._db3Lifecycle.pendingChanged(documentId)
        }
        binding.onError { [weak self] error in
            guard let self else { return }
            self.logger.warn("[record-log]", documentId, "—", error.message)
            var detail = error.details ?? [:]
            detail["code"] = .string(error.code.rawValue)
            self.eventEmitter.emit(ConnectionErrorEvent(
                message: error.message, documentId: documentId, messageType: "record.commit", detail: .object(detail)
            ))
        }
        let session = RecordLogSession(
            documentId: documentId, binding: binding,
            host: RecordLogSessionHost(
                connection: { [weak self] in self?.recordLogConnection },
                declarations: { [weak self] in self?.recordLogDeclarations() ?? [:] },
                synced: { [weak self] documentId in
                    Task { await self?.recordLogSessionSynced(documentId) }
                },
                syncFailed: { [weak self] documentId, reason in
                    self?.logger.debug("[record-log]", documentId, "— the open did not complete:", reason)
                    self?.documentManager.completePendingSyncOperation(documentId)
                    self?._db3Lifecycle.syncFailed(documentId, reason)
                },
                progress: { [weak self] documentId in
                    self?.recordLogSyncProgress(documentId)
                },
                // An index the room created for the declarations is in its
                // list from now: the store reads the list again.
                declared: { [weak self] documentId in
                    self?.refreshDb3Indexes(documentId)
                },
                status: { [weak self] documentId, status in
                    self?._db3Lifecycle.statusChanged(documentId, status)
                }
            ),
            logger: logger,
            history: recordLogState.history(documentId)
        )
        await session.attach()
        recordLogState.set(binding, session, for: documentId)
        // The store's view indexes come from the room's list, read by an open
        // that syncs the db3 (and on `record.declared`), not here: a db3 bound
        // for residency at start-up, or at its create, reads nothing.
        return binding
    }

    // MARK: - Indexes from the room's list

    /// How long a read of a db3's index list may take before it is abandoned
    /// (the cached list stands): js-bao's `DB3_INDEX_LIST_TIMEOUT_MS`.
    static let db3IndexListTimeout: TimeInterval = 10

    /// Read `documentId`'s index list (`GET db3/:id/indexes`) and hand it to
    /// its store, which builds its view's lookup indexes from it. Never awaited
    /// by an open: the open answers from the store and the list is applied when
    /// it arrives. Bounded by ``db3IndexListTimeout``; a failed or timed-out
    /// read logs one warning naming the document, and the cached list stands.
    /// Reads may answer out of order; one answered after a later read's list
    /// was applied is dropped.
    func refreshDb3Indexes(_ documentId: String) {
        db3IndexReadForTest?(documentId)
        let read = recordLogState.indexReads.issue(documentId)
        Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await self.requestJSON(
                    method: .get, path: "/db3/\(URLEncoding.encodeComponent(documentId))/indexes",
                    options: RequestOptions(timeout: Self.db3IndexListTimeout)
                )
                let entries = (answer?["indexes"]?.arrayValue ?? []).compactMap(RecordLogIndexEntry.init(json:))
                guard let binding = self.recordLogState.binding(documentId) else { return }
                try self.recordLogState.indexReads.apply(documentId, read) {
                    _ = try binding.withOperation { try binding.store.syncIndexes(entries) }
                }
            } catch {
                let status = (error as? HttpError).map { " (\($0.status))" } ?? ""
                self.logger.warn(
                    "[db3] \(documentId): the index list could not be read\(status): \(error.localizedDescription);"
                        + " the store keeps its cached indexes."
                )
            }
        }
    }

    /// Every registered model's declaration, as `record.declare` carries it:
    /// its fields with their options, and its compound unique constraints.
    func recordLogDeclarations() -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for name in registeredModelNames() {
            guard let schema = sharedModel(name)?.schema else { continue }
            out[name] = Self.recordLogDeclaration(schema)
        }
        return out
    }

    static func recordLogDeclaration(_ schema: PrimitiveSchema) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        for (name, descriptor) in schema.fields {
            var options: [String: JSONValue] = ["type": .string(descriptor.type.rawValue)]
            if descriptor.indexed { options["indexed"] = true }
            if descriptor.unique { options["unique"] = true }
            if descriptor.required { options["required"] = true }
            if descriptor.autoAssign { options["autoAssign"] = true }
            if let autoStamp = descriptor.autoStamp { options["autoStamp"] = .string(autoStamp.rawValue) }
            if let maxLength = descriptor.maxLength { options["maxLength"] = .number(Double(maxLength)) }
            if let maxCount = descriptor.maxCount { options["maxCount"] = .number(Double(maxCount)) }
            if let value = descriptor.default, let json = try? JSONValue(jsonAny: value.encodedForMeta()), json != .null {
                options["default"] = json
            }
            fields[name] = .object(options)
        }
        var declaration: [String: JSONValue] = ["fields": .object(fields)]
        let compound = schema.constraints.values.filter { $0.fields.count > 0 }.sorted { $0.name < $1.name }
        if !compound.isEmpty {
            declaration["uniqueConstraints"] = .array(compound.map {
                .object(["name": .string($0.name), "fields": .array($0.fields.map { .string($0) })])
            })
        }
        return .object(declaration)
    }

    /// The changes of a notice as `Db3RowsEvent` carries them: each record
    /// with the row the command answered, else the row its view holds now.
    static func db3RowChanges(_ notice: RecordLogChangeNotice, _ binding: RecordLogDocumentBinding) -> [Db3RowChange] {
        var out = notice.changes.map { Db3RowChange(model: $0.model, id: $0.id, row: $0.row) }
        let answered = Set(notice.changes.map { RecordLogRecordKey(model: $0.model, id: $0.id) })
        for key in notice.records where !answered.contains(key) {
            out.append(Db3RowChange(model: key.model, id: key.id, row: try? binding.store.read(model: key.model, id: key.id)))
        }
        return out
    }

    /// Bind every member of the format-3 documents bound here to `model`, for a
    /// model registered after they were bound: a db3 bound for residency (not
    /// open, so it has no Y.Doc) gets a member on a bare one, and an open
    /// session declares the model to the room before any entry of it.
    func bindRecordLogDocumentsTo(_ model: MultiDocModel) {
        for (documentId, binding) in recordLogState.bindings {
            if model.member(docId: documentId) == nil, !documentManager.isOpen(documentId), !binding.isClosed {
                _ = model.connect(docId: documentId, doc: YDocument())
            }
            guard let member = model.member(docId: documentId) else { continue }
            do {
                try member.bindRecordLog(binding)
            } catch {
                logger.warn("[record-log] could not bind", model.schema.name, "to", documentId, ":", error.localizedDescription)
            }
            if let session = recordLogState.session(documentId) {
                Task { await session.declare() }
            }
        }
    }

    /// Bind every registered model's member of `documentId` to its store.
    private func bindRecordLogMembers(_ documentId: String, _ binding: RecordLogDocumentBinding) {
        for name in registeredModelNames() {
            guard let member = sharedModel(name)?.member(docId: documentId) else { continue }
            do {
                try member.bindRecordLog(binding)
            } catch {
                logger.warn("[record-log] could not bind", name, "to", documentId, ":", error.localizedDescription)
            }
        }
    }

    /// The handshake is about to go out for a document whose open could not
    /// ask the documents API what format it is (the socket was not up yet, and
    /// this is the handshake that brings it up, or a reconnect re-syncing it).
    /// Ask now, once, and bind it when it is format 3, so the handshake is
    /// `record.open` rather than a `syncStep1` the room answers with
    /// `DOCUMENT_FORMAT_MISMATCH`.
    ///
    /// Answers `false` when the handshake must not go out this time: another
    /// call is asking about the same document, it resolved as format 3 and
    /// could not be bound, or its row names format 3 and no open has bound it
    /// yet. A question with no answer leaves the handshake as
    /// it was, as an open with the socket up does.
    func resolveRecordLogBeforeHandshake(_ documentId: String) async -> Bool {
        // A row that came to name format 2 after the open — a large document,
        // no longer served — never handshakes.
        if documentManager.documentFormat(documentId) == largeDocumentFormat
            || recordLogState.resolvedFormat(documentId) == largeDocumentFormat {
            await refuseUnsupportedDocumentFormat(documentId, error: documentFormatUnsupported(documentId: documentId))
            return false
        }
        // A row naming format 3 handshakes with its session's `record.open`
        // once an open binds it. A sync that gets here first — the one a
        // create's commit schedules can land while the open is between opening
        // the Y.Doc and binding — sends nothing: the room answers a `syncStep1`
        // by tearing the document down.
        if recordLogState.binding(documentId) == nil,
           (documentManager.documentFormat(documentId) ?? recordLogState.resolvedFormat(documentId))
               == RecordLogTransport.documentFormat {
            return false
        }
        guard recordLogState.isUnresolved(documentId) else { return true }
        guard recordLogState.binding(documentId) == nil,
              documentManager.documentFormat(documentId) == nil,
              recordLogState.resolvedFormat(documentId) == nil,
              documentManager.getDocument(documentId) != nil,
              !documentManager.isLocalOnly(documentId), !documentManager.isPendingCreate(documentId)
        else {
            recordLogState.noteResolved(documentId)
            return true
        }
        guard networkingAllowed() else { return true }
        guard recordLogState.beginResolving(documentId) else { return false }
        defer { recordLogState.endResolving(documentId) }
        let resolved: Int
        do {
            let format = try await lookUpDocumentFormat(documentId)
            recordLogState.noteResolved(documentId)
            guard let format else { return true }
            resolved = format
        } catch {
            recordLogState.noteResolved(documentId)
            logger.debug("[record-log] the documents API did not say what format", documentId, "is:", error.localizedDescription)
            return true
        }
        recordLogState.noteResolvedFormat(documentId, resolved)
        documentManager.noteDocumentFormat(documentId, resolved)
        if resolved == largeDocumentFormat {
            // A large document is no longer served: the handshake does not go
            // out, the document is closed under the app, and nothing it stored
            // is touched.
            await refuseUnsupportedDocumentFormat(documentId, error: documentFormatUnsupported(documentId: documentId))
            return false
        }
        guard resolved == RecordLogTransport.documentFormat, documentManager.getDocument(documentId) != nil else { return true }
        do {
            let binding = try await bindRecordLogDocument(documentId)
            bindRecordLogMembers(documentId, binding)
            return true
        } catch {
            logger.warn("[record-log]", documentId, "is a format-3 document this client cannot open:", error.localizedDescription)
            let refusal = (error as? JsBaoError) ?? JsBaoError(
                code: .unavailable, message: error.localizedDescription, details: ["documentId": .string(documentId)]
            )
            awaitingOpens.fail(documentId: documentId, error: refusal)
            return false
        }
    }

    /// Whether this device holds `documentId`'s format-3 data: rows, a cursor
    /// past 0, or a writer with entries.
    func recordLogHasLocalData(_ documentId: String) -> Bool {
        guard let binding = recordLogState.binding(documentId),
              let state = try? binding.store.storedState()
        else { return false }
        return state.rows > 0 || state.cursor > 0 || !state.writers.isEmpty
    }

    // MARK: - Frames

    /// Whether a frame belongs to a format-3 session, from its `type`,
    /// `messageType` and `code`: a `record.*` frame, or an `error` answering
    /// one (other than a format mismatch, which tears the document down
    /// through its own arm).
    static func isRecordLogFrame(type: String?, messageType: String?, code: String?) -> Bool {
        if type?.hasPrefix("record.") == true { return true }
        guard type == "error", messageType?.hasPrefix("record.") == true else { return false }
        return code != JsBaoErrorCode.documentFormatMismatch.rawValue
    }

    /// Hand a format-3 frame to its document's session; one for a document
    /// with no session is dropped.
    func routeRecordLogFrame(_ frame: [String: JSONValue]) async {
        recordLogFrameForTest?(frame)
        if let gate = recordLogFrameGateForTest, await !gate(frame) { return }
        // A db3 refused because its sync is off is gone for that reason: the
        // lifecycle hears it before the session marks the store refused,
        // which is what turns the db3 gone (#4806, the JS client's #4799).
        if frame["type"]?.stringValue == "error", frame["code"]?.stringValue == JsBaoErrorCode.db3SyncOff.rawValue,
           let documentId = frame["documentId"]?.stringValue {
            _db3Lifecycle.syncOffHeard(documentId)
        }
        guard let documentId = frame["documentId"]?.stringValue ?? frame["roomId"]?.stringValue,
              let session = recordLogState.session(documentId)
        else {
            logger.debug("[record-log] dropped", frame["type"]?.stringValue ?? "a frame", "for a document with no session")
            return
        }
        await session.receive(frame)
    }

    // MARK: - The connection

    /// The socket closed: every session drops what was in flight.
    func recordLogDisconnected() {
        let sessions = recordLogState.sessions
        guard !sessions.isEmpty else { return }
        Task {
            for session in sessions { await session.disconnected() }
        }
    }

    /// Networking may be allowed again on the same socket: every session
    /// sends what it queued meanwhile.
    func recordLogKick() {
        let sessions = recordLogState.sessions
        guard !sessions.isEmpty else { return }
        Task {
            for session in sessions { await session.kick() }
        }
    }

    // MARK: - Closing and purging

    /// The document closed: its session stops and its binding closes. The
    /// store keeps everything; the next open catches up from the cursor.
    func closeRecordLogDocument(_ documentId: String) async {
        guard let (binding, session) = recordLogState.remove(documentId) else { return }
        await session.close()
        binding.close()
    }

    /// Stop `documentId`'s conversation with its room and keep its store
    /// bound: what a db3's close does (#4701). The open group of saves commits.
    func releaseRecordLogSession(_ documentId: String) async {
        guard let binding = recordLogState.binding(documentId) else { return }
        await recordLogState.session(documentId)?.release()
        do {
            try binding.store.flush()
        } catch {
            logger.warn("[record-log]", documentId, "— the open group of saves did not commit at the release:", error.localizedDescription)
        }
    }

    /// Unbind a db3: its session and binding close and its models' members
    /// disconnect, so nothing of it answers here. The store keeps everything.
    func unbindRecordLogDocument(_ documentId: String) async {
        await closeRecordLogDocument(documentId)
        if !documentManager.isOpen(documentId) { disconnectRecordLogMembers(documentId) }
    }

    /// Remove `documentId`'s format-3 data from this device (an eviction, an
    /// account wipe). Unacknowledged writes are dropped and handed back as one
    /// `DocumentWriteRefusedEvent` with `.documentStorePurged`.
    func purgeRecordLogDocument(_ documentId: String) async {
        await unbindRecordLogDocument(documentId)
        guard let provider = await offlineStore.getStorageProvider(),
              let host = provider as? any Format2SqlHost,
              (try? RecordLogStore.hasTables(host: host)) == true
        else { return }
        let store = RecordLogStore(host: host, documentId: documentId, clientId: recordLogState.clientId, logger: logger)
        do {
            let reply = try store.purge(force: true)
            reportPurged(documentId, reply.handedBack)
            if !reply.nothingStored {
                logger.log("[record-log]", documentId, "— local store purged (", reply.pendingOps, "unacknowledged write(s) dropped)")
            }
        } catch {
            logger.warn("[record-log] purging", documentId, "failed:", error.localizedDescription)
        }
    }

    /// Purge every format-3 document this device holds.
    func purgeAllRecordLogDocuments() async {
        guard let provider = await offlineStore.getStorageProvider(),
              let host = provider as? any Format2SqlHost
        else { return }
        guard (try? RecordLogStore.hasTables(host: host)) == true else { return }
        let documents: [String] = (try? host.withConnection { connection in
            try connection.query("SELECT doc_id FROM record_log_state").compactMap { $0["doc_id"].stringValue }
        }) ?? []
        for documentId in Set(documents + recordLogState.bindings.map(\.0)) {
            await purgeRecordLogDocument(documentId)
        }
    }

    func reportPurged(_ documentId: String, _ handedBack: [RecordLogPendingEntry]) {
        let writes = handedBack.flatMap(\.refusedWrites)
        guard let first = writes.first else { return }
        logger.warn("[record-log] write-refused", documentId, "— DOCUMENT_STORE_PURGED handed back", handedBack.count, "entr(ies)")
        let event = DocumentWriteRefusedEvent(
            documentId: documentId, model: first.model, recordId: first.recordId,
            error: JsBaoError(
                code: .documentStorePurged,
                message: "The local copy of '\(documentId)' was removed before the room received "
                    + "\(handedBack.count) write(s); they were not applied.",
                details: ["documentId": .string(documentId), "scope": "local"]
            ),
            writes: writes, conflictingRecord: nil
        )
        eventEmitter.emit(event)
        _db3Lifecycle.writeRefused(event)
    }

    // MARK: - The principal

    /// Compare the user the record-log tables belong to with the one signed in.
    ///
    /// The browser's store is scoped by user through its file's namespace; this
    /// client's file is one per app, so the owner is written down. When both are
    /// known and differ the store is reset: every open format-3 document is
    /// closed, every document's rows, entries and projections are removed, and
    /// the client id is minted again — the previous user's writers are bound to
    /// them on the server, and their unsent writes are theirs, so no refusal is
    /// raised for them. Signed out (an offline relaunch before the token is
    /// back), nothing is compared. The owner is written at the first bind under
    /// a known user.
    ///
    /// - Throws: when the owner cannot be read, or the reset or the owner's
    ///   update does not complete. Nothing of the store may be bound then: the
    ///   bind that called this fails, and the next one checks again.
    func checkRecordLogOwner(host explicitHost: (any Format2SqlHost)? = nil) async throws {
        guard let userId = authController.getUserId(), !userId.isEmpty else { return }
        let host: any Format2SqlHost
        if let explicitHost {
            host = explicitHost
        } else {
            guard let provider = await offlineStore.getStorageProvider(),
                  let found = provider as? any Format2SqlHost
            else { return }
            host = found
        }
        let owner = try RecordLogStore.owner(host: host)
        if owner == userId { return }
        if let owner {
            try await resetRecordLogStore(host: host, from: owner, to: userId)
            return
        }
        // Nothing to compare against yet: only a store that holds record-log
        // tables is claimed, so a client that never binds a format-3 document
        // creates none of them.
        if try explicitHost != nil || RecordLogStore.hasTables(host: host) {
            try RecordLogStore.setOwner(host: host, userId: userId)
        }
    }

    /// The owner check at sign-in, which has no caller to throw to: a check
    /// that did not complete closes every open format-3 document, so nothing
    /// of a store that may be another user's is read or sent until a bind's
    /// own check passes.
    func checkRecordLogOwnerAtSignIn() async {
        do {
            try await checkRecordLogOwner()
        } catch {
            let closed = await closeAllRecordLogDocuments()
            logger.warn(
                "[record-log] could not check the store's owner (", error.localizedDescription, "):",
                closed, "open format-3 document(s) closed until a later open checks again"
            )
        }
    }

    /// Close every open format-3 document and forget the client id.
    @discardableResult
    private func closeAllRecordLogDocuments() async -> Int {
        let open = recordLogState.resetForAnotherUser()
        for (documentId, binding, session) in open {
            await session.close()
            binding.close()
            disconnectRecordLogMembers(documentId)
        }
        return open.count
    }

    private func resetRecordLogStore(host: any Format2SqlHost, from previous: String, to userId: String) async throws {
        let closed = await closeAllRecordLogDocuments()
        let dropped: Int
        do {
            dropped = try RecordLogStore.purgeAll(host: host)
            try RecordLogStore.setOwner(host: host, userId: userId)
        } catch {
            logger.warn("[record-log] resetting the store for another user failed:", error.localizedDescription)
            throw error
        }
        logger.log(
            "[record-log] another user signed in: the record-log store of the previous user was reset (",
            dropped, "unsent write(s) of theirs dropped,", closed, "open document(s) closed)"
        )
        _ = previous
    }

    /// Point every shared model's member of `documentId` back at its Y.Doc-less
    /// state: the binding it read through is gone.
    func disconnectRecordLogMembers(_ documentId: String) {
        for name in registeredModelNames() {
            sharedModel(name)?.disconnect(docId: documentId)
        }
    }
}
