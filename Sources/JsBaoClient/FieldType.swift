import Foundation

/// Storage-level field type used by the SQLite mirror (`BaoModelQueryEngine`)
/// and the runtime-schema layer (`DynamicModel` maps a `PrimitiveSchema`
/// field to one of these via `toLegacyFieldType()`).
public enum FieldType {
    case string
    case number
    case boolean
    case json  // stored as JSON string, parsed as Any
}
