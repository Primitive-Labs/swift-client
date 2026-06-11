import Foundation
import YSwift
import Yniffi

/// Runtime-schema-driven model layer. `DynamicModel` owns a model's root
/// Y.Map inside the doc and surfaces CRUD against `PrimitiveRecord`
/// instances. It's the read/write counterpart of `PrimitiveSchema` and
/// the attach point for Work Item 2's per-record observers.
///
/// Structure in the doc:
/// ```
/// {modelName}       (Y.Map of record-id → record Y.Map)
///   {record-id}     (Y.Map of field-name → encoded value)
///     id            = "\"record-id\""
///     field1        = ...
///     ...
/// _meta_{modelName} (Y.Map — written by SchemaSync.syncModelMeta)
/// ```
public final class DynamicModel {
    public let schema: PrimitiveSchema
    internal let doc: YDocument

    /// Identifier for this doc within a shared SQLite store. Defaults
    /// to `BaoModelQueryEngine.legacyDefaultDocId`
    /// ("__legacy_default__" — js-bao's `DEFAULT_LEGACY_DOC_ID`) for
    /// single-doc usage. When multiple `DynamicModel`s share the same
    /// `BaoModelQueryEngine`, every row is tagged with
    /// `_meta_doc_id = self.docId` so per-doc queries scope correctly
    /// and `MultiDocModel` can run cross-doc aggregations.
    public let docId: String

    /// Query path: SQLite mirror kept synchronously-consistent on
    /// local writes + eventually-consistent on remote writes via a
    /// root-map observer + per-record observers. The engine may be
    /// shared across multiple DynamicModel instances (one per doc) —
    /// when shared, every row gets a `_meta_doc_id` column.
    private let queryEngine: BaoModelQueryEngine

    /// Internal accessor for the underlying SQLite mirror — used by the
    /// fileprivate `RootMapObserver` (record delete path) and by tests.
    internal var queryEngineInternal: BaoModelQueryEngine { queryEngine }

    /// Public accessor for the in-memory SQLite mirror that backs queries.
    /// Exposed so debug tooling (the inspector's "Memory SQL" tab, integration
    /// tests, ad-hoc REPL inspection) can run `rawQuery` against the live
    /// projection without having to recreate it. Treat as read-only — direct
    /// writes will desync from the YMap source of truth.
    public var inspectionQueryEngine: BaoModelQueryEngine { queryEngine }

    /// Convenience for inspection callers that want this model's SQL table
    /// name (after `sanitizedTableName` substitutions). Use with `rawQuery`
    /// on `inspectionQueryEngine` to get this model's rows.
    public var inspectionTableName: String {
        BaoModelQueryEngine.sanitizeTableName(schema.name)
    }
    private var docUpdateSubscription: YSwift.YSubscription?

    // MARK: - Per-record observation

    /// Subscriptions for each record's nested Y.Map, keyed by record
    /// id. One per live record. Cancelled on record delete + on
    /// model deinit.
    private var recordSubscriptions: [String: Yniffi.YSubscription] = [:]
    /// Subscription on the model's root Y.Map — fires `.insertedNested`
    /// on record add, `.removedNested` on record delete.
    private var rootSubscription: Yniffi.YSubscription?
    private let observerLock = NSLock()

    // MARK: - Public change-listener API (Model.subscribe)

    /// Registered change listeners. Keyed by UUID so unsubscribe can
    /// find and remove its own entry without an identity trick on the
    /// closure. Guarded by `listenerLock`.
    private var listeners: [UUID: () -> Void] = [:]
    private let listenerLock = NSLock()

    /// Register a callback that fires after any add, update, or
    /// delete on the model. Returns an unsubscribe closure. Matches
    /// js-bao browser's `Model.subscribe` (browser.js:3628).
    ///
    /// The callback runs on whichever thread committed the change:
    /// local writes fire synchronously on the writing thread AFTER the
    /// write transaction commits (matching js-bao, which notifies
    /// post-commit — see #1116); remote changes fire from the
    /// observer-drain queue. A batch (`transact`) notifies once per
    /// model, not once per write. Callbacks may safely re-enter the
    /// model (query, write) since no transaction is open when they
    /// run. Keep callbacks fast and non-blocking.
    @discardableResult
    public func subscribe(_ callback: @escaping () -> Void) -> () -> Void {
        let id = UUID()
        listenerLock.lock()
        listeners[id] = callback
        listenerLock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.listenerLock.lock()
            self.listeners.removeValue(forKey: id)
            self.listenerLock.unlock()
        }
    }

    /// Fire every registered listener. Snapshot under the lock, then
    /// invoke outside it so a listener can safely (un)subscribe from
    /// within its own callback without deadlocking.
    internal func notifyListeners() {
        listenerLock.lock()
        let snapshot = Array(listeners.values)
        listenerLock.unlock()
        for cb in snapshot { cb() }
    }

    /// Notify listeners of a local write, deferring until the
    /// enclosing write transaction commits. js-bao notifies after the
    /// Y.Doc transaction closes; firing synchronously *inside* the
    /// open yrs transaction (the previous behavior, #1116) meant a
    /// subscriber observed half-committed batch state — and could
    /// deadlock if its callback touched anything that needs a new
    /// transaction (`query()` draining an observer task that calls
    /// `transactSync`, for example).
    ///
    /// Inside a transaction (the thread-local `activeTx` is set by
    /// `transact` / `withTx` / `withThrowingTx`), the model is queued
    /// on the thread's pending list — deduplicated, so a batch of N
    /// writes notifies once, matching js-bao's once-per-commit
    /// semantics. The outermost transaction wrapper flushes the queue
    /// right after `transactSync` returns. Outside a transaction it
    /// fires immediately.
    internal func notifyListenersAfterWrite() {
        if activeTx != nil {
            let dict = Thread.current.threadDictionary
            var pending = dict[Self.pendingNotifyKey] as? [DynamicModel] ?? []
            if !pending.contains(where: { $0 === self }) {
                pending.append(self)
            }
            dict[Self.pendingNotifyKey] = pending
        } else {
            notifyListeners()
        }
    }

    /// Fire (and clear) the notifications queued on this thread for
    /// models bound to `docKey`'s doc. Called by the transaction
    /// wrappers after their `transactSync` closes — i.e. after the yrs
    /// commit — so subscriber callbacks observe fully-committed state
    /// and are free to open new transactions (query, write, etc.).
    /// Doc-scoped to match `activeTxByDoc`: a nested transaction on doc
    /// B closing must not flush notifications queued under doc A's
    /// still-open transaction.
    fileprivate static func flushPendingNotifications(for docKey: ObjectIdentifier) {
        let dict = Thread.current.threadDictionary
        guard let pending = dict[pendingNotifyKey] as? [DynamicModel],
              !pending.isEmpty else { return }
        let mine = pending.filter { $0.docIdentity == docKey }
        let rest = pending.filter { $0.docIdentity != docKey }
        if rest.isEmpty {
            dict.removeObject(forKey: pendingNotifyKey)
        } else {
            dict[pendingNotifyKey] = rest
        }
        for model in mine { model.notifyListeners() }
    }
    /// Serial queue that drains observer-driven SQLite work. Observers
    /// fire from inside yrs's commit hook (RwLock held), so they can't
    /// open a new `transactSync` directly — they dispatch here.
    /// Query methods sync on this queue before reading to ensure the
    /// SQLite mirror has caught up with any pending remote changes.
    /// Accessed by the observer delegates at file scope.
    internal let observerDrainQueue = DispatchQueue(
        label: "JsBaoClient.DynamicModel.observerDrain"
    )

    /// Per-instance queue marker so `awaitObserverDrain` can detect a
    /// re-entrant call from this model's own drain queue (a listener
    /// callback that runs `query()`, say) and skip the self-deadlocking
    /// `sync`. Set on `observerDrainQueue` in `init`.
    private let drainQueueKey = DispatchSpecificKey<Bool>()

    /// Serial queue used to run uniqueness reconciliation *off* the
    /// yrs update-observer callback. yrs's `observe_update_v1` fires
    /// from inside the commit path while the RwLock is still held, so
    /// opening a new `transactSync` from there would deadlock. See
    /// BaoModel.swift for the prior-art comment.
    private let reconcileQueue = DispatchQueue(
        label: "JsBaoClient.DynamicModel.reconcile"
    )

    // MARK: - Active-transaction thread-local
    //
    // `transact { ... }` stores the open yrs transaction on the
    // current thread's thread-dictionary. Every write/read helper in
    // DynamicModel routes through `withTx` (or `withThrowingTx`),
    // which reuses the thread-local if present or opens a new
    // transactSync otherwise. This gives batch atomicity (one yrs
    // commit for N writes) without threading a YrsTransaction through
    // every method signature.

    fileprivate static let activeTxKey = "JsBaoClient.DynamicModel.activeTx"

    /// Thread-local list of models with listener notifications queued
    /// while a write transaction is open. Flushed by the outermost
    /// transaction wrapper after `transactSync` returns (#1116).
    fileprivate static let pendingNotifyKey = "JsBaoClient.DynamicModel.pendingNotify"

    /// Open yrs transactions on this thread, keyed by the YDocument's
    /// identity. **Doc-scoped, not global**: a YrsTransaction is bound to
    /// one yrs doc, so a write to a model on doc B nested inside a
    /// `transact` on doc A must open B's own transaction — reusing A's
    /// would apply B's mutations through a transaction object belonging
    /// to a different doc. Same-doc nesting (any model sharing the same
    /// `YDocument` instance) still reuses the open transaction, which is
    /// what dodges the yrs reentrant-RwLock deadlock.
    fileprivate static var activeTxByDoc: [ObjectIdentifier: YrsTransaction] {
        get {
            Thread.current.threadDictionary[activeTxKey]
                as? [ObjectIdentifier: YrsTransaction] ?? [:]
        }
        set {
            if newValue.isEmpty {
                Thread.current.threadDictionary.removeObject(forKey: activeTxKey)
            } else {
                Thread.current.threadDictionary[activeTxKey] = newValue
            }
        }
    }

    fileprivate var docIdentity: ObjectIdentifier { ObjectIdentifier(doc) }

    /// The open transaction for **this model's doc** on the current
    /// thread, if any.
    fileprivate var activeTx: YrsTransaction? {
        Self.activeTxByDoc[docIdentity]
    }

    /// Open a single yrs transaction spanning every write/read done
    /// inside the closure. Mirrors js-bao's `BaseModel.withTransaction`.
    ///
    /// - Batch atomicity: observers fire once per batch, not per write.
    /// - Uniqueness enforcement sees records created earlier in the
    ///   batch, so consecutive creates with the same key still throw.
    /// - Nested `transact` calls reuse the outer transaction — no new
    ///   commit.
    /// - Partial-commit on throw: yrs does NOT roll back. Writes made
    ///   before a throw remain committed. Callers that need strict
    ///   all-or-nothing must track and undo manually.
    @discardableResult
    public func transact<T>(_ body: () throws -> T) throws -> T {
        // Nested transact on the same doc: reuse the outer tx, no new
        // commit. A transact on a *different* doc opens its own.
        if activeTx != nil {
            return try body()
        }
        let docKey = docIdentity
        var result: Result<T, Error>!
        // `body` is non-escaping but `transactSync`'s closure wants
        // @escaping. Use withoutActuallyEscaping — the closure truly
        // doesn't escape past this call.
        withoutActuallyEscaping(body) { body in
            doc.transactSync { txn in
                Self.activeTxByDoc[docKey] = txn
                defer {
                    var map = Self.activeTxByDoc
                    map.removeValue(forKey: docKey)
                    Self.activeTxByDoc = map
                }
                do { result = .success(try body()) }
                catch { result = .failure(error) }
            }
        }
        // Commit is done — deliver listener notifications queued
        // during the batch (even on a throw: yrs doesn't roll back,
        // so writes made before the throw ARE committed).
        Self.flushPendingNotifications(for: docKey)
        return try result.get()
    }

    /// Non-throwing variant used by reads / deletes. Reuses the active
    /// transaction when one is in scope; otherwise opens one and
    /// publishes it via the thread-local so nested helpers (and the
    /// post-commit notification queue) see it.
    fileprivate func withTx<T>(_ body: (YrsTransaction) -> T) -> T {
        if let existing = activeTx {
            return body(existing)
        }
        let docKey = docIdentity
        var result: T!
        withoutActuallyEscaping(body) { body in
            doc.transactSync { txn in
                Self.activeTxByDoc[docKey] = txn
                defer {
                    var map = Self.activeTxByDoc
                    map.removeValue(forKey: docKey)
                    Self.activeTxByDoc = map
                }
                result = body(txn)
            }
        }
        Self.flushPendingNotifications(for: docKey)
        return result
    }

    /// Throwing variant used by writes. Errors thrown inside the body
    /// surface out of `transactSync` intact.
    fileprivate func withThrowingTx<T>(
        _ body: (YrsTransaction) throws -> T
    ) throws -> T {
        if let existing = activeTx {
            return try body(existing)
        }
        let docKey = docIdentity
        var result: Result<T, Error>!
        withoutActuallyEscaping(body) { body in
            doc.transactSync { txn in
                Self.activeTxByDoc[docKey] = txn
                defer {
                    var map = Self.activeTxByDoc
                    map.removeValue(forKey: docKey)
                    Self.activeTxByDoc = map
                }
                do { result = .success(try body(txn)) }
                catch { result = .failure(error) }
            }
        }
        Self.flushPendingNotifications(for: docKey)
        return try result.get()
    }

    /// Opens the model bound to a YDocument and syncs the `_meta_*`
    /// metadata. Safe to call on the same (doc, schema) pair multiple
    /// times — `SchemaSync` has a session cache.
    ///
    /// `DynamicModel` is the **untyped / runtime-schema** model — use it when
    /// you don't have a codegen'd type (generic tooling, the debug inspector,
    /// schema-from-the-wire). For a known model, prefer the codegen'd type's
    /// `Model.*` statics. Internally it's also the per-document engine that
    /// `MultiDocModel` connects into the shared cross-document store.
    ///
    /// - Parameters:
    ///   - doc: the YDocument hosting this model's records.
    ///   - schema: the model's runtime schema.
    ///   - docId: identifier for this doc inside the SQLite mirror.
    ///     Required when sharing an engine with other docs — see
    ///     `MultiDocModel`. Defaults to js-bao's legacy doc id
    ///     (`__legacy_default__`) for single-doc usage.
    ///   - sharedEngine: if non-nil, this DynamicModel writes its
    ///     rows into the supplied engine (tagged with `docId`).
    ///     When nil, a fresh engine is created. Multi-doc setups
    ///     pass the same engine to every per-doc model.
    public init(
        doc: YDocument,
        schema: PrimitiveSchema,
        docId: String = BaoModelQueryEngine.legacyDefaultDocId,
        sharedEngine: BaoModelQueryEngine? = nil
    ) {
        self.doc = doc
        self.schema = schema
        self.docId = docId
        observerDrainQueue.setSpecific(key: drainQueueKey, value: true)

        // Resolve the engine first so the table exists by the time
        // init's seeding loop tries to upsert rows into it.
        let engine = sharedEngine ?? BaoModelQueryEngine()
        let fields = schema.fields.map { (name: $0.key, type: $0.value.type.toLegacyFieldType()) }
        let indexedFields = Set(schema.fields.compactMap { (name, desc) in
            (desc.indexed || desc.unique) ? name : nil
        })
        let stringsetFields = Set(schema.fields.compactMap { (name, desc) in
            desc.type == .stringset ? name : nil
        })
        engine.ensureTable(
            modelName: schema.name,
            fields: fields,
            indexedFields: indexedFields,
            withDocIdColumn: true,
            stringsetFields: stringsetFields
        )
        self.queryEngine = engine

        SchemaSync.syncModelMeta(doc: doc, schema: schema)

        // One-shot init transaction: install the root observer, then
        // iterate existing records and install per-record observers
        // + seed their SQLite rows. Doing this in a single tx means
        // we can't miss a record that gets added between "install
        // root obs" and "iterate records" — yrs is single-writer,
        // so no writes land while we hold the tx open.
        doc.transactSync { [self] txn in
            guard let root = txn.transactionGetOrInsertMap(name: self.schema.name)
                    as YrsMap? else { return }
            let rootDelegate = RootMapObserver(model: self)
            self.rootSubscription = root.observe(delegate: rootDelegate)
            let idCollector = KeyCollector()
            root.keys(tx: txn, delegate: idCollector)
            for recordId in idCollector.keys {
                self.installRecordObserverUnlocked(id: recordId, rootMap: root, tx: txn)
                self.upsertSqliteRow(id: recordId, rootMap: root, tx: txn)
            }
        }

        // Keep the doc-level subscription for post-merge unique
        // reconciliation. Cheap: just queues async work.
        self.docUpdateSubscription = doc.observeUpdate { [weak self] _ in
            guard let self else { return }
            self.reconcileQueue.async { [weak self] in
                self?.reconcileUniqueConstraints()
            }
        }
    }

    deinit {
        docUpdateSubscription?.cancel()
        // `Yniffi.YSubscription` is the raw FFI handle — it auto-
        // cancels on Drop when the reference count hits zero, so
        // clearing our refs is enough.
        rootSubscription = nil
        recordSubscriptions.removeAll()
    }

    public var modelName: String { schema.name }

    // MARK: - Create

    /// Create a record with a caller-supplied id. Throws
    /// `UniqueConstraintViolationError` if any resolved unique
    /// constraint is already held by a different record.
    @discardableResult
    public func create(id: String, values: [String: PrimitiveValue]) throws -> PrimitiveRecord {
        try applyWrite(id: id, values: values, isUpdate: false)
        return PrimitiveRecord(modelName: schema.name, id: id, model: self)
    }

    /// Create a record auto-assigning its id from the `id` field's
    /// function default (typically `$generate_ulid`).
    @discardableResult
    public func create(values: [String: PrimitiveValue]) throws -> PrimitiveRecord {
        let id: String
        if let supplied = values["id"]?.asId ?? values["id"]?.asString {
            id = supplied
        } else if let def = schema.fields["id"]?.default,
                  case let .function(name) = def,
                  let gen = PrimitiveSchemaRegistry.shared.resolve(name),
                  let generated = gen().asString {
            id = generated
        } else {
            id = PrimitiveSchemaRegistry.generateULID()
        }
        var vals = values
        vals.removeValue(forKey: "id")
        return try create(id: id, values: vals)
    }

    /// Update the given fields on an existing record. Same uniqueness
    /// semantics as `create`. Omitted fields are left unchanged.
    public func update(id: String, values: [String: PrimitiveValue]) throws {
        try applyWrite(id: id, values: values, isUpdate: true)
    }

    /// Create-or-update by id, the way js-bao's `BaseModel.save` does:
    /// insert the record if it doesn't exist yet, otherwise update it in
    /// place. The insert-vs-update decision is made *inside* the write
    /// transaction (so it can't race a concurrent local write), and drives
    /// the same default-filling difference as `create` vs `update` — a new
    /// id fills unspecified fields from schema defaults; an existing id
    /// leaves omitted fields untouched.
    @discardableResult
    public func save(id: String, values: [String: PrimitiveValue]) throws -> PrimitiveRecord {
        try withThrowingTx { [self] txn in
            let root = txn.transactionGetOrInsertMap(name: self.schema.name)
            let isUpdate = root.getMap(tx: txn, key: id) != nil
            try self.applyWriteInternal(
                id: id, values: values, isUpdate: isUpdate, tx: txn
            )
        }
        return PrimitiveRecord(modelName: schema.name, id: id, model: self)
    }

    /// Add a single member to a stringset field WITHOUT replacing the
    /// rest of the set. The underlying Y.Map is updated with one
    /// `insert(member, "true")` op — concurrent offline writes from
    /// other clients adding *different* members will all union when
    /// the docs reconcile (CRDT-friendly).
    ///
    /// This is the path to use for "add this tag", "add this user to
    /// the participants set", etc. The full-replace path
    /// (`update(id:, values: [field: .stringset([...])])`) overwrites
    /// the entire nested Y.Map, which loses concurrent adds.
    ///
    /// Throws if `fieldName` isn't a `.stringset` in the schema, the
    /// record doesn't exist, or the `maxCount` constraint would be
    /// violated.
    public func addStringsetMember(
        id: String,
        fieldName: String,
        member: String
    ) throws {
        guard let desc = schema.fields[fieldName] else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "Unknown field `\(fieldName)` on model `\(schema.name)`"
            )
        }
        guard desc.type == .stringset else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "Field `\(fieldName)` is type `\(desc.type)`, not stringset"
            )
        }
        if let maxLen = desc.maxLength, member.count > maxLen {
            throw FieldValidationError.stringsetMemberTooLong(
                field: fieldName, modelName: schema.name,
                limit: maxLen, member: member
            )
        }
        try withThrowingTx { tx in
            guard let root = tx.transactionGetOrInsertMap(name: schema.name)
                    as YrsMap? else {
                throw JsBaoError(
                    code: .notFound,
                    message: "Record `\(id)` not found on model `\(schema.name)`"
                )
            }
            guard let rec = root.getMap(tx: tx, key: id) else {
                throw JsBaoError(
                    code: .notFound,
                    message: "Record `\(id)` not found on model `\(schema.name)`"
                )
            }
            // Get-or-create the nested member map. Returns the existing
            // map when present, so we don't clobber concurrent members.
            let nested = rec.getOrInsertMap(tx: tx, key: fieldName)
            if let max = desc.maxCount {
                let collector = KeyCollector()
                nested.keys(tx: tx, delegate: collector)
                let willHaveCount = collector.keys.contains(member)
                    ? collector.keys.count
                    : collector.keys.count + 1
                if willHaveCount > max {
                    throw FieldValidationError.stringsetMaxCountExceeded(
                        field: fieldName, modelName: schema.name,
                        limit: max, got: willHaveCount
                    )
                }
            }
            nested.insert(tx: tx, key: member, value: "true")
        }
    }

    /// Remove a single member from a stringset field WITHOUT touching
    /// other members. Concurrent offline removes converge to "the
    /// member is gone"; concurrent adds of the same member after a
    /// remove follow yrs's standard last-writer-wins on the per-key
    /// position.
    ///
    /// No-ops if the member wasn't present. Throws if the record
    /// doesn't exist or the field isn't a stringset.
    public func removeStringsetMember(
        id: String,
        fieldName: String,
        member: String
    ) throws {
        guard let desc = schema.fields[fieldName] else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "Unknown field `\(fieldName)` on model `\(schema.name)`"
            )
        }
        guard desc.type == .stringset else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "Field `\(fieldName)` is type `\(desc.type)`, not stringset"
            )
        }
        try withThrowingTx { tx in
            guard let root = tx.transactionGetOrInsertMap(name: schema.name)
                    as YrsMap? else {
                throw JsBaoError(
                    code: .notFound,
                    message: "Record `\(id)` not found on model `\(schema.name)`"
                )
            }
            guard let rec = root.getMap(tx: tx, key: id) else {
                throw JsBaoError(
                    code: .notFound,
                    message: "Record `\(id)` not found on model `\(schema.name)`"
                )
            }
            guard let nested = rec.getMap(tx: tx, key: fieldName) else {
                return // no-op: field absent
            }
            _ = try? nested.remove(tx: tx, key: member)
        }
    }

    /// Insert-or-update by a single-field unique value. Mirrors
    /// js-bao's `save({ upsertOn: field })`.
    ///
    /// If `_uniqueIdx_{model}_{constraint}` already holds an entry for
    /// the built key, this merges the caller-supplied fields into that
    /// existing record (id is reassigned). Otherwise a new record is
    /// inserted with the supplied or auto-generated id.
    ///
    /// Only caller-provided fields are written on the merge path —
    /// fields not mentioned are left untouched. Schema defaults apply
    /// only on the insert path.
    @discardableResult
    public func upsert(
        _ values: [String: PrimitiveValue],
        on field: String,
        id: String? = nil
    ) throws -> UpsertResult {
        // --- Validate the upsert-on input up-front (no tx yet) -------
        guard let fieldValue = values[field] else {
            throw UpsertError.missingField(field: field)
        }
        // Match js-bao: null/undefined/empty-string disallowed.
        if case let .string(s) = fieldValue, s.isEmpty {
            throw UpsertError.nullOrEmptyField(field: field)
        }

        // The field must have a registered single-field unique
        // constraint (compound uniques are not a valid upsert target).
        let constraintOpt = schema.resolvedUniqueConstraints.first {
            $0.fields == [field]
        }
        guard let constraint = constraintOpt else {
            throw UpsertError.noSingleFieldUniqueConstraint(field: field)
        }

        // Build the upsert key eagerly — bails if the value can't key.
        guard let key = UniqueIndex.buildKey(fields: [field], values: values) else {
            throw UpsertError.nullOrEmptyField(field: field)
        }

        // --- Resolve inside a single transaction to avoid TOCTOU ----
        var resolved: Result<(id: String, wasCreated: Bool), Error> =
            .success((id: "", wasCreated: false))

        withTx { [self] txn in
            let indexMap = txn.transactionGetOrInsertMap(
                name: UniqueIndex.mapName(
                    modelName: self.schema.name,
                    constraintName: constraint.name
                )
            )
            let existing: String? = {
                guard let raw = try? indexMap.get(tx: txn, key: key),
                      let s = PrimitiveValue.decodeJsonString(raw) else { return nil }
                return s
            }()

            if let existingId = existing {
                // Merge path. JS `save({ upsertOn })` matches by the unique
                // field and updates the existing record — the existing id
                // wins and any supplied id is ignored. (JS only throws its
                // upsertOn-conflict error for ids *explicitly* passed to the
                // constructor; Swift can't distinguish explicit from fresh
                // ids, so the supplied id is treated like JS's auto id.)
                resolved = .success((id: existingId, wasCreated: false))
            } else {
                // Insert path. Resolve the id: caller-supplied > schema
                // default generator > fallback ULID.
                let newId: String
                if let supplied = id {
                    newId = supplied
                } else if let suppliedId = values["id"]?.asId
                          ?? values["id"]?.asString {
                    newId = suppliedId
                } else if let def = self.schema.fields["id"]?.default,
                          case let .function(name) = def,
                          let gen = PrimitiveSchemaRegistry.shared.resolve(name),
                          let generated = gen().asString {
                    newId = generated
                } else {
                    newId = PrimitiveSchemaRegistry.generateULID()
                }
                resolved = .success((id: newId, wasCreated: true))
            }
        }

        let outcome = try resolved.get()

        // --- Apply the write through the existing enforcement path --
        // `isUpdate = !wasCreated` so applyWrite only writes
        // caller-provided fields on the merge path, and applies schema
        // defaults only on the insert path.
        var toWrite = values
        toWrite.removeValue(forKey: "id")
        try applyWrite(id: outcome.id, values: toWrite, isUpdate: !outcome.wasCreated)

        return UpsertResult(
            record: PrimitiveRecord(
                modelName: schema.name, id: outcome.id, model: self
            ),
            wasCreated: outcome.wasCreated
        )
    }

    // MARK: - Read

    public func find(id: String) -> PrimitiveRecord? {
        let exists = withTx { [self] txn in
            let root = txn.transactionGetMap(name: self.schema.name)
            return root?.getMap(tx: txn, key: id) != nil
        }
        return exists ? PrimitiveRecord(modelName: schema.name, id: id, model: self) : nil
    }

    public func findAll() -> [PrimitiveRecord] {
        return withTx { [self] txn in
            guard let root = txn.transactionGetMap(name: self.schema.name) else { return [] }
            let collector = KeyCollector()
            root.keys(tx: txn, delegate: collector)
            return collector.keys.map {
                PrimitiveRecord(modelName: self.schema.name, id: $0, model: self)
            }
        }
    }

    // MARK: - Query (SQLite-backed mirror)

    /// MongoDB-style filtered query against a SQLite mirror of the
    /// model's records. Local writes keep the mirror synchronously
    /// up-to-date; remote writes are picked up asynchronously via
    /// the root-map observer. We drain that queue before reading so
    /// callers always see the latest state.
    public func query(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) -> [[String: Any]] {
        awaitObserverDrain()
        return queryEngine.query(
            modelName: schema.name, filter: filter, options: options,
            scopedToDocId: docId,
            stringsetFields: stringsetFieldNames
        )
    }

    /// Names of fields that use the stringset layout — stored in
    /// per-field junction tables `{main}__{field}` rather than on the
    /// main row. Consumed by the engine's `$contains` translator and
    /// by the post-query population pass, and by the delete/upsert
    /// paths so the right junction tables get swept.
    internal var stringsetFieldNames: Set<String> {
        Set(schema.fields.compactMap { $0.value.type == .stringset ? $0.key : nil })
    }

    /// Batch-prefetch variant. Runs the base query then, for each
    /// include spec, collects FK values and does ONE target lookup
    /// per spec instead of N-per-record. Mirrors js-bao's
    /// `query(filter, {include: [...]})` — results arrive with
    /// related records attached under `row["_related"][resultKey]`.
    public func query(
        _ filter: DocumentFilter? = nil,
        options: QueryOptions? = nil,
        include: [Include]
    ) throws -> [[String: Any]] {
        awaitObserverDrain()
        var rows = queryEngine.query(
            modelName: schema.name, filter: filter, options: options,
            scopedToDocId: docId,
            stringsetFields: stringsetFieldNames
        )
        try IncludeResolver.resolve(rows: &rows, includes: include, depth: 0)
        return rows
    }

    /// Paginated include variant. Same batching semantics, but the
    /// result carries cursors.
    public func queryPaged(
        _ filter: DocumentFilter? = nil,
        options: QueryOptions? = nil,
        include: [Include]
    ) throws -> PagedQueryResult<[String: Any]> {
        awaitObserverDrain()
        let base = try queryEngine.queryPaged(
            modelName: schema.name, filter: filter, options: options,
            scopedToDocId: docId,
            stringsetFields: stringsetFieldNames
        )
        var rows = base.data
        try IncludeResolver.resolve(rows: &rows, includes: include, depth: 0)
        return PagedQueryResult(
            data: rows,
            nextCursor: base.nextCursor,
            prevCursor: base.prevCursor,
            hasMore: base.hasMore
        )
    }

    /// Paginated variant. Returns a `PaginatedResult` carrying the
    /// page's rows plus opaque cursors for next/prev navigation.
    /// Throws `InvalidCursorError` if the supplied cursor was
    /// generated under a different sort order.
    public func queryPaged(
        _ filter: DocumentFilter? = nil,
        options: QueryOptions? = nil
    ) throws -> PagedQueryResult<[String: Any]> {
        awaitObserverDrain()
        return try queryEngine.queryPaged(
            modelName: schema.name, filter: filter, options: options,
            scopedToDocId: docId,
            stringsetFields: stringsetFieldNames
        )
    }

    public func count(_ filter: DocumentFilter? = nil) -> Int {
        awaitObserverDrain()
        return queryEngine.count(
            modelName: schema.name, filter: filter, scopedToDocId: docId,
            stringsetFields: stringsetFieldNames
        )
    }

    public func aggregate(_ options: AggregateOptions) -> [[String: Any]] {
        awaitObserverDrain()
        return queryEngine.aggregate(
            modelName: schema.name, options: options, scopedToDocId: docId,
            stringsetFields: stringsetFieldNames
        )
    }

    /// Convert a `PrimitiveValue` into the bind-friendly value that
    /// `BaoModelQueryEngine.bindValue` understands.
    ///
    /// Stringsets are deliberately omitted here — they no longer live
    /// on the main table's row dict. `upsertSqliteRow` pulls stringset
    /// values out separately and passes them to the engine via its
    /// `stringsets` parameter so they land in the junction tables.
    private func sqliteRepresentation(of value: PrimitiveValue) -> Any? {
        switch value {
        case let .string(s):    return s
        case let .number(n):    return n
        case let .boolean(b):   return b
        case let .id(s):        return s
        case let .date(s):      return s
        case .stringset:        return nil
        case let .json(d):      return String(data: d, encoding: .utf8) ?? ""
        }
    }

    /// Explicit "find by constraint OR create" primitive. Mirrors
    /// js-bao's `BaseModel.upsertByUnique`.
    ///
    /// - Parameters:
    ///   - name: resolved unique constraint name (single-field or compound).
    ///   - data: the full or partial record. MUST include every field
    ///     named by the constraint — those values form the lookup key.
    ///   - mode: `.either` insert-or-update; `.mustExist` only update;
    ///     `.mustNotExist` only insert.
    ///   - id: optional caller-supplied id used when inserting.
    @discardableResult
    public func upsertByUnique(
        constraint name: String,
        data: [String: PrimitiveValue],
        mode: UpsertMode = .either,
        id: String? = nil
    ) throws -> UpsertResult {
        guard let constraint = schema.resolvedUniqueConstraints
            .first(where: { $0.name == name })
        else {
            throw FindByUniqueError.constraintNotFound(name)
        }

        // Every constraint field must be present in `data` — we need
        // all of them to build the lookup key.
        for f in constraint.fields where data[f] == nil {
            throw UpsertByUniqueError.missingConstraintField(field: f)
        }

        // Build the key once up front.
        guard let key = UniqueIndex.buildKey(
            fields: constraint.fields, values: data
        ) else {
            // Shouldn't happen if every constraint field is non-null,
            // but `buildKey` is the source of truth.
            throw UpsertByUniqueError.missingConstraintField(
                field: constraint.fields.first ?? ""
            )
        }

        // Resolve existing record inside a transaction to avoid TOCTOU.
        var existingId: String?
        withTx { [self] txn in
            let indexMap = txn.transactionGetOrInsertMap(
                name: UniqueIndex.mapName(
                    modelName: self.schema.name,
                    constraintName: name
                )
            )
            if let raw = try? indexMap.get(tx: txn, key: key),
               let decoded = PrimitiveValue.decodeJsonString(raw) {
                existingId = decoded
            }
        }

        switch mode {
        case .mustExist where existingId == nil:
            throw UpsertByUniqueError.recordNotFound(constraint: name)
        case .mustNotExist where existingId != nil:
            throw UniqueConstraintViolationError(
                modelName: schema.name,
                constraintName: name,
                fields: constraint.fields,
                attemptedRecordId: id ?? "(auto)",
                existingRecordId: existingId!
            )
        default:
            break
        }

        if let existingId {
            var values = data
            values.removeValue(forKey: "id")
            try applyWrite(id: existingId, values: values, isUpdate: true)
            return UpsertResult(
                record: PrimitiveRecord(
                    modelName: schema.name, id: existingId, model: self
                ),
                wasCreated: false
            )
        }

        // Insert path. Resolve id: caller-supplied > data.id > default >
        // fresh ULID.
        let newId: String
        if let supplied = id {
            newId = supplied
        } else if let dataId = data["id"]?.asId ?? data["id"]?.asString {
            newId = dataId
        } else if let def = schema.fields["id"]?.default,
                  case let .function(name) = def,
                  let gen = PrimitiveSchemaRegistry.shared.resolve(name),
                  let generated = gen().asString {
            newId = generated
        } else {
            newId = PrimitiveSchemaRegistry.generateULID()
        }
        var values = data
        values.removeValue(forKey: "id")
        try applyWrite(id: newId, values: values, isUpdate: false)
        return UpsertResult(
            record: PrimitiveRecord(
                modelName: schema.name, id: newId, model: self
            ),
            wasCreated: true
        )
    }

    // MARK: - Post-merge uniqueness reconciliation

    /// Scan the model's records for post-merge uniqueness invariant
    /// violations and repair them. Mirrors js-bao's
    /// `resolveConflictsForBatch` in `BaseModel.ts`.
    ///
    /// When two offline clients create records that both pass the local
    /// uniqueness check and later merge via yrs, both records survive —
    /// yrs is deterministic at the CRDT level, but the application-layer
    /// uniqueness invariant is now broken. For each unique constraint,
    /// this method groups records by unique key, picks the largest id
    /// as the winner (matches js-bao's ULID-sortable convention),
    /// deletes the losers, and rewrites the `_uniqueIdx_*` entries to
    /// point at the survivors.
    ///
    /// Safe to call any time — a no-op when no duplicates exist.
    /// Idempotent.
    public func reconcileUniqueConstraints() {
        guard !schema.resolvedUniqueConstraints.isEmpty else { return }
        withTx { [self] txn in
            self.runReconcile(tx: txn)
        }
    }

    private func runReconcile(tx: YrsTransaction) {
        guard let root = tx.transactionGetMap(name: schema.name) else { return }

        // Collect all record ids.
        let idCollector = KeyCollector()
        root.keys(tx: tx, delegate: idCollector)
        if idCollector.keys.count < 2 { return }

        // Pre-read every record's field values once.
        var recordValues: [String: [String: PrimitiveValue]] = [:]
        for recordId in idCollector.keys {
            guard let rec = root.getMap(tx: tx, key: recordId) else { continue }
            recordValues[recordId] = snapshotFromMap(rec: rec, tx: tx)
        }

        // Per-constraint: build key→[recordId…] groups; losers go to
        // idsToDiscard. Mirrors js-bao's "sort ascending, keep last"
        // deterministic winner rule.
        var idsToDiscard: Set<String> = []
        for constraint in schema.resolvedUniqueConstraints {
            var groups: [String: [String]] = [:]
            for (recordId, values) in recordValues where !idsToDiscard.contains(recordId) {
                guard let key = UniqueIndex.buildKey(
                    fields: constraint.fields, values: values
                ) else { continue } // null-keyed → exempt
                groups[key, default: []].append(recordId)
            }
            for (_, ids) in groups where ids.count > 1 {
                let sorted = ids.sorted()
                for loser in sorted.dropLast() {
                    idsToDiscard.insert(loser)
                }
            }
        }

        if idsToDiscard.isEmpty { return }

        // Delete each loser and clean its `_uniqueIdx_*` entries (only
        // if the index still points at the discarded id; the yrs LWW
        // merge may have pre-picked a different owner).
        for loserId in idsToDiscard {
            let losersValues = recordValues[loserId] ?? [:]
            for constraint in schema.resolvedUniqueConstraints {
                guard let key = UniqueIndex.buildKey(
                    fields: constraint.fields, values: losersValues
                ) else { continue }
                let indexMap = tx.transactionGetOrInsertMap(
                    name: UniqueIndex.mapName(
                        modelName: schema.name,
                        constraintName: constraint.name
                    )
                )
                if let raw = try? indexMap.get(tx: tx, key: key),
                   PrimitiveValue.decodeJsonString(raw) == loserId {
                    _ = try? indexMap.remove(tx: tx, key: key)
                }
            }
            _ = try? root.remove(tx: tx, key: loserId)
        }

        // Reconcile `_uniqueIdx_*` to point at surviving records.
        // Matches js-bao's final pass (BaseModel.ts lines 1608–1628).
        for constraint in schema.resolvedUniqueConstraints {
            let indexMap = tx.transactionGetOrInsertMap(
                name: UniqueIndex.mapName(
                    modelName: schema.name,
                    constraintName: constraint.name
                )
            )
            for (recordId, values) in recordValues where !idsToDiscard.contains(recordId) {
                guard let key = UniqueIndex.buildKey(
                    fields: constraint.fields, values: values
                ) else { continue }
                if let raw = try? indexMap.get(tx: tx, key: key),
                   PrimitiveValue.decodeJsonString(raw) == recordId {
                    continue
                }
                indexMap.insert(
                    tx: tx,
                    key: key,
                    value: PrimitiveValue.jsonEncodeString(recordId)
                )
            }
        }
    }

    // MARK: - findByUnique

    /// Look up a record by the value of a single-field unique
    /// constraint. Convenience wrapper over the compound form.
    ///
    /// Matches js-bao's `findByUnique(constraintName, value)` shape
    /// (see `BaseModel.ts` line 3631).
    public func findByUnique(
        constraint name: String,
        value: PrimitiveValue
    ) throws -> PrimitiveRecord? {
        try findByUnique(constraint: name, values: [value])
    }

    /// Look up a record by the positional values of a resolved
    /// unique constraint. Values must be in the same order as
    /// `constraint.fields`.
    ///
    /// Returns nil on an index miss or a null/missing value (matches
    /// js-bao's null-key bypass). Throws if the constraint name is
    /// unknown or the value count doesn't match the field count.
    public func findByUnique(
        constraint name: String,
        values: [PrimitiveValue]
    ) throws -> PrimitiveRecord? {
        guard let constraint = schema.resolvedUniqueConstraints
            .first(where: { $0.name == name })
        else {
            throw FindByUniqueError.constraintNotFound(name)
        }
        guard values.count == constraint.fields.count else {
            throw FindByUniqueError.fieldCountMismatch(
                expected: constraint.fields.count, got: values.count
            )
        }

        // Pair positional values with field names to reuse the
        // canonical key builder.
        var valueDict: [String: PrimitiveValue] = [:]
        for (f, v) in zip(constraint.fields, values) { valueDict[f] = v }
        guard let key = UniqueIndex.buildKey(
            fields: constraint.fields, values: valueDict
        ) else { return nil }

        let recordId: String? = withTx { [self] txn in
            let indexMap = txn.transactionGetOrInsertMap(
                name: UniqueIndex.mapName(
                    modelName: self.schema.name,
                    constraintName: name
                )
            )
            guard let raw = try? indexMap.get(tx: txn, key: key),
                  let decoded = PrimitiveValue.decodeJsonString(raw)
            else { return nil }
            return decoded
        }

        guard let id = recordId else { return nil }
        return find(id: id)
    }

    // MARK: - Delete

    public func delete(id: String) {
        withTx { [self] txn in
            // Clean up the unique indexes first so their entries drop
            // along with the record — otherwise a subsequent create
            // with the same unique value would see a stale lookup and
            // falsely report a violation.
            self.clearUniqueIndexesForRecord(id: id, tx: txn)

            let root = txn.transactionGetOrInsertMap(name: self.schema.name)
            _ = try? root.remove(tx: txn, key: id)
        }

        // Direct SQLite + observer cleanup on local delete. The
        // root-map observer will ALSO fire `.removedNested` on commit
        // and redundantly delete/cancel — both paths are idempotent.
        cancelRecordObserverUnlocked(id: id)
        queryEngine.deleteRecord(
            modelName: schema.name, id: id, scopedToDocId: docId,
            stringsetFields: stringsetFieldNames
        )
        // Deferred when inside an outer `transact` batch (#1116).
        notifyListenersAfterWrite()
    }

    // MARK: - Write + uniqueness enforcement

    /// Core write path shared by `create` and `update`. Opens a single
    /// transaction and, inside it:
    ///   1. Reads the record's existing state (for update).
    ///   2. Builds a merged "dataToSave" (old + new, minus id).
    ///   3. For each resolved unique constraint, checks that the key is
    ///      free (or already owned by this record).
    ///   4. Writes the new fields into the record Y.Map.
    ///   5. Releases any old unique-index entries whose keys changed.
    ///   6. Writes the new unique-index entries.
    ///
    /// Everything is in one yrs transaction so the uniqueness check
    /// cannot race a concurrent local write.
    private func applyWrite(
        id: String,
        values newValues: [String: PrimitiveValue],
        isUpdate: Bool
    ) throws {
        try withThrowingTx { [self] txn in
            try self.applyWriteInternal(
                id: id,
                values: newValues,
                isUpdate: isUpdate,
                tx: txn
            )
        }
    }

    private func applyWriteInternal(
        id: String,
        values: [String: PrimitiveValue],
        isUpdate: Bool,
        tx txn: YrsTransaction
    ) throws {
        var newValues = values
        let root = txn.transactionGetOrInsertMap(name: self.schema.name)

        // Read existing record (if any) WITHOUT creating it —
        // creating an empty nested map before validation would
        // leak a visible empty record when we later throw.
        let existing = root.getMap(tx: txn, key: id)
        let oldData: [String: PrimitiveValue] = existing.map {
            self.snapshotFromMap(rec: $0, tx: txn)
        } ?? [:]

        // Apply schema-declared auto-timestamps BEFORE validation so a
        // `required: true` + `auto_stamp = "create"` field doesn't trip
        // the required check. Mirrors js-bao `BaseModel.save` (the
        // pre-transact stamp block) + the schemaless `applyAutoStamps`:
        //
        //   - `create`: stamp only on insert (`!isUpdate`) AND only when
        //     the caller didn't supply a non-nil value AND no value is
        //     already persisted. (`isUpdate` here is the in-transaction
        //     insert-vs-update decision `save()` already computed.)
        //   - `update` / `both`: stamp on every write unless the caller
        //     supplied an explicit non-nil value on this save.
        //
        // The stamp is `Date.now()` — epoch milliseconds as a number,
        // matching js-bao's `Date.now()` value (a JS number). We fold it
        // into `newValues` so the rest of the path (merge, dirty-check,
        // unique-index reconciliation, write) treats it like any caller
        // field. "Explicit" = the field is present in the caller's
        // `values`. (Swift's typed `primitiveValues()` omits nil fields
        // entirely, so an absent key is the analogue of js-bao's
        // null/undefined — there is no in-dict null sentinel.) A
        // persisted-from-a-previous-save value is NOT treated as explicit,
        // so `update` keeps firing on every save.
        let nowMillis = (Date().timeIntervalSince1970 * 1000).rounded()
        for (fname, desc) in self.schema.fields {
            guard let stamp = desc.autoStamp else { continue }
            // Explicit-wins: caller set this field on this save.
            if newValues[fname] != nil { continue }
            switch stamp {
            case .create:
                if isUpdate { continue }
                // Don't overwrite an already-persisted value.
                if oldData[fname] != nil { continue }
            case .update, .both:
                break  // always fire (caller didn't set it, per check above)
            }
            newValues[fname] = .number(nowMillis)
        }

        // Merge caller values on top of existing, and fill in
        // schema defaults for anything still missing (only
        // meaningful on create; a no-op on update since existing
        // fields will already cover the dict).
        var dataToSave = oldData
        for (k, v) in newValues { dataToSave[k] = v }
        if !isUpdate {
            for (fname, desc) in self.schema.fields where dataToSave[fname] == nil {
                if let def = desc.default, let v = self.materializeDefault(def) {
                    dataToSave[fname] = v
                }
            }
        }

        // Declarative required-field validation — runs on EVERY save
        // (insert and update), matching js-bao's `validateBeforeSave`
        // (BaseModel.ts line 2159). The merged-state view above
        // (oldData + newValues) is what we check: an update that
        // leaves a required field untouched passes because the old
        // value is still in dataToSave; an update that explicitly
        // clears it would fail.
        //
        // Presence check only — matches js-bao's `null || undefined`
        // guard (BaseModel.ts line 844). Empty strings are
        // considered present and pass.
        for (fname, desc) in self.schema.fields where desc.required {
            guard dataToSave[fname] != nil else {
                throw FieldValidationError.requiredFieldMissing(
                    field: fname, modelName: self.schema.name
                )
            }
        }

        // Stringset bounds — mirrors js-bao browser.js:3016-3030.
        // Check BEFORE materializing the nested record map so a
        // failed bounds check doesn't leak a visible partial record
        // (same no-partial-write contract as required-field validation).
        for (fname, desc) in self.schema.fields where desc.type == .stringset {
            guard case let .stringset(members) = dataToSave[fname] else { continue }
            if let limit = desc.maxCount, members.count > limit {
                throw FieldValidationError.stringsetMaxCountExceeded(
                    field: fname, modelName: self.schema.name,
                    limit: limit, got: members.count
                )
            }
            if let limit = desc.maxLength {
                for member in members where member.count > limit {
                    throw FieldValidationError.stringsetMemberTooLong(
                        field: fname, modelName: self.schema.name,
                        limit: limit, member: member
                    )
                }
            }
        }

        // Dirty-check short-circuit — mirrors js-bao `BaseModel.save`,
        // which skips the write entirely when the diff finds no changes
        // ("No changes detected for ${id}, skipping save"). Only applies
        // to the update path: a brand-new record is always written (an
        // insert is, by definition, a change — matching js-bao, whose
        // diff treats every field of a new record as "added"). For an
        // existing record we compare the fully-merged target state
        // (`dataToSave` = old + caller + stamps) against what's already
        // persisted (`oldData`); if they're identical, nothing changed.
        //
        // Composition with auto_stamp: an `update`/`both` stamp was
        // already folded into `dataToSave` above, so it makes the record
        // dirty and the write proceeds — exactly as js-bao, where the
        // pre-transact stamp lands in `_localChanges` before the diff. A
        // pure no-op update of an `auto_stamp = "create"`-only model
        // stays clean (create doesn't fire on update) and is skipped.
        if isUpdate, dataToSave == oldData {
            return
        }

        // Validation passed — now it's safe to materialize the nested
        // record map.
        let rec = existing ?? root.insertMap(tx: txn, key: id)

        // Pre-flight: enforce every resolved unique constraint.
        for constraint in self.schema.resolvedUniqueConstraints {
            guard let newKey = UniqueIndex.buildKey(
                fields: constraint.fields,
                values: dataToSave
            ) else { continue } // null-values → not enforced
            let indexMap = txn.transactionGetOrInsertMap(
                name: UniqueIndex.mapName(
                    modelName: self.schema.name,
                    constraintName: constraint.name
                )
            )
            if let existing = try? indexMap.get(tx: txn, key: newKey),
               let owner = PrimitiveValue.decodeJsonString(existing),
               owner != id {
                throw UniqueConstraintViolationError(
                    modelName: self.schema.name,
                    constraintName: constraint.name,
                    fields: constraint.fields,
                    attemptedRecordId: id,
                    existingRecordId: owner
                )
            }
        }

        // Apply id (only needed on create; idempotent on update).
        rec.insert(tx: txn, key: "id",
                   value: PrimitiveValue.jsonEncodeString(id))

        // Write the requested field changes. (If this is a create we
        // also need to write any defaulted fields from dataToSave that
        // weren't in newValues.)
        var toWrite = newValues
        if !isUpdate {
            for (k, v) in dataToSave where toWrite[k] == nil {
                toWrite[k] = v
            }
        }
        for (fieldName, value) in toWrite where fieldName != "id" {
            self.writeValue(rec, fieldName: fieldName, value: value, tx: txn)
        }

        // Reconcile unique-index entries:
        //   - for each constraint, delete the old key if it changed
        //   - set the new key → this.id
        for constraint in self.schema.resolvedUniqueConstraints {
            let indexMap = txn.transactionGetOrInsertMap(
                name: UniqueIndex.mapName(
                    modelName: self.schema.name,
                    constraintName: constraint.name
                )
            )
            let oldKey = UniqueIndex.buildKey(
                fields: constraint.fields,
                values: oldData
            )
            let newKey = UniqueIndex.buildKey(
                fields: constraint.fields,
                values: dataToSave
            )
            if let oldKey, oldKey != newKey {
                _ = try? indexMap.remove(tx: txn, key: oldKey)
            }
            if let newKey {
                indexMap.insert(
                    tx: txn,
                    key: newKey,
                    value: PrimitiveValue.jsonEncodeString(id)
                )
            }
        }

        // --- SQLite mirror: direct incremental write --------------
        // Keeps the mirror synchronously consistent with the Y.Map
        // after every local write. The root-map observer will ALSO
        // fire asynchronously (same commit → queued re-upsert), but
        // that's idempotent. This direct call is what makes queries
        // immediately after a write see the new state without waiting
        // for the observer queue to drain.
        //
        // For new records we also install the per-record observer
        // here so future field changes reach SQLite via the observer
        // pipeline too.
        if !isUpdate {
            self.installRecordObserverUnlocked(id: id, rootMap: root, tx: txn)
        }
        self.upsertSqliteRow(id: id, rootMap: root, tx: txn)
        // applyWriteInternal always runs inside the write transaction —
        // the notification is queued and delivered by the transaction
        // wrapper after the yrs commit (#1116).
        self.notifyListenersAfterWrite()
    }

    /// Snapshot a record's fields WITHOUT opening a new transaction.
    /// Used during `applyWrite` to read the pre-write state for the
    /// unique-index cleanup.
    private func snapshotFromMap(rec: YrsMap, tx: YrsTransaction) -> [String: PrimitiveValue] {
        var out: [String: PrimitiveValue] = [:]
        for (fieldName, desc) in schema.fields {
            if desc.type == .stringset {
                guard let nested = rec.getMap(tx: tx, key: fieldName) else { continue }
                let collector = KeyCollector()
                nested.keys(tx: tx, delegate: collector)
                out[fieldName] = .stringset(Set(collector.keys))
            } else if let raw = try? rec.get(tx: tx, key: fieldName),
                      let v = PrimitiveValue.decode(yrsString: raw, as: desc.type) {
                out[fieldName] = v
            }
        }
        return out
    }

    /// Iterate every `_uniqueIdx_*` map for this model's resolved
    /// constraints and drop any entries whose value matches the given
    /// record id. Called on delete.
    private func clearUniqueIndexesForRecord(id: String, tx: YrsTransaction) {
        for constraint in schema.resolvedUniqueConstraints {
            let indexMap = tx.transactionGetOrInsertMap(
                name: UniqueIndex.mapName(
                    modelName: schema.name,
                    constraintName: constraint.name
                )
            )
            let collector = KeyCollector()
            indexMap.keys(tx: tx, delegate: collector)
            for key in collector.keys {
                if let raw = try? indexMap.get(tx: tx, key: key),
                   PrimitiveValue.decodeJsonString(raw) == id {
                    _ = try? indexMap.remove(tx: tx, key: key)
                }
            }
        }
    }

    // MARK: - Record-backed accessors (used from PrimitiveRecord subscript)

    internal func readField(recordId: String, field: String) -> PrimitiveValue? {
        // Stringsets live in a nested Y.Map, not as a scalar; the raw
        // `rec.get(field)` call errors for non-Any values, so we route
        // stringsets through their own nested-map read path first.
        if schema.fields[field]?.type == .stringset {
            return readStringSet(recordId: recordId, field: field)
        }
        guard let raw = readRaw(recordId: recordId, field: field) else {
            // Schema says stringset-less, but the value might still be a
            // nested Y.Map (e.g. schema drift). Try the nested path as a
            // fallback so readers of drifted docs degrade gracefully.
            if schema.fields[field] == nil,
               let v = readStringSet(recordId: recordId, field: field) {
                return v
            }
            return nil
        }
        // If the schema knows the type, decode using it.
        if let type = schema.fields[field]?.type {
            return PrimitiveValue.decode(yrsString: raw, as: type)
        }
        // Otherwise, best-effort inference.
        return inferValue(fromRaw: raw)
    }

    /// Read a stringset field by iterating its nested Y.Map. Returns nil
    /// if the field doesn't exist OR isn't a Y.Map.
    private func readStringSet(recordId: String, field: String) -> PrimitiveValue? {
        return withTx { [self] txn in
            guard let root = txn.transactionGetMap(name: self.schema.name),
                  let rec  = root.getMap(tx: txn, key: recordId),
                  let nested = rec.getMap(tx: txn, key: field) else { return nil }
            let collector = KeyCollector()
            nested.keys(tx: txn, delegate: collector)
            return .stringset(Set(collector.keys))
        }
    }

    internal func readRaw(recordId: String, field: String) -> String? {
        return withTx { [self] txn in
            guard let root = txn.transactionGetMap(name: self.schema.name),
                  let rec  = root.getMap(tx: txn, key: recordId) else { return nil }
            return try? rec.get(tx: txn, key: field)
        }
    }

    internal func writeField(recordId: String, field: String, value: PrimitiveValue) {
        withTx { [self] txn in
            guard let root = txn.transactionGetMap(name: self.schema.name) else { return }
            let rec = root.getOrInsertMap(tx: txn, key: recordId)
            self.writeValue(rec, fieldName: field, value: value, tx: txn)
        }
    }

    internal func clearField(recordId: String, field: String) {
        withTx { [self] txn in
            guard let root = txn.transactionGetMap(name: self.schema.name),
                  let rec  = root.getMap(tx: txn, key: recordId) else { return }
            _ = try? rec.remove(tx: txn, key: field)
        }
    }

    internal func fieldNames(recordId: String) -> Set<String> {
        return withTx { [self] txn in
            guard let root = txn.transactionGetMap(name: self.schema.name),
                  let rec  = root.getMap(tx: txn, key: recordId) else { return [] }
            let collector = KeyCollector()
            rec.keys(tx: txn, delegate: collector)
            return Set(collector.keys)
        }
    }

    internal func snapshot(recordId: String) -> [String: PrimitiveValue] {
        var out: [String: PrimitiveValue] = [:]
        for (fieldName, _) in schema.fields {
            // Route through `readField` so the stringset nested-map path
            // and the scalar decode path are both covered.
            if let v = readField(recordId: recordId, field: fieldName) {
                out[fieldName] = v
            }
        }
        return out
    }

    // MARK: - Internals

    private func writeValue(
        _ rec: YrsMap,
        fieldName: String,
        value: PrimitiveValue,
        tx: YrsTransaction
    ) {
        if case let .stringset(items) = value {
            // Per-member layout: each member is a key in the nested
            // Y.Map with value `true`. Mirrors js-bao's wire format
            // (browser.ts `setStringSet`).
            //
            // Full-set assignment is a DIFF against the locally-known
            // members, not a wholesale map replacement — mirrors
            // js-bao's `applyStringSetChangeToYMap` (BaseModel.ts),
            // which only `target.set(member, true)`s additions and
            // `target.delete(member)`s removals on the *existing*
            // nested Y.Map. Keeping the same Y.Map instance alive is
            // what preserves CRDT union semantics: a concurrent
            // offline add from another client targets this map, so it
            // survives a full-set assignment that doesn't know about
            // it. Replacing the map (the previous behavior) orphaned
            // those concurrent inserts and they were lost on merge
            // (#1114).
            if let nested = rec.getMap(tx: tx, key: fieldName) {
                let collector = KeyCollector()
                nested.keys(tx: tx, delegate: collector)
                let existing = Set(collector.keys)
                for member in items.subtracting(existing) {
                    nested.insert(tx: tx, key: member, value: "true")
                }
                for member in existing.subtracting(items) {
                    _ = try? nested.remove(tx: tx, key: member)
                }
            } else {
                // No nested map yet (fresh field, or a legacy scalar
                // value that getMap can't see) — clear any scalar and
                // materialize the map with the full member set.
                _ = try? rec.remove(tx: tx, key: fieldName)
                let nested = rec.insertMap(tx: tx, key: fieldName)
                for item in items {
                    nested.insert(tx: tx, key: item, value: "true")
                }
            }
            return
        }
        if let encoded = value.encodedForYrs() {
            rec.insert(tx: tx, key: fieldName, value: encoded)
        }
    }

    private func materializeDefault(_ def: DefaultValue) -> PrimitiveValue? {
        switch def {
        case let .scalar(v):
            return v
        case let .function(name):
            return PrimitiveSchemaRegistry.shared.resolve(name)?()
        }
    }

    /// Schema-less inference for an unknown field's raw value. Mirrors
    /// `SchemaDiscovery.inferTypeFromValue` but decodes into a
    /// `PrimitiveValue` directly.
    private func inferValue(fromRaw raw: String) -> PrimitiveValue? {
        if raw == "true"  { return .boolean(true)  }
        if raw == "false" { return .boolean(false) }
        if let n = Double(raw) { return .number(n) }
        if let s = PrimitiveValue.decodeJsonString(raw) { return .string(s) }
        return nil
    }

    // MARK: - Per-record observer installation + SQLite row helpers

    /// Install (or re-install) a per-record observer on the nested
    /// Y.Map for `id`. Caller holds neither observerLock nor any yrs
    /// lock. Safe to call with a held tx.
    internal func installRecordObserverUnlocked(
        id: String,
        rootMap: YrsMap,
        tx: YrsTransaction
    ) {
        guard let rec = rootMap.getMap(tx: tx, key: id) else { return }
        observerLock.lock()
        // Replacing the entry drops the old subscription → auto-cancel
        // via Rust's Drop. No explicit cancel on the raw FFI handle.
        recordSubscriptions[id] = rec.observe(
            delegate: RecordObserver(model: self, recordId: id)
        )
        observerLock.unlock()
    }

    internal func cancelRecordObserverUnlocked(id: String) {
        observerLock.lock()
        // Removing from the dictionary drops the last strong ref,
        // triggering Rust Drop → cancels the subscription.
        recordSubscriptions.removeValue(forKey: id)
        observerLock.unlock()
    }

    /// Build the SQLite row for a record and upsert it. Uses a held
    /// transaction to read the nested Y.Map (including stringset
    /// nested maps). Does NOT open a new transaction — callers must
    /// provide one.
    internal func upsertSqliteRow(
        id: String,
        rootMap: YrsMap,
        tx: YrsTransaction
    ) {
        guard let rec = rootMap.getMap(tx: tx, key: id) else {
            // Record gone — treat as delete.
            queryEngine.deleteRecord(
                modelName: schema.name, id: id, scopedToDocId: docId,
                stringsetFields: stringsetFieldNames
            )
            return
        }
        // Main-row dict (scalars only). `_meta_doc_id` makes the row
        // addressable under the shared-engine compound PK.
        var row: [String: Any] = ["id": id, "_meta_doc_id": docId]
        // Stringsets routed separately into junction tables.
        var stringsets: [String: [String]] = [:]
        let snap = snapshotFromMap(rec: rec, tx: tx)
        for (name, _) in schema.fields where name != "id" {
            guard let v = snap[name] else { continue }
            if case let .stringset(set) = v {
                stringsets[name] = Array(set)
            } else if let sql = sqliteRepresentation(of: v) {
                row[name] = sql
            }
        }
        queryEngine.upsertRecord(
            modelName: schema.name,
            record: row,
            stringsets: stringsets
        )
    }

    /// Block until the observer-drain queue is empty. Queries call
    /// this before reading so remote-driven async upserts finish
    /// before the SELECT runs. Idempotent; cheap when queue is idle.
    ///
    /// Re-entrancy-safe: when called from this model's own drain
    /// queue (a subscriber callback delivered there that re-enters
    /// `query()`, for example), the `sync` would self-deadlock — and
    /// it's also unnecessary, because the mirror already reflects
    /// every change applied before the current task. We detect that
    /// case via the queue-specific marker and return immediately
    /// (#1116).
    internal func awaitObserverDrain() {
        if DispatchQueue.getSpecific(key: drainQueueKey) == true { return }
        observerDrainQueue.sync {}
    }

    // MARK: - Delegate used for raw key iteration

    internal final class KeyCollector: YrsMapIteratorDelegate {
        var keys: [String] = []
        func call(value: String) { keys.append(value) }
    }
}

// MARK: - Observer delegates

/// Fires on the model's root Y.Map. Values there are nested Y.Maps
/// (one per record), so we only expect `.insertedNested` /
/// `.updatedNested` / `.removedNested` events.
///
/// - `.insertedNested` / `.updatedNested`: dispatch async. The
///   callback can't open a transaction directly (yrs RwLock held
///   during observer fire), so we hop to a serial queue to install
///   the per-record observer and seed the SQLite row.
///
/// - `.removedNested`: synchronously cancel the per-record observer
///   and delete the SQLite row — neither operation needs a tx.
private final class RootMapObserver: YrsMapObservationDelegate {
    weak var model: DynamicModel?
    init(model: DynamicModel) { self.model = model }
    func call(value: [YrsMapChange]) {
        guard let model else { return }
        for event in value {
            switch event.change {
            case .insertedNested, .updatedNested:
                let key = event.key
                model.observerDrainQueue.async { [weak model] in
                    guard let model else { return }
                    model.doc.transactSync { txn in
                        guard let root = txn.transactionGetMap(name: model.modelName)
                                as YrsMap? else { return }
                        model.installRecordObserverUnlocked(
                            id: key, rootMap: root, tx: txn
                        )
                        model.upsertSqliteRow(id: key, rootMap: root, tx: txn)
                    }
                    model.notifyListeners()
                }
            case .removedNested:
                model.cancelRecordObserverUnlocked(id: event.key)
                model.queryEngineInternal.deleteRecord(
                    modelName: model.modelName,
                    id: event.key,
                    scopedToDocId: model.docId,
                    stringsetFields: model.stringsetFieldNames
                )
                // Notify from the drain queue, not from inside yrs's
                // commit hook (where this observer fires with the doc
                // lock held) — a listener that re-enters the model
                // would deadlock against the in-flight commit (#1116).
                model.observerDrainQueue.async { [weak model] in
                    model?.notifyListeners()
                }
            default:
                // Scalar events on the root map are not a normal
                // layout for this schema — ignore.
                break
            }
        }
    }
}

/// Fires on a single record's nested Y.Map. Any field change —
/// scalar or nested (stringset) — dispatches a re-read + upsert.
///
/// We always re-read the full record rather than patching the single
/// column because (a) writing one column still needs INSERT OR
/// REPLACE on the full row (SQLite primary-key semantics), and
/// (b) stringset field changes don't carry the new value in the
/// event, so a re-read is required anyway.
private final class RecordObserver: YrsMapObservationDelegate {
    weak var model: DynamicModel?
    let recordId: String
    init(model: DynamicModel, recordId: String) {
        self.model = model
        self.recordId = recordId
    }
    func call(value: [YrsMapChange]) {
        guard let model else { return }
        let id = recordId
        model.observerDrainQueue.async { [weak model] in
            guard let model else { return }
            model.doc.transactSync { txn in
                guard let root = txn.transactionGetMap(name: model.modelName)
                        as YrsMap? else { return }
                model.upsertSqliteRow(id: id, rootMap: root, tx: txn)
            }
            model.notifyListeners()
        }
    }
}

// MARK: - PrimitiveFieldType ↔ legacy FieldType bridge

internal extension PrimitiveFieldType {
    /// Coerce to the legacy `FieldType` used by `BaoModelQueryEngine` for
    /// SQLite column-type inference. Lossy by design: dates and ids
    /// become TEXT columns; stringset/json become JSON-string columns.
    func toLegacyFieldType() -> FieldType {
        switch self {
        case .number:                     return .number
        case .boolean:                    return .boolean
        case .json, .stringset:           return .json
        case .string, .date, .id:         return .string
        }
    }
}
