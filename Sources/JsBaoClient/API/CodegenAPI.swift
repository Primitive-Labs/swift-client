import Foundation

/// The surface `swift-bao-codegen`'s generated models call into — the
/// cross-document shared store, schema-and-dictionary shaped rather than
/// generic, so the generated per-type facade does the typed mapping.
///
/// **App code does not call this.** Use the generated `Model.query(...)` /
/// `Model.find(...)` / `save(in:)` facade instead; it is typed, and it calls
/// through here for you. This exists as its own namespace (`client.codegen`)
/// so ~20 codegen-backing entry points stay out of `client.`'s autocomplete
/// without hiding them from the generated code that needs them.
///
/// ## Why a facade rather than `@_spi(Codegen)` (#2367)
///
/// SPI narrows *discoverability*, not access, and — decisively — it is not
/// re-exported through `@_exported import JsBaoClient`. `PrimitiveApp`
/// re-exports the client that way, so under SPI every scaffolded app's
/// generated models would need their own `@_spi(Codegen) import JsBaoClient`,
/// and any hand-written app code that touched one of these would fail with
/// "cannot find in scope" rather than something a reader can act on. A plain
/// namespace has neither problem.
///
/// Reads span every open document by default; pass `options.documents` to
/// scope them. Writes target one document and throw if it isn't open.
public final class CodegenAPI: @unchecked Sendable {
    /// The owning client, held **weakly**: a strong reference would be a
    /// retain cycle, and `unowned` would trap. `client.codegen` is a public
    /// property, so reading it copies a strong reference out of the client —
    /// `let cg = client.codegen` stored in a view model outlives the client
    /// that made it as soon as that client is released or replaced (which
    /// `configureDefault` allows). Every method here degrades to a thrown
    /// `.unavailable`, a `nil`, or a no-op instead.
    ///
    /// Matches how the other client-holding types are wired
    /// (`DocumentsAPI.client`, `DocumentContext.client`).
    private weak var client: JsBaoClient?

    init(client: JsBaoClient) {
        self.client = client
    }

    /// The owning client, or a thrown `.unavailable` when it has been
    /// released. Every throwing method funnels through this so the failure
    /// reads the same everywhere.
    private func requireClient(_ method: String) throws -> JsBaoClient {
        guard let client else {
            throw JsBaoError(
                code: .unavailable,
                message: "client.codegen.\(method) was called after its JsBaoClient was released"
            )
        }
        return client
    }

    /// Include target for generated query-time include builders. The
    /// generated `Model.includeRelation()` helpers call this with the target
    /// model's schema.
    ///
    /// It cannot throw (the generated builders call it in a non-throwing
    /// position), so when the owning client has been released it returns a
    /// detached target whose `query` throws `.unavailable` — the include fails
    /// where it is resolved, with a message, rather than trapping here.
    public func includeTarget(for schema: PrimitiveSchema) -> any IncludeTarget {
        guard let client else { return DetachedIncludeTarget(modelName: schema.name) }
        return client.sharedModel(for: schema)
    }

    // MARK: - Reads

    /// Cross-document query → raw rows. The facade maps rows to the model type.
    public func query(
        _ schema: PrimitiveSchema,
        filter: DocumentFilter? = nil,
        options: QueryOptions? = nil
    ) throws -> [[String: Any]] {
        try requireClient("query").sharedModel(for: schema).query(filter, options: options)
    }

    /// Cross-document query with query-time relationship includes. Returns raw
    /// rows with related records attached under `_related`, matching JS
    /// `BaseModel.query(filter, { include })`.
    public func query(
        _ schema: PrimitiveSchema,
        filter: DocumentFilter? = nil,
        options: QueryOptions? = nil,
        include: [Include]
    ) throws -> [[String: Any]] {
        try requireClient("query").sharedModel(for: schema)
            .query(filter, options: options, include: include)
    }

    /// Cross-document paginated query → raw rows + cursors. The facade maps
    /// rows to the model type while preserving `nextCursor`/`prevCursor`/
    /// `hasMore` — so a caller passing `options.cursor`/`options.limit` can
    /// actually obtain the next page. Mirrors js-bao's `BaseModel.query()`
    /// return shape (#946); ``query(_:filter:options:)`` stays the flat-array
    /// convenience.
    public func queryPaged(
        _ schema: PrimitiveSchema,
        filter: DocumentFilter? = nil,
        options: QueryOptions? = nil
    ) throws -> PagedQueryResult<PrimitiveRow> {
        try requireClient("queryPaged").sharedModel(for: schema).queryPaged(filter, options: options)
    }

    /// Cross-document paginated query with query-time relationship includes.
    public func queryPaged(
        _ schema: PrimitiveSchema,
        filter: DocumentFilter? = nil,
        options: QueryOptions? = nil,
        include: [Include]
    ) throws -> PagedQueryResult<PrimitiveRow> {
        try requireClient("queryPaged").sharedModel(for: schema)
            .queryPaged(filter, options: options, include: include)
    }

    /// Cross-document count.
    public func count(_ schema: PrimitiveSchema, filter: DocumentFilter? = nil) throws -> Int {
        try requireClient("count").sharedModel(for: schema).count(filter)
    }

    /// First record with `id` across every open doc (raw row), or `nil`.
    /// Answers `nil` once the owning client has been released — the same
    /// answer it gives for a record that isn't there.
    public func find(_ schema: PrimitiveSchema, id: String) -> [String: Any]? {
        client?.sharedModel(for: schema).find(id: id)?.row
    }

    /// First record matching a unique `constraint` and `value` across every
    /// open doc (raw row), or `nil`. Mirrors js-bao's `BaseModel.findByUnique`.
    public func findByUnique(
        _ schema: PrimitiveSchema, constraint: String, value: PrimitiveValue
    ) throws -> [String: Any]? {
        try requireClient("findByUnique").sharedModel(for: schema)
            .findByUnique(constraint: constraint, value: value)?.row
    }

    /// First record matching `filter` across every open doc (raw row), or
    /// `nil` — `query(...).first`. Mirrors js-bao's `BaseModel.queryOne`.
    public func queryOne(
        _ schema: PrimitiveSchema,
        filter: DocumentFilter? = nil,
        options: QueryOptions? = nil
    ) throws -> [String: Any]? {
        try requireClient("queryOne").sharedModel(for: schema).query(filter, options: options).first
    }

    /// First record matching `filter` across every open doc with query-time
    /// relationship includes attached under `_related` (raw row), or `nil`.
    /// Mirrors js-bao's `BaseModel.queryOne(filter, { include })`.
    ///
    /// Convention: this takes `.first` of the included query rather than
    /// forwarding `limit: 1` the way js-bao's `queryOne` does. That matches the
    /// no-include ``queryOne(_:filter:options:)`` above, so the typed `queryOne`
    /// overloads stay consistent with each other; the include resolver runs over
    /// the full match set and the first row (with its `_related`) is returned. A
    /// filter that matches nothing returns `nil` with no related decode.
    public func queryOne(
        _ schema: PrimitiveSchema,
        filter: DocumentFilter? = nil,
        options: QueryOptions? = nil,
        include: [Include]
    ) throws -> [String: Any]? {
        try requireClient("queryOne").sharedModel(for: schema)
            .query(filter, options: options, include: include).first
    }

    /// Aggregate (group / count / sum / avg / …) across every open document.
    public func aggregate(
        _ schema: PrimitiveSchema, options: AggregateOptions
    ) throws -> [[String: Any]] {
        try requireClient("aggregate").sharedModel(for: schema).aggregate(options)
    }

    /// Subscribe to any add/update/delete in any open doc's copy of the model.
    ///
    /// The callback is `@Sendable` (#1992): it runs on whichever thread
    /// committed the change — a local writer's thread, or the observer-drain
    /// queue — so state it captures must be safe to touch from either.
    ///
    /// Once the owning client has been released there is nothing left to
    /// observe, so this registers nothing and returns a no-op unsubscribe.
    public func subscribe(
        _ schema: PrimitiveSchema, _ callback: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void {
        guard let client else { return {} }
        return client.sharedModel(for: schema).subscribe(callback)
    }

    // MARK: - Writes

    /// Create-or-update a record in document `docId` — insert if it doesn't
    /// exist yet, update in place if it does (one call, mirrors js-bao's
    /// `BaseModel.save`). Throws if the doc isn't open.
    ///
    /// - Parameter changedFields: the fields the caller actually assigned,
    ///   js-bao's `_localChanges`. On an update only these are written, so a
    ///   save built from a stale fetch doesn't re-write — and clobber — the
    ///   fields another device changed concurrently (#2459). `nil` means "no
    ///   tracking information": every supplied value counts as a change.
    ///   Either way an update still drops values that already equal what's
    ///   persisted — see `DynamicModel.save(id:values:changedFields:)`.
    ///
    /// Returns the live `PrimitiveRecord` handle for the saved row, so a
    /// caller can read the record as it now stands in the document rather
    /// than assuming its own values won: on an update the fields it didn't
    /// write keep whatever another device put there, and on an insert the
    /// schema defaults and `auto_stamp` values are filled in. The generated
    /// `save(in:)` rebuilds its return value from this (#2459).
    @discardableResult
    public func save(
        _ schema: PrimitiveSchema, id: String,
        values: [String: PrimitiveValue], in docId: String,
        changedFields: Set<String>? = nil
    ) throws -> PrimitiveRecord {
        try requireClient("save").requireMember(schema, in: docId)
            .save(id: id, values: values, changedFields: changedFields)
    }

    /// Insert-or-update a record in document `docId`, matched by the
    /// single-field unique constraint on `field` — mirrors js-bao's
    /// `save({ upsertOn: field })`. Throws if the doc isn't open.
    ///
    /// Returns the `UpsertResult` so callers can read the RESOLVED
    /// record: on the merge path the existing record's id wins (JS
    /// reassigns `this.id = existingId`), so `result.record.id` may
    /// differ from the `id` passed in.
    /// - Parameter explicitId: `true` when the caller pinned the `id`
    ///   (the codegen's designated `init(id:…)`), `false` when it was
    ///   auto-generated (the auto-id convenience init). Threaded to
    ///   `DynamicModel.upsert` so an explicit id that collides with a
    ///   matched record throws `UpsertError.explicitIdConflict` —
    ///   mirroring js-bao's `_constructorProvidedId` upsertOn-conflict.
    /// - Parameter changedFields: the fields the caller actually assigned
    ///   (see ``save(_:id:values:in:changedFields:)``). Applies to the merge
    ///   path only; the insert path writes every supplied value.
    @discardableResult
    public func upsert(
        _ schema: PrimitiveSchema, id: String,
        values: [String: PrimitiveValue], on field: String, in docId: String,
        explicitId: Bool = false,
        changedFields: Set<String>? = nil
    ) throws -> UpsertResult {
        try requireClient("upsert").requireMember(schema, in: docId)
            .upsert(
                values, on: field, id: id, explicitId: explicitId,
                changedFields: changedFields
            )
    }

    /// Insert-or-update a record matched by the NAMED unique constraint
    /// (single-field or compound) — mirrors js-bao's
    /// `BaseModel.upsertByUnique(constraintName, lookupValue, data,
    /// options)`. `mode` maps JS's option flags: `.mustExist` ⇔
    /// `objectMustExist`, `.mustNotExist` ⇔ `objectMustNotExist`,
    /// `.either` ⇔ default. Throws if the constraint isn't declared, a
    /// constraint field is missing from `values`, or (on insert) the
    /// target doc isn't open.
    ///
    /// Scope: the existing-record search spans EVERY open document
    /// (js-bao parity — `for (docId of connectedDocuments)`); a match in
    /// any open doc merges into that doc, and a fresh insert lands in
    /// `docId`.
    ///
    /// - Parameter uniqueLookupValue: optional explicit lookup value(s),
    ///   one per constraint field — mirrors js-bao's separate
    ///   `uniqueLookupValue` argument. When nil the key is built from
    ///   `values`. Validated against `values` (arity + per-field).
    /// - Parameter explicitId: `true` when the caller pinned `id`; an
    ///   explicit id colliding with a matched record throws
    ///   `UpsertError.explicitIdConflict`.
    /// - Parameter changedFields: the fields the caller actually assigned
    ///   (see ``save(_:id:values:in:changedFields:)``). Applies to the merge
    ///   path only; the insert path writes every supplied value.
    @discardableResult
    public func upsertByUnique(
        _ schema: PrimitiveSchema, id: String,
        values: [String: PrimitiveValue], constraint: String,
        mode: UpsertMode = .either, in docId: String,
        explicitId: Bool = false,
        uniqueLookupValue: [PrimitiveValue]? = nil,
        changedFields: Set<String>? = nil
    ) throws -> UpsertResult {
        // The cross-doc search needs the document open before it can be a
        // merge target; require it up front (also the insert target).
        let client = try requireClient("upsertByUnique")
        _ = try client.requireMember(schema, in: docId)
        return try client.sharedModel(for: schema).upsertByUnique(
            constraint: constraint, data: values, mode: mode, id: id,
            explicitId: explicitId, targetDocId: docId,
            uniqueLookupValue: uniqueLookupValue,
            changedFields: changedFields
        )
    }

    /// Delete a record from document `docId`. Throws if the doc isn't open.
    public func delete(_ schema: PrimitiveSchema, id: String, in docId: String) throws {
        try requireClient("delete").requireMember(schema, in: docId).delete(id: id)
    }

    // MARK: - Cross-document relationship traversal
    //
    // These mirror the JS client's generated relationship instance methods
    // (`author.posts()`, `post.author()` — relationshipManager.ts), where the
    // target model class is baked in at codegen and the accessor resolves the
    // related record(s) by querying that target. On Swift the generated
    // value-type struct has no per-document handle, so traversal runs against
    // the cross-document shared store (same surface as `query` / `find`): the
    // emitter knows the target's `PrimitiveSchema` at codegen time and passes
    // it in, so no global registry lookup is needed.
    //
    // Semantically equivalent to the per-record resolvers in
    // `PrimitiveRecord.refersTo/hasMany/hasManyThrough` (RelationshipResolution.swift),
    // but spanning every open document instead of one doc's `DynamicModel`.

    /// Resolve a `refersTo` relationship: `sourceForeignKey` is this
    /// record's foreign-key value pointing at a record in `target`.
    /// Returns the target's raw row, or `nil` when the FK is unset or
    /// points at a missing record. Mirrors JS `generateRefersToMethod`
    /// (`targetModelClass.find(relatedId)`).
    public func refersTo(
        target: PrimitiveSchema,
        foreignKey sourceForeignKey: String?
    ) -> [String: Any]? {
        guard let fk = sourceForeignKey, !fk.isEmpty else { return nil }
        return find(target, id: fk)
    }

    /// Resolve a `hasMany` relationship: records in `target` whose
    /// `relatedIdField` equals `sourceId` (this record's id). Applies
    /// optional `orderByField` / `orderDirection` sort. Returns raw rows.
    /// Mirrors JS `generateHasManyMethod`
    /// (`targetModelClass.query({ [relatedIdField]: this.id }, { sort })`).
    public func hasMany(
        target: PrimitiveSchema,
        relatedIdField: String,
        sourceId: String,
        orderByField: String? = nil,
        orderDirection: String? = nil
    ) throws -> [[String: Any]] {
        let descending = (orderDirection?.uppercased() == "DESC")
        let options = orderByField.map { QueryOptions(sort: [$0: descending ? -1 : 1]) }
        return try query(target, filter: [relatedIdField: sourceId], options: options)
    }

    /// Resolve a `hasManyThrough` relationship via `joinModel`: find join
    /// rows whose `joinModelLocalField` equals `sourceId` (ordered by the
    /// declared `joinModelOrderByField` / `joinModelOrderDirection`, default
    /// `id ASC`), collect their `joinModelRelatedField` values, and resolve
    /// those ids in `target` with a single `id: { $in: [...] }` query. That
    /// query's `id ASC` tiebreaker re-orders the output, so targets come back
    /// in **target `id ASC`** — the declared join order governs which rows are
    /// selected, not the final order. Mirrors JS `generateHasManyThroughMethod`
    /// (sort join leg → `query({ id: { $in } })` → `id ASC` tiebreaker).
    public func hasManyThrough(
        target: PrimitiveSchema,
        joinModel: PrimitiveSchema,
        sourceId: String,
        joinModelLocalField: String,
        joinModelRelatedField: String,
        joinModelOrderByField: String? = nil,
        joinModelOrderDirection: String? = nil
    ) throws -> [[String: Any]] {
        let descending = (joinModelOrderDirection?.uppercased() == "DESC")
        let joinOptions = joinModelOrderByField.map {
            QueryOptions(sort: [$0: descending ? -1 : 1])
        }
        let joinRows = try query(
            joinModel, filter: [joinModelLocalField: sourceId], options: joinOptions
        )
        let targetIds = joinRows.compactMap { $0[joinModelRelatedField] as? String }
        guard !targetIds.isEmpty else { return [] }
        return try query(target, filter: ["id": ["$in": targetIds]], options: nil)
    }

    /// Paginated `hasManyThrough` traversal — pages the JOIN leg through the
    /// shared composite-cursor engine (``queryPaged(_:filter:options:)``) by
    /// the declared `joinModelOrderByField` / `joinModelOrderDirection`
    /// (defaulting to **`id ASC`** when none is declared), then
    /// `$in`-resolves the page's related ids against `target`. Mirrors JS
    /// `generateHasManyThroughMethod`, which now delegates the page cut to
    /// `BaseModel.query` (`relationshipManager.ts`).
    ///
    /// The cursor is the engine's **opaque** token (a `String?`), the same
    /// composite `(field, id)` cursor `queryPaged` mints — so a cursor issued
    /// here or by the JS client round-trips through the shared decoder. This
    /// fixes the tie-straddle skip/duplicate defect (#1607) the old
    /// hand-rolled raw-scalar cursor had. `limit` is required so a bare
    /// `hasManyThrough(...)` call still binds to the unpaginated overload
    /// above.
    ///
    /// Envelope contract: the returned `nextCursor` / `prevCursor` / `hasMore`
    /// are COPIED verbatim from the join leg's paged result, and `data` is
    /// REPLACED with the `$in`-resolved targets. Targets come back **target
    /// `id ASC`** (the `$in` tiebreaker, #1201) — the join order governs which
    /// rows are on the page, not the intra-page order. `hasMore` is the
    /// engine's over-fetch signal: more rows remain in the CURRENT paging
    /// direction (forward → later rows, backward → earlier rows) — it is NOT
    /// "a prevCursor is present".
    ///
    /// A non-positive `limit` returns an empty page without querying.
    public func hasManyThrough(
        target: PrimitiveSchema,
        joinModel: PrimitiveSchema,
        sourceId: String,
        joinModelLocalField: String,
        joinModelRelatedField: String,
        joinModelOrderByField: String? = nil,
        joinModelOrderDirection: String? = nil,
        limit: Int,
        afterCursor: String? = nil,
        beforeCursor: String? = nil,
        direction: CursorDirection = .forward
    ) throws -> PagedQueryResult<PrimitiveRow> {
        guard limit > 0 else {
            return PagedQueryResult(data: [], nextCursor: nil, prevCursor: nil, hasMore: false)
        }
        let orderByField = joinModelOrderByField ?? "id"
        let descending = (joinModelOrderDirection?.uppercased() == "DESC")

        // D7 / Fork B (#1607): warn on a nullable join order field.
        RelationshipPaginationValidator.warnIfOrderFieldNullable(
            schema: joinModel, orderByField: orderByField,
            relationshipDescription:
                "hasManyThrough(\(target.name) via \(joinModel.name))"
        )

        let cursor = direction == .forward ? afterCursor : beforeCursor
        let joinOptions = QueryOptions(
            sort: [orderByField: descending ? -1 : 1],
            limit: limit,
            cursor: cursor,
            direction: direction,
            projection: [joinModelRelatedField: 1, orderByField: 1]
        )
        let joinPage = try queryPaged(
            joinModel, filter: [joinModelLocalField: sourceId], options: joinOptions
        )
        let relatedIds = joinPage.data.compactMap { $0[joinModelRelatedField] as? String }
        guard !relatedIds.isEmpty else {
            return PagedQueryResult(
                data: [], nextCursor: joinPage.nextCursor,
                prevCursor: joinPage.prevCursor, hasMore: joinPage.hasMore
            )
        }
        let rows = try query(target, filter: ["id": ["$in": relatedIds]], options: nil)
        return PagedQueryResult(
            data: rows.map(PrimitiveRow.init(raw:)), nextCursor: joinPage.nextCursor,
            prevCursor: joinPage.prevCursor, hasMore: joinPage.hasMore
        )
    }
}

/// What ``CodegenAPI/includeTarget(for:)`` answers with once its owning client
/// has been released. `includeTarget` sits in a non-throwing position in the
/// generated relationship builders, so it cannot report the failure itself;
/// this defers it to the point the include is resolved, where `query` can
/// throw a message instead of trapping.
private final class DetachedIncludeTarget: IncludeTarget {
    let modelName: String

    init(modelName: String) {
        self.modelName = modelName
    }

    func query(_ filter: DocumentFilter?, options: QueryOptions?) throws -> [[String: Any]] {
        throw JsBaoError(
            code: .unavailable,
            message: "An include targeting `\(modelName)` was built from a client.codegen "
                + "whose JsBaoClient has been released"
        )
    }
}
