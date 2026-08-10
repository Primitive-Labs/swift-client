import Foundation

/// Errors from runtime relationship accessors on `PrimitiveRecord`.
/// Relationship METADATA is stored in `_meta_*._relationships` by the
/// schema-sync code; these are the errors for USING it at runtime.
public enum RelationshipError: Error, Equatable, Sendable {
    /// No relationship by that name is registered on this record's schema.
    case relationshipNotFound(String)
    /// The named relationship exists but is of a different type than
    /// the caller's method implies (e.g. calling `refersTo` on a
    /// `hasMany` relationship). Prevents silent misuse.
    case wrongType(name: String, expected: String, got: String)
    /// The relationship's metadata is missing the `type` key entirely
    /// — the doc is malformed.
    case missingTypeMetadata(relationship: String)
    /// The relationship config doesn't include a key required to
    /// resolve it (e.g. `relatedIdField` for a hasMany).
    case missingRequiredProperty(relationship: String, property: String)
}

/// Shared D7 / Fork B (#1607) guard for relationship pagination: warn when a
/// pagination order field is nullable / optional on the model being paged.
/// Kept as one helper so the cross-document shared path
/// (`JsBaoClient.hasManyThroughShared`) and the dynamic path
/// (`PrimitiveRecord.hasManyThrough`) apply the identical rule. Mirrors JS
/// `warnIfOrderFieldNullable` (`relationshipManager.ts`).
///
/// This started (Fork B, sponsor-approved 2026-07-17) as a hard throw. It was
/// relaxed to a warning to match JS: a hard throw broke existing valid schemas
/// that order a `hasMany` by an indexed-but-not-`required` field (the
/// canonical `authors.posts`-by-`createdAt` "newest first" pattern shipped in
/// the vue demo and docs harness). The composite `(field, id)` cursor already
/// appends the `id` tiebreaker, so a non-unique order field paginates
/// deterministically; only a value that is *actually* NULL on a boundary row
/// is a hazard, and that isn't detectable from the `required` flag alone
/// (`createdAt` is not marked `required` yet is always present in practice).
/// Full NULL-ordering semantics are deferred to #1316.
///
/// Only warns about a field we can positively see is not marked required:
/// `id` / `type` are always present, and an order field absent from
/// `schema.fields` isn't something we can assert about, so both are skipped.
enum RelationshipPaginationValidator {
    /// System fields that are always present and never nullable.
    static let alwaysPresentOrderFields: Set<String> = ["id", "type"]

    /// Advisory logger for the D7 warning. Fixed at `.warn` because this is a
    /// rare, correctness-relevant advisory (only fires for a nullable order
    /// field) that should surface regardless of the client's log level.
    private static let logger = createLogger(level: .warn, scope: "RelationshipPagination")

    static func warnIfOrderFieldNullable(
        schema: PrimitiveSchema,
        orderByField: String,
        relationshipDescription: String
    ) {
        if alwaysPresentOrderFields.contains(orderByField) { return }
        guard let field = schema.fields[orderByField] else { return }
        if field.required != true {
            logger.warn(
                "\(relationshipDescription) orders by "
                    + "'\(orderByField)', which is not marked required. The composite "
                    + "(\(orderByField), id) cursor paginates deterministically, but a row "
                    + "whose '\(orderByField)' is actually NULL has no stable cursor position "
                    + "and may drop from the tail. Mark '\(orderByField)' as required, or order "
                    + "by a required field such as 'id', to remove the risk. "
                    + "(Full NULL-ordering support is tracked in #1316.)"
            )
        }
    }
}

public extension PrimitiveRecord {

    /// Follow a `refersTo` relationship: this record holds a foreign
    /// key (`relatedIdField`) pointing to a record in `target`.
    /// Returns `nil` if the FK is missing or the target doesn't exist.
    ///
    /// Matches js-bao's `refersTo` accessor semantics
    /// (`RefersToRelationshipConfig`).
    func refersTo(
        relationship name: String,
        target: DynamicModel
    ) throws -> PrimitiveRecord? {
        let rel = try requireRelationship(name: name, expectedType: "refersTo")
        guard let fkField = rel.properties["relatedIdField"] else {
            throw RelationshipError.missingRequiredProperty(
                relationship: name, property: "relatedIdField"
            )
        }
        guard let fkValue = self[fkField]?.asString else { return nil }
        return target.find(id: fkValue)
    }

    /// Follow a `hasMany` relationship: records in `target` have a
    /// foreign key (`relatedIdField`) pointing back at this record.
    ///
    /// Applies optional `orderByField` / `orderDirection` sort.
    /// Matches js-bao's `hasMany` accessor semantics.
    func hasMany(
        relationship name: String,
        target: DynamicModel
    ) throws -> [PrimitiveRecord] {
        let rel = try requireRelationship(name: name, expectedType: "hasMany")
        guard let fkField = rel.properties["relatedIdField"] else {
            throw RelationshipError.missingRequiredProperty(
                relationship: name, property: "relatedIdField"
            )
        }

        // Route through the SQLite-backed query engine (indexed FK
        // lookup) instead of `findAll().filter` — the O(N) full scan
        // this used to do (#1115). Same filter the batch Include path
        // builds (`fkField IN parents`), specialized to one parent.
        // js-bao's generated hasMany accessor does the same:
        // `query({ [relatedIdField]: this.id }, { sort: ... })`
        // (relationshipManager.ts `generateHasManyMethod`).
        let orderBy = rel.properties["orderByField"]
        let descending = rel.properties["orderDirection"] == "DESC"
        let options = orderBy.map {
            QueryOptions(sort: [$0: descending ? -1 : 1])
        }
        let rows = try target.query([fkField: .string(self.id)], options: options)
        return rows.compactMap { row in
            (row["id"]?.stringValue).map {
                PrimitiveRecord(modelName: target.schema.name, id: $0, model: target)
            }
        }
    }

    /// Follow a `refersToMany` relationship: this record has a
    /// stringset field (`sourceField`) whose entries are ids into the
    /// target model. Returns the matched target records in the order
    /// dictated by `Set` iteration (stable within a doc, not across).
    ///
    /// Companion to the batch `Include(type: .refersToMany, ...)`
    /// API, for cases where you only have a single parent in hand.
    func refersToMany(
        relationship name: String,
        target: DynamicModel
    ) throws -> [PrimitiveRecord] {
        let rel = try requireRelationship(name: name, expectedType: "refersToMany")
        guard let src = rel.properties["sourceField"] else {
            throw RelationshipError.missingRequiredProperty(
                relationship: name, property: "sourceField"
            )
        }
        guard case let .stringset(ids) = self[src] ?? .stringset([]) else {
            return []
        }
        return ids.compactMap { target.find(id: $0) }
    }

    /// Follow a `hasManyThrough` relationship via a join model.
    /// Matches js-bao's `hasManyThrough` accessor semantics.
    func hasManyThrough(
        relationship name: String,
        joinModel: DynamicModel,
        target: DynamicModel
    ) throws -> [PrimitiveRecord] {
        let rel = try requireRelationship(
            name: name, expectedType: "hasManyThrough"
        )
        guard let localField = rel.properties["joinModelLocalField"] else {
            throw RelationshipError.missingRequiredProperty(
                relationship: name, property: "joinModelLocalField"
            )
        }
        guard let relatedField = rel.properties["joinModelRelatedField"] else {
            throw RelationshipError.missingRequiredProperty(
                relationship: name, property: "joinModelRelatedField"
            )
        }

        // Find join rows pointing at this record — indexed query
        // instead of the old `findAll().filter` full scan (#1115).
        // Order the join leg by the declared `joinModelOrderByField` /
        // `joinModelOrderDirection` (default `id ASC`), like the `hasMany`
        // sibling above — js-bao sorts the join leg before collecting ids
        // (relationshipManager.ts `generateHasManyThroughMethod`).
        let joinOrderBy = rel.properties["joinModelOrderByField"] ?? "id"
        let descending = rel.properties["joinModelOrderDirection"]?.uppercased() == "DESC"
        let joinOptions = QueryOptions(sort: [joinOrderBy: descending ? -1 : 1])
        let joinRows = try joinModel.query([localField: .string(self.id)], options: joinOptions)
        let targetIds = joinRows.compactMap { $0[relatedField]?.stringValue }
        guard !targetIds.isEmpty else { return [] }
        // Resolve the targets with one batched `id: { $in: [...] }` query.
        // Its `id ASC` tiebreaker re-orders the output to target `id ASC`,
        // matching JS and the generated `hasManyThroughShared` path — the
        // declared join order selects which rows, not the final order.
        let rows = try target.query(["id": ["$in": .array(targetIds.map { .string($0) })]], options: nil)
        return rows.compactMap { row in
            (row["id"]?.stringValue).map {
                PrimitiveRecord(modelName: target.schema.name, id: $0, model: target)
            }
        }
    }

    /// Paginated `hasManyThrough` — pages the join leg through the shared
    /// composite-cursor engine (`DynamicModel.queryPaged`), then
    /// `$in`-resolves the page's ids against `target`. The dynamic-path
    /// counterpart to `JsBaoClient.hasManyThroughShared`'s paginated
    /// overload; both delegate the page cut to the same engine so the
    /// tie-straddle skip/duplicate defect (#1607) can't recur.
    ///
    /// Cursors are the engine's **opaque** tokens (a `String?`), not raw
    /// join-scalar values — so a cursor minted here or by the JS client
    /// round-trips through the same composite `(field, id)` decoder. The
    /// wrapper copies the join leg's `nextCursor` / `prevCursor` / `hasMore`
    /// verbatim and replaces `data` with the resolved targets. Targets come
    /// back **target `id ASC`** (the `$in` tiebreaker, #1201) — the join
    /// order picks page membership, not intra-page order. `hasMore` is the
    /// engine's over-fetch signal: more rows remain in the CURRENT paging
    /// direction (forward → later rows, backward → earlier rows).
    ///
    /// `limit` is required so a bare `hasManyThrough(...)` call still binds
    /// to the unpaginated overload above.
    func hasManyThrough(
        relationship name: String,
        joinModel: DynamicModel,
        target: DynamicModel,
        limit: Int,
        afterCursor: String? = nil,
        beforeCursor: String? = nil,
        direction: CursorDirection = .forward
    ) throws -> PagedQueryResult<PrimitiveRecord> {
        guard limit > 0 else {
            return PagedQueryResult(data: [], nextCursor: nil, prevCursor: nil, hasMore: false)
        }
        let rel = try requireRelationship(
            name: name, expectedType: "hasManyThrough"
        )
        guard let localField = rel.properties["joinModelLocalField"] else {
            throw RelationshipError.missingRequiredProperty(
                relationship: name, property: "joinModelLocalField"
            )
        }
        guard let relatedField = rel.properties["joinModelRelatedField"] else {
            throw RelationshipError.missingRequiredProperty(
                relationship: name, property: "joinModelRelatedField"
            )
        }

        let orderByField = rel.properties["joinModelOrderByField"] ?? "id"
        let descending = (rel.properties["joinModelOrderDirection"]?.uppercased() == "DESC")

        // D7 / Fork B (#1607): warn on a nullable join order field.
        RelationshipPaginationValidator.warnIfOrderFieldNullable(
            schema: joinModel.schema, orderByField: orderByField,
            relationshipDescription:
                "hasManyThrough(\(target.schema.name) via \(joinModel.schema.name))"
        )

        let cursor = direction == .forward ? afterCursor : beforeCursor
        let options = QueryOptions(
            sort: [orderByField: descending ? -1 : 1],
            limit: limit,
            cursor: cursor,
            direction: direction,
            projection: [relatedField: 1, orderByField: 1]
        )
        let joinPage = try joinModel.queryPaged([localField: .string(self.id)], options: options)
        let relatedIds = joinPage.data.compactMap { $0[relatedField]?.stringValue }
        guard !relatedIds.isEmpty else {
            return PagedQueryResult(
                data: [], nextCursor: joinPage.nextCursor,
                prevCursor: joinPage.prevCursor, hasMore: joinPage.hasMore
            )
        }
        let rows = try target.query(["id": ["$in": .array(relatedIds.map { .string($0) })]], options: nil)
        let records: [PrimitiveRecord] = rows.compactMap { row in
            (row["id"]?.stringValue).map {
                PrimitiveRecord(modelName: target.schema.name, id: $0, model: target)
            }
        }
        return PagedQueryResult(
            data: records, nextCursor: joinPage.nextCursor,
            prevCursor: joinPage.prevCursor, hasMore: joinPage.hasMore
        )
    }

    // MARK: - Internals

    private func requireRelationship(
        name: String,
        expectedType: String
    ) throws -> RelationshipDescriptor {
        guard let rel = model.schema.relationships[name] else {
            throw RelationshipError.relationshipNotFound(name)
        }
        guard let actualType = rel.properties["type"] else {
            throw RelationshipError.missingTypeMetadata(relationship: name)
        }
        guard actualType == expectedType else {
            throw RelationshipError.wrongType(
                name: name, expected: expectedType, got: actualType
            )
        }
        return rel
    }
}
