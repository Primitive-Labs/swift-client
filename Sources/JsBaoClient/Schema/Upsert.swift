import Foundation

/// Outcome of a `DynamicModel.upsert(...)` call.
public struct UpsertResult {
    public let record: PrimitiveRecord
    /// `true` if a new record was inserted; `false` if an existing
    /// record was found and merged into.
    public let wasCreated: Bool
}

/// Errors specific to the inline upsert path — distinct from
/// `UniqueConstraintViolationError`, which still fires when the upsert
/// would violate OTHER unique constraints.
public enum UpsertError: Error, Equatable, Sendable {
    /// The values dict does not contain the `on:` field.
    case missingField(field: String)
    /// The `on:` field is present but holds null/empty data. Matches
    /// js-bao's `upsertValue === null || undefined || ""` guard.
    case nullOrEmptyField(field: String)
    /// No single-field unique constraint is registered on the `on:`
    /// field. Compound uniques are not a valid upsert target (per
    /// js-bao's `constraint.fields.length === 1` requirement).
    case noSingleFieldUniqueConstraint(field: String)
    /// The caller supplied an id that doesn't match the id of the
    /// existing record matched by the upsertOn value.
    case idMismatch(supplied: String, existing: String)
}

/// Mode for `DynamicModel.upsertByUnique`. Matches js-bao's option
/// flags (`objectMustExist` / `objectMustNotExist`).
public enum UpsertMode: Sendable, Equatable {
    /// Insert when absent, merge into existing when present (default).
    case either
    /// Update only — throw `UpsertByUniqueError.recordNotFound` when no
    /// record is found by the given constraint key.
    case mustExist
    /// Insert only — throw `UniqueConstraintViolationError` when a
    /// record already holds the constraint key.
    case mustNotExist
}

/// Errors specific to `upsertByUnique`. Disjoint from
/// `UpsertError` (inline upsertOn) and `FindByUniqueError`
/// (constraint-name lookup), though those are also reachable from the
/// `upsertByUnique` call path.
public enum UpsertByUniqueError: Error, Equatable, Sendable {
    /// The `data` dict doesn't include a field required by the
    /// constraint — we can't construct the lookup key.
    case missingConstraintField(field: String)
    /// Mode `.mustExist` selected but no existing record matches.
    case recordNotFound(constraint: String)
}
