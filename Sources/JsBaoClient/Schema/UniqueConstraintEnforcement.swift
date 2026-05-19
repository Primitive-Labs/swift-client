import Foundation
import YSwift
import Yniffi

/// Thrown by `DynamicModel.create` / `update` when a write would
/// collide with an existing record on one of the resolved unique
/// constraints. Mirrors js-bao's `UniqueConstraintViolationError`.
public struct UniqueConstraintViolationError: Error, Equatable, Sendable {
    public let modelName: String
    public let constraintName: String
    public let fields: [String]
    public let attemptedRecordId: String
    public let existingRecordId: String

    public var localizedDescription: String {
        "Unique constraint '\(constraintName)' violated for model '\(modelName)' "
        + "on fields [\(fields.joined(separator: ", "))]. "
        + "Attempted id \(attemptedRecordId); existing record \(existingRecordId) "
        + "already holds this value."
    }
}

/// Errors from `DynamicModel.findByUnique`.
public enum FindByUniqueError: Error, Equatable, Sendable {
    /// No constraint registered under the given name.
    case constraintNotFound(String)
    /// The caller supplied the wrong number of positional values for
    /// the compound constraint's field count.
    case fieldCountMismatch(expected: Int, got: Int)
}

/// Helpers for the yjs-side unique index mechanism.
///
/// js-bao stores one Y.Map per constraint named
/// `_uniqueIdx_{modelName}_{constraintName}`, keyed by the unique key
/// string (single-field: `String(value)`; compound:
/// `JSON.stringify(values)`), valued by the record id owning that key.
/// See `js-bao/src/models/BaseModel.ts` save/delete paths.
internal enum UniqueIndex {

    /// The Y.Map name that hosts the index for a given constraint.
    static func mapName(modelName: String, constraintName: String) -> String {
        "_uniqueIdx_\(modelName)_\(constraintName)"
    }

    /// Build the unique key for a set of fields against a data dict.
    /// Returns `nil` if any field is absent — matches js-bao's null
    /// semantics (nulls disable the constraint for that record).
    static func buildKey(
        fields: [String],
        values: [String: PrimitiveValue]
    ) -> String? {
        if fields.isEmpty { return nil }
        var vals: [PrimitiveValue] = []
        for f in fields {
            guard let v = values[f] else { return nil }
            vals.append(v)
        }
        if fields.count == 1 {
            // `String(value)` in JS: stringify the scalar as a bare value
            // (no surrounding quotes).
            return stringify(vals[0])
        }
        // `JSON.stringify(values)` in JS: JSON array with minimal
        // formatting, matching what js-bao emits.
        let parts = vals.map { jsonStringify($0) }
        return "[" + parts.joined(separator: ",") + "]"
    }

    /// JS `String(v)` semantics for the single-field case.
    private static func stringify(_ v: PrimitiveValue) -> String {
        switch v {
        case let .string(s):    return s
        case let .id(s):        return s
        case let .date(s):      return s
        case let .boolean(b):   return b ? "true" : "false"
        case let .number(n):    return PrimitiveValue.encodeNumber(n) ?? "null"
        case let .stringset(s): return "[" + s.sorted().joined(separator: ",") + "]"
        case .json:             return ""  // no js-bao precedent; avoid key collisions
        }
    }

    /// JS `JSON.stringify(v)` semantics for values inside a compound key.
    private static func jsonStringify(_ v: PrimitiveValue) -> String {
        switch v {
        case let .string(s):    return PrimitiveValue.jsonEncodeString(s)
        case let .id(s):        return PrimitiveValue.jsonEncodeString(s)
        case let .date(s):      return PrimitiveValue.jsonEncodeString(s)
        case let .boolean(b):   return b ? "true" : "false"
        case let .number(n):    return PrimitiveValue.encodeNumber(n) ?? "null"
        case let .stringset(s):
            let parts = s.sorted().map { PrimitiveValue.jsonEncodeString($0) }
            return "[" + parts.joined(separator: ",") + "]"
        case .json:
            return "null"
        }
    }
}
