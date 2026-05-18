import Foundation

/// What an `Include` spec can point at. Both `DynamicModel`
/// (single-doc) and `MultiDocModel` (shared-store across many docs)
/// conform, so an include can batch-fetch related records regardless
/// of which doc owns them. The resolver only needs `modelName` for
/// the default result key and a `query(_:options:)` primitive for the
/// batched FK lookup.
public protocol IncludeTarget: AnyObject {
    var modelName: String { get }
    func query(_ filter: DocumentFilter?, options: QueryOptions?) -> [[String: Any]]
}

extension DynamicModel: IncludeTarget {}

/// The three relationship flavors supported by `Include`. Mirrors
/// js-bao's `IncludeSpec.type` (`refersTo | refersToMany | hasMany`).
public enum IncludeKind: String, Sendable, Equatable {
    /// Parent holds a foreign-key scalar pointing at ONE target record.
    case refersTo
    /// Parent holds a stringset of foreign-key values referencing
    /// MANY target records.
    case refersToMany
    /// Target records carry a FK pointing back at the parent.
    case hasMany
}

/// Declarative include spec — pass an array of these to
/// `DynamicModel.query(... , include:)` to batch-prefetch related
/// records. Ported from js-bao's `IncludeSpec` (queryTypes).
///
/// For each parent record in the query result, matched related
/// records are attached under `row["_related"][resultKey]`.
public struct Include {
    public let type: IncludeKind
    /// Target model to pull related records from. Either a single-doc
    /// `DynamicModel` or a cross-doc `MultiDocModel` — the resolver
    /// calls the same `query` API on both.
    public let target: any IncludeTarget
    /// Key the related data gets stored under in `_related`. Defaults
    /// to the target's `modelName`.
    public let resultKey: String?

    /// **refersTo / refersToMany**: the parent's field holding the
    /// FK value (scalar) or FK-set (stringset).
    public let sourceField: String?

    /// **hasMany**: the target model's field pointing back at the
    /// parent. Required.
    public let foreignKey: String?

    /// **hasMany**: the parent's field whose value is compared to
    /// `foreignKey` on the target. Defaults to `"id"`.
    public let localField: String?

    /// Extra filter applied to the related records (in addition to
    /// the FK match).
    public let filter: DocumentFilter?

    /// Sort order for related records (mainly meaningful for hasMany).
    public let sort: [String: Int]?

    /// Per-parent limit on hasMany. Applied by filtering the
    /// target-side result after grouping.
    public let limit: Int?

    /// Nested includes — each attached related record gets its own
    /// `_related` populated. Depth capped at 3, matching js-bao.
    public let include: [Include]?

    /// Per-include field projection. Same shape as
    /// `QueryOptions.projection` — 1 = include, 0 = exclude, with `id`
    /// always returned. Applies to the related records only.
    public let projection: [String: Int]?

    public init(
        type: IncludeKind,
        target: any IncludeTarget,
        sourceField: String? = nil,
        foreignKey: String? = nil,
        localField: String? = nil,
        filter: DocumentFilter? = nil,
        sort: [String: Int]? = nil,
        limit: Int? = nil,
        projection: [String: Int]? = nil,
        resultKey: String? = nil,
        include: [Include]? = nil
    ) {
        self.type = type
        self.target = target
        self.sourceField = sourceField
        self.foreignKey = foreignKey
        self.localField = localField
        self.filter = filter
        self.sort = sort
        self.limit = limit
        self.projection = projection
        self.resultKey = resultKey
        self.include = include
    }
}

/// Batch-aware relationship resolver. Ported from js-bao's
/// `IncludeResolver` (`src/query/IncludeResolver.ts`).
///
/// One pass per include spec:
///   1. Collect unique FK values from the parent rows.
///   2. Query the target model once (with an `$in` over all FKs).
///   3. Build a lookup map.
///   4. Attach related records to `row["_related"][resultKey]`.
///
/// For `hasMany` we group by the FK back-pointer; for `refersToMany`
/// we expand the parent's stringset into member ids then map.
///
/// Recurses on nested includes, capping at depth 3.
enum IncludeResolver {

    static let maxDepth = 3

    /// Top-level entry — mutate `rows` in place, attaching
    /// `_related[resultKey]` for each include.
    static func resolve(
        rows: inout [[String: Any]],
        includes: [Include],
        depth: Int
    ) throws {
        if rows.isEmpty { return }
        if depth >= maxDepth { return }

        for spec in includes {
            // Ensure every row has a `_related` container before we
            // write into it.
            for i in rows.indices {
                if rows[i]["_related"] == nil {
                    rows[i]["_related"] = [String: Any]()
                }
            }
            let key = spec.resultKey ?? spec.target.modelName

            switch spec.type {
            case .refersTo:
                try resolveRefersTo(rows: &rows, spec: spec, key: key)
            case .refersToMany:
                try resolveRefersToMany(rows: &rows, spec: spec, key: key)
            case .hasMany:
                try resolveHasMany(rows: &rows, spec: spec, key: key)
            }

            // Recurse. Collect the related records attached under
            // `key` across all rows, then recurse with depth+1.
            if let nested = spec.include, !nested.isEmpty {
                var collected: [[String: Any]] = []
                for row in rows {
                    let related = row["_related"] as? [String: Any]
                    if let arr = related?[key] as? [[String: Any]] {
                        collected.append(contentsOf: arr)
                    } else if let obj = related?[key] as? [String: Any] {
                        collected.append(obj)
                    }
                }
                if !collected.isEmpty {
                    try resolve(rows: &collected, includes: nested, depth: depth + 1)
                    // Propagate the mutated _related back into the
                    // parent rows.
                    reattachMutatedRelated(
                        parents: &rows, key: key, children: collected
                    )
                }
            }
        }
    }

    // MARK: - refersTo

    private static func resolveRefersTo(
        rows: inout [[String: Any]],
        spec: Include,
        key: String
    ) throws {
        guard let fkField = spec.sourceField else { return }

        let fkValues: [String] = Array(Set(
            rows.compactMap { $0[fkField] as? String }.filter { !$0.isEmpty }
        ))
        if fkValues.isEmpty {
            for i in rows.indices {
                setRelated(&rows[i], key: key, value: NSNull())
            }
            return
        }

        var filter: DocumentFilter = ["id": ["$in": fkValues]]
        if let extra = spec.filter {
            for (k, v) in extra { filter[k] = v }
        }
        let relatedRows = spec.target.query(
            filter,
            options: spec.projection.map { QueryOptions(projection: $0) }
        )
        var lookup: [String: [String: Any]] = [:]
        for r in relatedRows {
            if let id = r["id"] as? String { lookup[id] = r }
        }

        for i in rows.indices {
            let fk = rows[i][fkField] as? String
            if let fk, let match = lookup[fk] {
                setRelated(&rows[i], key: key, value: match)
            } else {
                setRelated(&rows[i], key: key, value: NSNull())
            }
        }
    }

    // MARK: - refersToMany

    private static func resolveRefersToMany(
        rows: inout [[String: Any]],
        spec: Include,
        key: String
    ) throws {
        guard let fkField = spec.sourceField else { return }

        // Each parent row's stringset column is already an
        // `[String]` — the engine populates it from the per-field
        // junction table after the base SELECT (see
        // `BaoModelQueryEngine.populateStringsets`). Older CSV-
        // backed rows would show up as a plain `String`; we keep a
        // defensive split-on-comma fallback for that, but in a
        // well-formed current-layout database it's never exercised.
        var perParent: [(parentIdx: Int, ids: [String])] = []
        var allTargetIds = Set<String>()
        for (i, row) in rows.enumerated() {
            let ids: [String]
            if let arr = row[fkField] as? [String] {
                ids = arr
            } else if let csv = row[fkField] as? String, !csv.isEmpty {
                ids = csv.split(separator: ",").map(String.init)
            } else {
                ids = []
            }
            perParent.append((i, ids))
            for id in ids { allTargetIds.insert(id) }
        }

        if allTargetIds.isEmpty {
            for i in rows.indices {
                setRelated(&rows[i], key: key, value: [[String: Any]]())
            }
            return
        }

        var filter: DocumentFilter = ["id": ["$in": Array(allTargetIds)]]
        if let extra = spec.filter {
            for (k, v) in extra { filter[k] = v }
        }

        // Push sort + projection into the target query. `spec.limit`
        // caps per-parent (not total), so we don't propagate it to
        // the target query — instead we apply it after filtering
        // each parent's set.
        let targetOptions: QueryOptions? = {
            if spec.sort?.isEmpty == false || spec.projection != nil {
                return QueryOptions(sort: spec.sort, projection: spec.projection)
            }
            return nil
        }()
        let targetRows = spec.target.query(filter, options: targetOptions)

        // Build both a lookup (for O(1) membership) and preserve the
        // sorted order by walking `targetRows` directly.
        var lookup: [String: [String: Any]] = [:]
        for r in targetRows {
            if let id = r["id"] as? String { lookup[id] = r }
        }

        for (parentIdx, ids) in perParent {
            let idSet = Set(ids)
            // Walk target rows in sorted order; pick only this
            // parent's members. If no spec.sort was set, the target
            // query's default is `id ASC` (via resolveSort), so the
            // order is at least deterministic.
            var matched: [[String: Any]] = []
            for row in targetRows {
                guard let rid = row["id"] as? String,
                      idSet.contains(rid) else { continue }
                matched.append(row)
                if let limit = spec.limit, matched.count >= limit { break }
            }
            // Fallback: if sort wasn't applied and we found nothing
            // via the walk (shouldn't happen, but defensive), use the
            // lookup path for a best-effort result.
            if matched.isEmpty && !idSet.isEmpty {
                matched = ids.compactMap { lookup[$0] }
                if let limit = spec.limit, matched.count > limit {
                    matched = Array(matched.prefix(limit))
                }
            }
            setRelated(&rows[parentIdx], key: key, value: matched)
        }
    }

    // MARK: - hasMany

    private static func resolveHasMany(
        rows: inout [[String: Any]],
        spec: Include,
        key: String
    ) throws {
        guard let fkField = spec.foreignKey else { return }
        let localField = spec.localField ?? "id"

        let parentValues: [String] = Array(Set(
            rows.compactMap { $0[localField] as? String }.filter { !$0.isEmpty }
        ))
        if parentValues.isEmpty {
            for i in rows.indices {
                setRelated(&rows[i], key: key, value: [[String: Any]]())
            }
            return
        }

        var filter: DocumentFilter = [fkField: ["$in": parentValues]]
        if let extra = spec.filter {
            for (k, v) in extra { filter[k] = v }
        }
        // Apply sort + projection on the target side so per-parent
        // ordering is correct before limiting and projected fields
        // flow through. Force-select `fkField` internally so grouping
        // still works when a caller projection omits it; strip it
        // back out of emitted rows afterwards if the caller said so.
        let (queryProjection, stripFK) = forceIncludeFK(
            projection: spec.projection, fkField: fkField
        )
        let opts = QueryOptions(sort: spec.sort, projection: queryProjection)
        let allRelated = spec.target.query(filter, options: opts)

        var grouped: [String: [[String: Any]]] = [:]
        for r in allRelated {
            guard let fk = r[fkField] as? String else { continue }
            var emitted = r
            if stripFK { emitted.removeValue(forKey: fkField) }
            grouped[fk, default: []].append(emitted)
        }

        for i in rows.indices {
            let parentKey = rows[i][localField] as? String ?? ""
            var list = grouped[parentKey] ?? []
            if let limit = spec.limit, list.count > limit {
                list = Array(list.prefix(limit))
            }
            setRelated(&rows[i], key: key, value: list)
        }
    }

    /// Ensures `fkField` is fetched so `resolveHasMany` can group by
    /// it. Returns the projection to run the target query with, plus
    /// whether the caller's projection excluded the field (in which
    /// case it must be stripped from emitted rows after grouping).
    private static func forceIncludeFK(
        projection: [String: Int]?,
        fkField: String
    ) -> (query: [String: Int]?, stripAfter: Bool) {
        guard let projection, !projection.isEmpty else {
            return (projection, false)
        }
        // Include-mode (all 1s): add fkField as 1 if absent. The user
        // didn't ask for it, so strip it after grouping.
        // Exclude-mode (all 0s): drop fkField from the exclusion map
        // if present. Same: user asked to omit, so strip after.
        let isIncludeMode = projection.values.allSatisfy { $0 == 1 }
        if isIncludeMode {
            if projection[fkField] == 1 {
                return (projection, false)
            }
            var next = projection
            next[fkField] = 1
            return (next, true)
        } else {
            if projection[fkField] != 0 {
                return (projection, false)
            }
            var next = projection
            next.removeValue(forKey: fkField)
            return (next.isEmpty ? nil : next, true)
        }
    }

    // MARK: - Helpers

    private static func setRelated(
        _ row: inout [String: Any],
        key: String,
        value: Any
    ) {
        var related = row["_related"] as? [String: Any] ?? [:]
        related[key] = value
        row["_related"] = related
    }

    /// After recursing on nested related records we mutated those
    /// copies (array/value-type semantics). Put the mutated versions
    /// back into the parent's `_related`.
    private static func reattachMutatedRelated(
        parents: inout [[String: Any]],
        key: String,
        children: [[String: Any]]
    ) {
        // Map children back to their parent rows by id.
        var byId: [String: [String: Any]] = [:]
        for c in children {
            if let id = c["id"] as? String { byId[id] = c }
        }
        for i in parents.indices {
            var related = parents[i]["_related"] as? [String: Any] ?? [:]
            if let arr = related[key] as? [[String: Any]] {
                related[key] = arr.map { orig -> [String: Any] in
                    if let id = orig["id"] as? String, let updated = byId[id] {
                        return updated
                    }
                    return orig
                }
            } else if let obj = related[key] as? [String: Any] {
                if let id = obj["id"] as? String, let updated = byId[id] {
                    related[key] = updated
                }
            }
            parents[i]["_related"] = related
        }
    }
}
