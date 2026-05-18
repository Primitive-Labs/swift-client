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

        let matches = target.findAll().filter {
            $0[fkField]?.asString == self.id
        }

        guard let orderBy = rel.properties["orderByField"] else { return matches }

        let descending = rel.properties["orderDirection"] == "DESC"
        return matches.sorted { a, b in
            let av = a[orderBy]?.asString ?? ""
            let bv = b[orderBy]?.asString ?? ""
            return descending ? av > bv : av < bv
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

        // Find join rows pointing at this record.
        let joinRows = joinModel.findAll().filter {
            $0[localField]?.asString == self.id
        }
        // Collect target ids and resolve to records.
        let targetIds = joinRows.compactMap { $0[relatedField]?.asString }
        return targetIds.compactMap { target.find(id: $0) }
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
