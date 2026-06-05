import Foundation
import YSwift

/// Cross-doc query layer for a model whose records live in multiple
/// `YDocument`s. Mirrors js-bao's `BaseModel.dbInstance` design: one
/// shared SQLite mirror owned by `MultiDocModel`, every per-doc
/// `DynamicModel` writes into it tagged with `_meta_doc_id = docId`.
/// Cross-doc reads (`findAll`, `query`, `count`, `aggregate`) run as a
/// single SQL query against the shared table.
///
/// ## Writes
/// Writes go through the per-doc `DynamicModel` returned by
/// `connect(docId:doc:)`. Each doc still owns its own Y.Map record
/// tree, its own `_uniqueIdx_*` enforcement, and its own per-record
/// observers — uniqueness is per-doc (matches js-bao).
///
/// ## Reads
/// Reads span every connected doc in one SQL query. Rows carry
/// `_meta_doc_id` so callers can route follow-up ops to the
/// originating doc's `DynamicModel` (available via
/// `member(docId:)`).
///
/// ## Disconnect semantics
/// `disconnect(docId:)` drops the doc's rows from the shared SQLite
/// table immediately, so subsequent cross-doc queries don't return
/// stale state. The underlying `YDocument` is not touched — re-
/// connecting it will seed its rows back into the table.
/// Internal plumbing — the shared cross-document store behind the codegen'd
/// `Model.*` facade. App code never references this type; it reaches the
/// store through `JsBaoClient.queryShared`/`saveShared`/etc. (and the
/// generated facade methods that call them).
final class MultiDocModel: IncludeTarget {
    public let schema: PrimitiveSchema

    /// Satisfies `IncludeTarget` — derived from the schema so
    /// `Include(target:)` can default `resultKey` to the model name.
    public var modelName: String { schema.name }

    /// Single shared SQLite mirror. Table has `_meta_doc_id` column
    /// with compound `(_meta_doc_id, id)` primary key.
    private let engine: BaoModelQueryEngine

    private var members: [String: DynamicModel] = [:]
    /// Preserves connect-order for deterministic iteration in
    /// `find` / `findByUnique` (first-match-wins matches js-bao).
    private var orderedDocIds: [String] = []
    private let lock = NSLock()

    /// Result of a per-doc lookup. `docId` tells the caller which
    /// doc holds the match so follow-up writes can target the right
    /// `DynamicModel`.
    public struct Located {
        public let docId: String
        public let row: [String: Any]
    }

    public init(
        schema: PrimitiveSchema,
        initialMembers: [(docId: String, doc: YDocument)] = []
    ) {
        self.schema = schema
        self.engine = BaoModelQueryEngine()
        // Seed the shared table up-front — each per-doc DynamicModel
        // would ensure the same table, but doing it here means we
        // have a table the moment `MultiDocModel` exists (useful for
        // tests that don't connect anyone).
        let fields = schema.fields.map {
            (name: $0.key, type: $0.value.type.toLegacyFieldType())
        }
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
        for m in initialMembers {
            _ = connectInternal(docId: m.docId, doc: m.doc)
        }
    }

    // MARK: - Connect / disconnect

    /// Attach a `YDocument` under `docId` and return the per-doc
    /// `DynamicModel`. The returned model writes into this
    /// aggregator's shared engine, tagged with `docId`. Re-connecting
    /// the same `docId` replaces the prior member.
    @discardableResult
    public func connect(docId: String, doc: YDocument) -> DynamicModel {
        lock.lock()
        defer { lock.unlock() }
        return connectInternal(docId: docId, doc: doc)
    }

    public func disconnect(docId: String) {
        lock.lock()
        defer { lock.unlock() }
        disconnectInternal(docId: docId)
    }

    /// The `DynamicModel` for a given doc — use it for writes, or to
    /// drive the row returned by `find` / `findByUnique` back to the
    /// correct doc.
    public func member(docId: String) -> DynamicModel? {
        lock.lock()
        defer { lock.unlock() }
        return members[docId]
    }

    public var connectedDocIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return orderedDocIds
    }

    private func connectInternal(docId: String, doc: YDocument) -> DynamicModel {
        if members[docId] != nil {
            disconnectInternal(docId: docId)
        }
        let model = DynamicModel(
            doc: doc, schema: schema,
            docId: docId, sharedEngine: engine
        )
        members[docId] = model
        orderedDocIds.append(docId)
        // Install any subscribers that were registered before this
        // doc was connected. Safe to call here — `installActiveSubsOn`
        // releases our lock before touching model.listenerLock.
        installActiveSubsOn(model: model, docId: docId)
        return model
    }

    private func disconnectInternal(docId: String) {
        guard members.removeValue(forKey: docId) != nil else { return }
        orderedDocIds.removeAll { $0 == docId }
        // Drop per-member subscriber hooks. The DynamicModel's own
        // listener map would also clear when it deinits, but this
        // keeps our `activeSubs` state tidy so a later top-level
        // unsubscribe only tears down live hooks.
        uninstallActiveSubsFrom(docId: docId)
        // Drop the doc's rows from the shared table so subsequent
        // cross-doc reads don't see stale state. We go through
        // `rawQuery` because the engine's public API doesn't expose a
        // "delete by docId" primitive — safe since both inputs are
        // sanitized/bound.
        let tableName = schema.name
        _ = engine.rawQuery(
            "DELETE FROM \"\(tableName)\" WHERE \"_meta_doc_id\" = ?",
            params: [docId]
        )
        // Also sweep any junction-table rows the doc contributed.
        engine.deleteAllStringsetRows(
            modelName: tableName,
            scopedToDocId: docId,
            stringsetFields: stringsetFieldNames
        )
    }

    // MARK: - Reads

    public func findAll() -> [[String: Any]] {
        return query(nil, options: nil)
    }

    /// Find a record by id. First-match-wins in connect order
    /// (matches js-bao). Returns `nil` if no doc has it.
    public func find(id: String) -> Located? {
        // Drain every member's observer queue so an incoming remote
        // update is visible before we read.
        let snapshot = snapshotMembersInOrder()
        for (docId, model) in snapshot {
            model.awaitObserverDrain()
        }
        // Prefer one SQL query over iterating Y.Maps — `id` is not
        // unique across docs (that's the whole point), so we sort
        // results by docId in connect order.
        let rows = engine.query(
            modelName: schema.name,
            filter: ["id": id]
        )
        guard !rows.isEmpty else { return nil }
        let connectOrder = snapshot.enumerated().reduce(
            into: [String: Int]()
        ) { $0[$1.element.docId] = $1.offset }
        let sorted = rows.sorted {
            (connectOrder[$0["_meta_doc_id"] as? String ?? ""] ?? .max) <
            (connectOrder[$1["_meta_doc_id"] as? String ?? ""] ?? .max)
        }
        guard let first = sorted.first,
              let docId = first["_meta_doc_id"] as? String else { return nil }
        return Located(docId: docId, row: first)
    }

    /// Find by a unique constraint across connected docs. Iterates in
    /// connect order; first hit wins. Uniqueness is per-doc so cross-
    /// doc collisions are allowed — matches js-bao's behavior.
    public func findByUnique(
        constraint name: String,
        value: PrimitiveValue
    ) throws -> Located? {
        try findByUnique(constraint: name, values: [value])
    }

    public func findByUnique(
        constraint name: String,
        values: [PrimitiveValue]
    ) throws -> Located? {
        for (docId, model) in snapshotMembersInOrder() {
            guard let rec = try model.findByUnique(
                constraint: name, values: values
            ) else { continue }
            var row: [String: Any] = ["id": rec.id]
            let snap = rec.snapshot()
            for (fname, _) in schema.fields where fname != "id" {
                if let v = snap[fname] {
                    row[fname] = sqliteRepresentation(of: v)
                }
            }
            row["_meta_doc_id"] = docId
            return Located(docId: docId, row: row)
        }
        return nil
    }

    /// Cross-doc query. Filter, sort, limit, offset, and cursor all
    /// execute in a single SQL query against the shared table — no
    /// fan-out or Swift-side merging.
    public func query(
        _ filter: DocumentFilter? = nil,
        options: QueryOptions? = nil
    ) -> [[String: Any]] {
        drainAllObservers()
        return engine.query(
            modelName: schema.name, filter: filter, options: options,
            stringsetFields: stringsetFieldNames
        )
    }

    public func count(_ filter: DocumentFilter? = nil) -> Int {
        drainAllObservers()
        return engine.count(
            modelName: schema.name, filter: filter,
            stringsetFields: stringsetFieldNames
        )
    }

    /// Count variant that accepts `QueryOptions` — used when callers
    /// want the `documents` scoping shortcut (or future options) on a
    /// count call. `sort`/`limit`/`cursor` on the options are ignored
    /// since they don't apply to a count.
    public func count(
        _ filter: DocumentFilter? = nil,
        options: QueryOptions?
    ) -> Int {
        drainAllObservers()
        return engine.count(
            modelName: schema.name, filter: filter,
            stringsetFields: stringsetFieldNames,
            documents: options?.documents
        )
    }

    /// Cross-doc aggregation. Runs one SQL query against the shared
    /// table. Group by `_meta_doc_id` to get per-doc rollups; omit
    /// grouping for a single global rollup.
    public func aggregate(_ options: AggregateOptions) -> [[String: Any]] {
        drainAllObservers()
        return engine.aggregate(
            modelName: schema.name, options: options,
            stringsetFields: stringsetFieldNames
        )
    }

    /// Names of fields whose SQLite column stores a comma-joined
    /// stringset. See `DynamicModel.stringsetFieldNames`.
    private var stringsetFieldNames: Set<String> {
        Set(schema.fields.compactMap { $0.value.type == .stringset ? $0.key : nil })
    }

    // MARK: - Aggregate-level subscribe

    /// One registered listener. `callback` is kept so we can install
    /// it on future `connect`s; `unsubByDocId` tracks the per-member
    /// unsubscribe closures so `disconnect` can tear down that
    /// doc's hook and the top-level unsubscribe can tear down every
    /// hook at once.
    private struct ActiveSub {
        let callback: () -> Void
        var unsubByDocId: [String: () -> Void]
    }
    private var activeSubs: [UUID: ActiveSub] = [:]
    private let subscribeLock = NSLock()

    /// Register a callback that fires on any change in any connected
    /// doc's model. Works whether called before or after `connect`:
    /// already-connected members get the callback installed
    /// immediately; later `connect` calls automatically install it
    /// on the new member; `disconnect` tears down the per-doc hook.
    /// Matches `DynamicModel.subscribe` semantics (js-bao browser.js:3628).
    @discardableResult
    public func subscribe(_ callback: @escaping () -> Void) -> () -> Void {
        let id = UUID()
        // Pre-install on currently-connected members OUTSIDE
        // subscribeLock so we don't nest locks (members access goes
        // through the main `lock` via snapshotMembersInOrder). Then
        // record the active sub.
        var unsubByDocId: [String: () -> Void] = [:]
        for (docId, model) in snapshotMembersInOrder() {
            unsubByDocId[docId] = model.subscribe(callback)
        }
        subscribeLock.lock()
        activeSubs[id] = ActiveSub(callback: callback, unsubByDocId: unsubByDocId)
        subscribeLock.unlock()

        return { [weak self] in
            guard let self else { return }
            self.subscribeLock.lock()
            let removed = self.activeSubs.removeValue(forKey: id)
            self.subscribeLock.unlock()
            for (_, unsub) in removed?.unsubByDocId ?? [:] { unsub() }
        }
    }

    /// Install every active subscriber onto a freshly-connected
    /// member. Called from `connectInternal` after the member is
    /// registered. Caller holds the main `lock`; we take
    /// `subscribeLock` to snapshot the active-sub set, release both
    /// before invoking `model.subscribe` (which takes the model's
    /// own listener lock).
    private func installActiveSubsOn(model: DynamicModel, docId: String) {
        subscribeLock.lock()
        let callbacks = activeSubs.map { (id: $0.key, callback: $0.value.callback) }
        subscribeLock.unlock()
        // `model.subscribe` is safe to call without our locks held.
        var newUnsubs: [(UUID, () -> Void)] = []
        for entry in callbacks {
            let unsub = model.subscribe(entry.callback)
            newUnsubs.append((entry.id, unsub))
        }
        subscribeLock.lock()
        for (id, unsub) in newUnsubs {
            activeSubs[id]?.unsubByDocId[docId] = unsub
        }
        subscribeLock.unlock()
    }

    /// Tear down every active subscriber's per-member hook on the
    /// doc being disconnected. The member's own listener map will
    /// also clear when it deinits, but we remove the unsub closures
    /// from `activeSubs` so a later top-level unsubscribe doesn't
    /// chase stale references.
    private func uninstallActiveSubsFrom(docId: String) {
        subscribeLock.lock()
        var toFire: [() -> Void] = []
        for (id, var sub) in activeSubs {
            if let unsub = sub.unsubByDocId.removeValue(forKey: docId) {
                toFire.append(unsub)
                activeSubs[id] = sub
            }
        }
        subscribeLock.unlock()
        for unsub in toFire { unsub() }
    }

    /// Batch-prefetch variant. Runs the cross-doc base query, then
    /// for each include spec does ONE batched lookup on the target
    /// (which may itself be a `MultiDocModel`, so related records can
    /// live in yet another set of docs). Same contract as
    /// `DynamicModel.query(_:options:include:)`.
    public func query(
        _ filter: DocumentFilter? = nil,
        options: QueryOptions? = nil,
        include: [Include]
    ) throws -> [[String: Any]] {
        drainAllObservers()
        var rows = engine.query(
            modelName: schema.name, filter: filter, options: options,
            stringsetFields: stringsetFieldNames
        )
        try IncludeResolver.resolve(rows: &rows, includes: include, depth: 0)
        return rows
    }

    /// Cursor-based paginated query across every connected doc. Same
    /// contract as `DynamicModel.queryPaged` — returns a page's rows
    /// plus opaque next/prev cursors. Cursors encode the sort state
    /// against the shared table, so round-tripping them walks through
    /// the union of every doc's records in one SQL query per page.
    public func queryPaged(
        _ filter: DocumentFilter? = nil,
        options: QueryOptions? = nil
    ) throws -> PagedQueryResult<[String: Any]> {
        drainAllObservers()
        return try engine.queryPaged(
            modelName: schema.name, filter: filter, options: options,
            stringsetFields: stringsetFieldNames
        )
    }

    /// Paginated + include variant. Applies the include resolver to
    /// each page's rows.
    public func queryPaged(
        _ filter: DocumentFilter? = nil,
        options: QueryOptions? = nil,
        include: [Include]
    ) throws -> PagedQueryResult<[String: Any]> {
        drainAllObservers()
        let base = try engine.queryPaged(
            modelName: schema.name, filter: filter, options: options,
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

    // MARK: - Internals

    private func snapshotMembersInOrder() -> [(docId: String, model: DynamicModel)] {
        lock.lock()
        defer { lock.unlock() }
        return orderedDocIds.compactMap { id in
            members[id].map { (docId: id, model: $0) }
        }
    }

    private func drainAllObservers() {
        for (_, model) in snapshotMembersInOrder() {
            model.awaitObserverDrain()
        }
    }

    /// `PrimitiveValue → SQLite-bind-friendly Any`.
    private func sqliteRepresentation(of value: PrimitiveValue) -> Any {
        switch value {
        case let .string(s):    return s
        case let .number(n):    return n
        case let .boolean(b):   return b
        case let .id(s):        return s
        case let .date(s):      return s
        case let .stringset(s): return Array(s).joined(separator: ",")
        case let .json(d):      return String(data: d, encoding: .utf8) ?? ""
        }
    }
}
