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
    /// The caller supplied an EXPLICIT id (via the model's designated
    /// `init(id:…)` initializer, not the auto-id convenience init), the
    /// `on:` field matched an existing record, and that record's id is
    /// different from the supplied one. Mirrors js-bao's
    /// `"[Model] upsertOn conflict: caller id '<supplied>' does not match
    /// existing record '<existing>'"` thrown from `BaseModel.save` when
    /// `_constructorProvidedId && this.id !== existingId`.
    ///
    /// JS only raises this when the id was *explicitly* passed to the
    /// model constructor; a freshly auto-generated id is silently
    /// discarded on merge. The Swift codegen tracks the same provenance:
    /// the auto-id convenience initializer marks the id non-explicit, so
    /// only a caller who pinned a specific id and then collided trips
    /// this error.
    case explicitIdConflict(supplied: String, existing: String)
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
    /// An explicit `uniqueLookupValue` was supplied but its arity didn't
    /// match the constraint's field count. Mirrors js-bao building the
    /// lookup key from `keyValuesForLookup` per constraint field.
    case lookupValueArityMismatch(constraint: String, expected: Int, got: Int)
    /// An explicit `uniqueLookupValue` disagrees with the value carried
    /// for the same field in `data`. Mirrors js-bao's
    /// `"upsertByUnique: Mismatch between dataToUpsert.'<field>' … and
    /// uniqueLookupValue for constraint '<name>'"` guard.
    case lookupValueMismatch(constraint: String, field: String)
}
