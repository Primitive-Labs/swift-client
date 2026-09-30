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
///
/// ## `@unchecked Sendable` — safety argument (#1992, Phase C)
///
/// A class with mutable state, so the conformance is unchecked. Every stored
/// property is either immutable-and-`Sendable` or confined to a named lock:
///
/// | State | Confinement |
/// |---|---|
/// | `schema` (`PrimitiveSchema`) | `let`, `Sendable` value type |
/// | `engine` (`BaoModelQueryEngine`) | `let`; the engine is itself `@unchecked Sendable` under its own `lock` (see its safety argument) |
/// | `members`, `orderedDocIds` | mutated in `connect`/`disconnect` and read via `snapshotMembersInOrder` / `connectedDocIds`, all under `lock` |
/// | `activeSubs` | mutated and read only under the **separate** `subscribeLock` |
///
/// **Two locks with a fixed acquisition order: `lock` → `subscribeLock`.**
/// The nesting is real and one-directional. `connect`/`disconnect` hold `lock`
/// and call `installActiveSubsOn` / `uninstallActiveSubsFrom`, which take
/// `subscribeLock` inside it. Nothing ever takes `lock` while holding
/// `subscribeLock`: `subscribe` snapshots members through
/// `snapshotMembersInOrder()` (which takes and releases `lock`) *before*
/// touching `subscribeLock`, and the unsubscribe closure only touches
/// `subscribeLock`. Since both locks are `NSLock` (non-reentrant), the
/// inner sections also never re-enter their own lock, and callbacks
/// (`model.subscribe`, the collected `unsub` closures) are always invoked
/// with `subscribeLock` released.
///
/// **A third lock is in that order: the member's `listenerLock`.**
/// `installActiveSubsOn` / `uninstallActiveSubsFrom` call
/// `DynamicModel.subscribe` and the collected `unsub` closures, both of which
/// take the member's `listenerLock` — and `connect`/`disconnect` still hold
/// `lock` at that point. So the full order is
/// `lock` → (`subscribeLock` released) → `listenerLock`. Still
/// one-directional: nothing in `DynamicModel` takes a `MultiDocModel` lock,
/// so `listenerLock` is always a leaf here and cannot close a cycle.
///
/// **Concurrent `connect`/`disconnect` while a cross-doc query iterates.**
/// The query methods do not hold `lock` for the duration of the query: they
/// drain observers over a *snapshot* of members and then run one SQL statement
/// against `engine`, whose own lock serializes it against the row
/// inserts/deletes a concurrent `connect`/`disconnect` performs. So a query
/// concurrent with a membership change is not a data race; it returns a page
/// that is consistent per SQL statement and may or may not include the doc
/// being connected/disconnected. That is the same visibility contract a remote
/// change already has, not a new one.
///
/// Listener closures are `@Sendable` (#1992): confining the `activeSubs`
/// dictionary under a lock says nothing about state a callback captures, so
/// the closure type carries the requirement instead.
final class MultiDocModel: IncludeTarget, @unchecked Sendable {
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
        public let row: [String: JSONValue]
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

    public func findAll() -> [[String: JSONValue]] {
        // `nil` filter never carries a substring operator, so the
        // now-throwing `query` can't actually throw here — handle the
        // unreachable error locally to keep `findAll` non-throwing
        // (fixed-shape read, per the #1119 design).
        //
        // #3436 — except while a large document is connected, where `query`
        // refuses because it would answer from the engine alone. There is no
        // filter to push down here, so this read answers COMPLETELY instead:
        // the engine's rows for the ordinary documents, and each large
        // document's rows from its own store. Silently returning the ordinary
        // half is the one thing it must not do.
        let engineRows = (try? queryIgnoringLargeDocuments()) ?? []
        return engineRows + format2Rows()
    }

    /// The engine half of `findAll`, with the large-document refusal skipped
    /// because the caller supplies the other half.
    private func queryIgnoringLargeDocuments() throws -> [[String: JSONValue]] {
        drainAllObservers()
        return try engine.query(
            modelName: schema.name, filter: nil, options: nil,
            stringsetFields: stringsetFieldNames
        )
    }

    /// Find a record by id. First-match-wins in connect order
    /// (matches js-bao). Returns `nil` if no doc has it.
    public func find(id: String) -> Located? {
        // Drain every member's observer queue so an incoming remote
        // update is visible before we read.
        let snapshot = snapshotMembersInOrder()
        for (_, model) in snapshot {
            model.awaitObserverDrain()
        }
        // Prefer one SQL query over iterating Y.Maps — `id` is not
        // unique across docs (that's the whole point), so we sort
        // results by docId in connect order. A bare `id` equality filter
        // can't trigger the substring-op validator, so the now-throwing
        // `engine.query` is unreachable-error here — handle it locally
        // so `find` stays non-throwing.
        // `stringsetFields` is what drives the post-query pass that pulls
        // members out of the per-field junction tables. Without it the
        // returned row simply has no stringset keys — `find` handed back a
        // record `query` would have returned complete (#2485).
        let rows = (try? engine.query(
            modelName: schema.name,
            filter: ["id": .string(id)],
            stringsetFields: stringsetFieldNames
        )) ?? []
        guard !rows.isEmpty else { return format2Located(id: id) }
        let connectOrder = snapshot.enumerated().reduce(
            into: [String: Int]()
        ) { $0[$1.element.docId] = $1.offset }
        let sorted = rows.sorted {
            (connectOrder[$0["_meta_doc_id"]?.stringValue ?? ""] ?? .max) <
            (connectOrder[$1["_meta_doc_id"]?.stringValue ?? ""] ?? .max)
        }
        if let first = sorted.first, let docId = first["_meta_doc_id"]?.stringValue {
            return Located(docId: docId, row: first)
        }
        return format2Located(id: id)
    }

    /// The record in a connected LARGE document, if one holds it (#3436).
    ///
    /// A miss in the shared engine is not an answer while a large document is
    /// open: its rows are not in there. Connect order, first hit wins — the
    /// same rule the engine rows follow.
    ///
    /// Asked of each store BY ID, one keyed read at a time, stopping at the
    /// first hit. Materializing every row to find one is the shape a large
    /// document is least able to afford: at the sizes this format exists for it
    /// turns an ordinary lookup into a full read of the document.
    private func format2Located(id: String) -> Located? {
        for (docId, model) in format2Members() {
            guard let delegate = model.format2,
                  var row = try? delegate.row(id: id) else { continue }
            for field in stringsetFieldNames {
                let members = (try? delegate.members(id: id, field: field)) ?? []
                row[field] = .array(members.map { .string($0) })
            }
            row["_meta_doc_id"] = .string(docId)
            return Located(docId: docId, row: row)
        }
        return nil
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
            var row: [String: JSONValue] = ["id": .string(rec.id)]
            let snap = rec.snapshot()
            for (fname, _) in schema.fields where fname != "id" {
                if let v = snap[fname] {
                    row[fname] = rowRepresentation(of: v)
                }
            }
            // A record with no members has no snapshot entry at all, so give
            // every stringset field the same `[]` the engine's population pass
            // produces — one row shape whether the set is empty or not (#2485).
            for fname in stringsetFieldNames where row[fname] == nil {
                row[fname] = .array([])
            }
            row["_meta_doc_id"] = .string(docId)
            return Located(docId: docId, row: row)
        }
        return nil
    }

    /// Cross-doc "find by constraint OR create" — mirrors js-bao's
    /// `BaseModel.upsertByUnique`, which searches EVERY connected
    /// document for an existing match before deciding insert vs. merge.
    ///
    /// Search: iterate connected docs in connect order; the first doc
    /// whose `_uniqueIdx_*` map holds the constraint key wins (uniqueness
    /// is per-doc, so the same key may exist in more than one open doc —
    /// first-match-wins matches js-bao's `for (docId of connectedDocuments)`
    /// loop with `break`).
    ///
    /// Merge: writes the matched record id through `targetDocId`, mirroring
    /// js-bao's `existingRecord.save({ targetDocument })` path when a target
    /// document is supplied. If the match was found in another open doc, this
    /// preserves JS's explicit-target behavior: the target doc receives the
    /// resolved id, while the original doc is not deleted or moved.
    ///
    /// Insert: writes into `targetDocId`; throws if that doc isn't open.
    ///
    /// - Parameters:
    ///   - uniqueLookupValue: optional explicit lookup value(s) (one per
    ///     constraint field). Mirrors js-bao's separate
    ///     `uniqueLookupValue` argument; validated against `data`.
    ///   - changedFields: the fields the caller actually assigned (see
    ///     `DynamicModel.save(id:values:changedFields:)`). Applies to the
    ///     merge path only; the insert path writes every supplied value.
    @discardableResult
    public func upsertByUnique(
        constraint name: String,
        data: [String: PrimitiveValue],
        mode: UpsertMode = .either,
        id: String? = nil,
        explicitId: Bool = false,
        targetDocId: String,
        uniqueLookupValue: [PrimitiveValue]? = nil,
        changedFields: Set<String>? = nil
    ) throws -> UpsertResult {
        let members = snapshotMembersInOrder()
        for (_, model) in members { model.awaitObserverDrain() }

        // Resolve + validate the lookup key once. Any connected member
        // can do this (they share the schema); fall back to the target
        // doc's member when nothing is connected yet.
        guard let keyResolver = members.first?.model
                ?? member(docId: targetDocId) else {
            throw JsBaoError(
                code: .notFound,
                message: "No document is connected for `\(schema.name)`."
            )
        }
        let (constraint, key) = try keyResolver.resolveUpsertConstraintKey(
            constraint: name, data: data, uniqueLookupValue: uniqueLookupValue
        )

        // Before the search: a match in any doc would otherwise supply the
        // id the caller failed to (see
        // `DynamicModel.requireNonEmptySuppliedId`).
        try DynamicModel.requireNonEmptySuppliedId(
            id, data: data, modelName: schema.name
        )

        // Cross-doc search: first connected doc that holds the key wins.
        // The ordered values travel with the key so a LARGE member can answer
        // from its merged view, which is the only place its uniqueness lives
        // (#3436). `resolveUpsertConstraintKey` has already established that
        // every constraint field is present in `data` and that an explicit
        // lookup value agrees with it field by field.
        let orderedValues = constraint.fields.compactMap { data[$0] }
        var matchRecordId: String?
        for (_, model) in members {
            if let rid = model.existingRecordId(
                constraintName: name, key: key, orderedValues: orderedValues
            ) {
                matchRecordId = rid
                break
            }
        }

        switch mode {
        case .mustExist where matchRecordId == nil:
            throw UpsertByUniqueError.recordNotFound(constraint: name)
        case .mustNotExist where matchRecordId != nil:
            throw UniqueConstraintViolationError(
                modelName: schema.name,
                constraintName: name,
                fields: constraint.fields,
                attemptedRecordId: id ?? "(auto)",
                existingRecordId: matchRecordId!
            )
        default:
            break
        }

        if let matchRecordId {
            // Explicit-id conflict: caller pinned a specific id that
            // disagrees with the matched record. Mirrors js-bao's
            // `_constructorProvidedId && this.id !== existingId` guard
            // (here surfaced via `upsertByUnique`'s explicit-id path).
            if explicitId, let supplied = id, supplied != matchRecordId {
                throw UpsertError.explicitIdConflict(
                    supplied: supplied, existing: matchRecordId
                )
            }
            guard let target = member(docId: targetDocId) else {
                throw JsBaoError(
                    code: .notFound,
                    message: "Document `\(targetDocId)` is not open. Open it " +
                             "(client.openDocument) before writing `\(schema.name)` records."
                )
            }
            _ = try target.save(
                id: matchRecordId, values: data, changedFields: changedFields
            )
            return UpsertResult(
                record: PrimitiveRecord(
                    modelName: schema.name, id: matchRecordId, model: target
                ),
                wasCreated: false
            )
        }

        // Insert into the target doc.
        guard let target = member(docId: targetDocId) else {
            throw JsBaoError(
                code: .notFound,
                message: "Document `\(targetDocId)` is not open. Open it " +
                         "(client.openDocument) before writing `\(schema.name)` records."
            )
        }
        return try target.insertNew(id: id, data: data)
    }


    // MARK: - Large documents (#3436)

    /// The connected members whose document is a large one, in connect order.
    ///
    /// Their records are in the documents' own stores, not in this
    /// aggregator's shared engine — the file-backed projection that will put
    /// them there is behavior 13 — so every read below has to say what it does
    /// about them rather than quietly answer without them.
    private func format2Members() -> [(docId: String, model: DynamicModel)] {
        snapshotMembersInOrder().filter { $0.1.format2 != nil }
            .map { (docId: $0.0, model: $0.1) }
    }

    /// The refusal a filtered read gives when this model has members of BOTH
    /// kinds (#3436, behavior 12, mirroring #3430's Decision R by name).
    ///
    /// An ordinary document's rows are in the in-memory mirror and a large
    /// document's are in the file-backed query tables. One SQL statement
    /// cannot span two databases, and merging two result sets in Swift would
    /// mean a second implementation of sort, limit and cursor — so the read
    /// says it cannot answer rather than answering from one of them. Scoping
    /// the read to documents of one kind makes it answerable again.
    private func format2QueryScope(
        _ large: [String], _ ordinary: [String]
    ) -> JsBaoError {
        JsBaoError(
            code: .format2QueryScope,
            message: "`\(schema.name)` cannot answer one filtered read across both "
                + "large document(s) \(large.joined(separator: ", ")) and ordinary "
                + "document(s) \(ordinary.joined(separator: ", ")): their rows are in "
                + "different query stores. Scope the read to documents of one kind "
                + "(`QueryOptions.documents`), or use `findAll()` / `find(id:)`, which "
                + "read both.",
            details: [
                "model": .string(schema.name),
                "largeDocuments": .array(large.map { .string($0) }),
                "documents": .array(ordinary.map { .string($0) }),
            ]
        )
    }

    /// Which engine answers a filtered read, or the refusal.
    ///
    /// - `nil` — the shared in-memory mirror, which is every client with no
    ///   large document open and is the unchanged path.
    /// - a projection and a scope — every connected member is large, so the
    ///   read runs on the file-backed tables restricted to those documents.
    /// - a throw — members of both kinds, which one statement cannot span.
    ///
    /// Decided against the documents the read ASKED for, not against everything
    /// connected: a read scoped to one kind is answerable however many
    /// documents of the other kind happen to be open, which is what the
    /// refusal's own message tells the caller to do. The scope handed back is
    /// the requested one narrowed to this model's large members — never "every
    /// large document", which would answer a one-document read from two.
    private func format2Route(
        _ options: QueryOptions?
    ) throws -> (Format2QueryProjection, [String])? {
        let requested = options?.documents
        let members = snapshotMembersInOrder()
            .filter { requested?.contains($0.0) ?? true }
        let large = members.filter { $0.1.format2 != nil }
            .map { (docId: $0.0, model: $0.1) }
        guard !large.isEmpty else { return nil }
        let ordinary = members.filter { $0.1.format2 == nil }.map(\.0)
        guard ordinary.isEmpty else {
            throw format2QueryScope(large.map(\.docId), ordinary)
        }
        guard let projection = large.first?.model.format2?.binding.projection else {
            return nil
        }
        // Every one of them has to be projected, not just reachable: a
        // document whose projection did not commit has no rows in these
        // tables, and a read that ran anyway would answer short and say
        // nothing. The per-document facade refuses for the same reason.
        for (_, model) in large {
            guard let delegate = model.format2 else { continue }
            delegate.binding.settleFolds()
            try delegate.requireProjection()
        }
        return (projection, large.map(\.docId))
    }

    /// Every row a large document's member holds, in the shape the engine's
    /// rows use — `_meta_doc_id` tag included, stringsets as arrays.
    private func format2Rows() -> [[String: JSONValue]] {
        var out: [[String: JSONValue]] = []
        for (docId, model) in format2Members() {
            guard let delegate = model.format2,
                  let ids = try? delegate.allIds() else { continue }
            for id in ids {
                guard var row = try? delegate.row(id: id) else { continue }
                for field in stringsetFieldNames {
                    let members = (try? delegate.members(id: id, field: field)) ?? []
                    row[field] = .array(members.map { .string($0) })
                }
                row["_meta_doc_id"] = .string(docId)
                out.append(row)
            }
        }
        return out
    }

    /// Cross-doc query. Filter, sort, limit, offset, and cursor all
    /// execute in a single SQL query against the shared table — no
    /// fan-out or Swift-side merging.
    public func query(
        _ filter: DocumentFilter? = nil,
        options: QueryOptions? = nil
    ) throws -> [[String: JSONValue]] {
        if let (projection, scope) = try format2Route(options) {
            return try projection.engine.query(
                modelName: schema.name, filter: filter,
                options: Format2ModelDelegate.scoped(options, to: scope),
                stringsetFields: stringsetFieldNames
            )
        }
        drainAllObservers()
        return try engine.query(
            modelName: schema.name, filter: filter, options: options,
            stringsetFields: stringsetFieldNames
        )
    }

    public func count(_ filter: DocumentFilter? = nil) throws -> Int {
        try count(filter, options: nil)
    }

    /// Count variant that accepts `QueryOptions` — used when callers
    /// want the `documents` scoping shortcut (or future options) on a
    /// count call. `sort`/`limit`/`cursor` on the options are ignored
    /// since they don't apply to a count.
    public func count(
        _ filter: DocumentFilter? = nil,
        options: QueryOptions?
    ) throws -> Int {
        if let (projection, scope) = try format2Route(options) {
            return try projection.engine.count(
                modelName: schema.name, filter: filter,
                stringsetFields: stringsetFieldNames,
                documents: scope
            )
        }
        drainAllObservers()
        return try engine.count(
            modelName: schema.name, filter: filter,
            stringsetFields: stringsetFieldNames,
            documents: options?.documents
        )
    }

    /// Cross-doc aggregation. Runs one SQL query against the shared
    /// table. Group by `_meta_doc_id` to get per-doc rollups; omit
    /// grouping for a single global rollup.
    public func aggregate(_ options: AggregateOptions) throws -> [[String: JSONValue]] {
        // Routed on the documents the caller ASKED for (#3760), exactly as
        // `query` and `count` are: a read scoped to one kind is answerable
        // however many documents of the other kind happen to be open, and a
        // read that names an ordinary document beside a large one is the mix
        // no single statement can serve.
        //
        // `scope` is that request narrowed to this model's CONNECTED large
        // members, and the engine intersects it with `options.documents` — so a
        // request naming a document this model no longer holds answers nothing
        // from it, which is what `query` answers for the same request. The query
        // tables keep a closed document's rows (#3756), so the narrowing is what
        // stands between the two reads agreeing and not.
        let requested = QueryOptions(documents: options.documents)
        if let (projection, scope) = try format2Route(requested) {
            return try projection.engine.aggregate(
                modelName: schema.name, options: options,
                stringsetFields: stringsetFieldNames, documents: scope
            )
        }
        drainAllObservers()
        return try engine.aggregate(
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
        let callback: @Sendable () -> Void
        var unsubByDocId: [String: @Sendable () -> Void]
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
    public func subscribe(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = UUID()
        // Pre-install on currently-connected members BEFORE taking
        // `subscribeLock` — member access goes through the main `lock` via
        // `snapshotMembersInOrder`, and taking `lock` while holding
        // `subscribeLock` would invert the one-directional
        // `lock` → `subscribeLock` order the type's safety argument relies
        // on. Then record the active sub.
        var unsubByDocId: [String: @Sendable () -> Void] = [:]
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
    /// registered, so the caller still holds the main `lock` — this is
    /// the `lock` → `subscribeLock` nesting the type's safety argument
    /// describes. We take `subscribeLock` only to snapshot the
    /// active-sub set and release it before invoking `model.subscribe`
    /// (which takes the model's own listener lock); the main `lock`
    /// stays held throughout, which is fine because nothing on that
    /// path tries to reacquire it.
    private func installActiveSubsOn(model: DynamicModel, docId: String) {
        subscribeLock.lock()
        let callbacks = activeSubs.map { (id: $0.key, callback: $0.value.callback) }
        subscribeLock.unlock()
        // `model.subscribe` is safe to call without our locks held.
        var newUnsubs: [(UUID, @Sendable () -> Void)] = []
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
        var toFire: [@Sendable () -> Void] = []
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
    ) throws -> [[String: JSONValue]] {
        // #3436 — the base query routes exactly as the plain one does; a large
        // document's rows are in the file-backed tables and are not in this
        // engine at all. The include resolution that follows is unchanged: it
        // runs against the rows the base query produced, whichever engine
        // answered it.
        if let (projection, scope) = try format2Route(options) {
            var rows = try projection.engine.query(
                modelName: schema.name, filter: filter,
                options: Format2ModelDelegate.scoped(options, to: scope),
                stringsetFields: stringsetFieldNames
            )
            try IncludeResolver.resolve(rows: &rows, includes: include, depth: 0)
            return rows
        }
        drainAllObservers()
        var rows = try engine.query(
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
    ) throws -> PagedQueryResult<PrimitiveRow> {
        // #3436 — routed like every other filtered read. A page answered from
        // the in-memory mirror while a large document is connected would be a
        // page of the ordinary documents only, and its cursor would walk them
        // alone.
        if let (projection, scope) = try format2Route(options) {
            return try projection.engine.queryPaged(
                modelName: schema.name, filter: filter,
                options: Format2ModelDelegate.scoped(options, to: scope),
                stringsetFields: stringsetFieldNames
            )
        }
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
    ) throws -> PagedQueryResult<PrimitiveRow> {
        let base: PagedQueryResult<PrimitiveRow>
        if let (projection, scope) = try format2Route(options) {
            base = try projection.engine.queryPaged(
                modelName: schema.name, filter: filter,
                options: Format2ModelDelegate.scoped(options, to: scope),
                stringsetFields: stringsetFieldNames
            )
        } else {
            drainAllObservers()
            base = try engine.queryPaged(
                modelName: schema.name, filter: filter, options: options,
                stringsetFields: stringsetFieldNames
            )
        }
        // Unwrap → resolve includes (in-place mutation) → rewrap (#1992).
        var rows = base.data.map(\.raw)
        try IncludeResolver.resolve(rows: &rows, includes: include, depth: 0)
        return PagedQueryResult(
            data: rows.map(PrimitiveRow.init(raw:)),
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

    /// `PrimitiveValue` → the value a query row carries for that field.
    ///
    /// Matches what `BaoModelQueryEngine` emits, so a row built here (only
    /// `findByUnique` does) decodes through the same accessors as one that
    /// came out of a SQL query. In particular a stringset is `[String]`, the
    /// shape the engine's junction-table population pass writes and the
    /// generated row decoder casts to — a comma-joined `String` would fail
    /// that cast and silently drop the field (#2485).
    private func rowRepresentation(of value: PrimitiveValue) -> JSONValue {
        switch value {
        case let .string(s):    return .string(s)
        case let .number(n):    return .number(n)
        case let .boolean(b):   return .bool(b)
        case let .id(s):        return .string(s)
        case let .date(s):      return .string(s)
        case let .stringset(s): return .array(Array(s).map { .string($0) })
        case let .json(d):      return .string(String(data: d, encoding: .utf8) ?? "")
        }
    }
}
