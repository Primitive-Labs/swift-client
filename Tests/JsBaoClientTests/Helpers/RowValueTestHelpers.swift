import Foundation
@testable import JsBaoClient

/// Test-only shorthand for reading the untyped shapes a query row carries.
///
/// Production code reads related records through `PrimitiveRow.one(_:as:)` /
/// `many(_:as:)`, which decode to a typed model. The tests assert on the raw
/// `_related` payload instead, so they need the array-of-rows form.
extension JSONValue {
    /// The array of rows an include attaches under `_related[key]`; `nil` when
    /// this value isn't an array. Non-object elements are dropped.
    var rowsValue: [[String: JSONValue]]? {
        guard let items = arrayValue else { return nil }
        return items.compactMap { $0.objectValue }
    }
}
