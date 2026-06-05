import Foundation
import YSwift
@testable import JsBaoClient

// MARK: - Test-only TypedModel
//
// `TypedModel<T>` was REMOVED from the client (the app-facing model is now the
// codegen'd type's static `Model.*` API). The codegen round-trip / acceptance
// tests still want a typed per-document wrapper to write a struct and read it
// back typed — that's a *test ergonomic*, not production API. This is a
// test-local re-creation of the removed type, wrapping the public
// `DynamicModel` (the runtime engine). It does not ship in the library.
final class TypedModel<T: PrimitiveModel> {
    let dynamic: DynamicModel

    init(doc: YDocument) {
        self.dynamic = DynamicModel(doc: doc, schema: T.primitiveSchema)
    }

    init(dynamic: DynamicModel) {
        precondition(dynamic.schema.name == T.modelName,
                     "DynamicModel schema name must match T.modelName")
        self.dynamic = dynamic
    }

    @discardableResult
    func create(_ value: T) throws -> T {
        _ = try dynamic.create(id: value.id, values: value.primitiveValues())
        return value
    }

    func find(id: String) -> T? {
        guard let record = dynamic.find(id: id) else { return nil }
        return T(record: record)
    }

    func find(_ id: String) -> T? { find(id: id) }

    func findAll() -> [T] {
        dynamic.findAll().compactMap { T(record: $0) }
    }

    func delete(id: String) { dynamic.delete(id: id) }
    func delete(_ id: String) { delete(id: id) }

    func query(_ filter: DocumentFilter? = nil, options: QueryOptions? = nil) -> [T] {
        dynamic.query(filter, options: options).compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return find(id: id)
        }
    }

    func queryOne(_ filter: DocumentFilter? = nil) -> T? {
        query(filter, options: QueryOptions(limit: 1)).first
    }

    func update(_ id: String, _ updates: [String: Any]) {
        var values: [String: PrimitiveValue] = [:]
        for (key, raw) in updates {
            guard let desc = T.primitiveSchema.fields[key] else { continue }
            if let pv = TestPrimitiveValueBridge.wrap(raw, type: desc.type) {
                values[key] = pv
            }
        }
        try? dynamic.update(id: id, values: values)
    }

    func findByUnique(constraint name: String, value: PrimitiveValue) throws -> T? {
        guard let record = try dynamic.findByUnique(constraint: name, value: value),
              let id = record["id"] as? String else { return nil }
        return find(id: id)
    }

    func findByUnique(constraint name: String, values: [PrimitiveValue]) throws -> T? {
        guard let record = try dynamic.findByUnique(constraint: name, values: values),
              let id = record["id"] as? String else { return nil }
        return find(id: id)
    }

    func insert(_ value: T) { try? create(value) }
}

/// Test-local copy of the removed `PrimitiveValueBridge`, used by the test-only
/// `TypedModel.update(_:_:)` above.
internal enum TestPrimitiveValueBridge {
    static func wrap(_ value: Any, type: PrimitiveFieldType) -> PrimitiveValue? {
        if value is NSNull { return nil }
        switch type {
        case .string:    if let s = value as? String { return .string(s) }
        case .number:
            if let d = value as? Double { return .number(d) }
            if let i = value as? Int    { return .number(Double(i)) }
            if let i = value as? Int64  { return .number(Double(i)) }
        case .boolean:   if let b = value as? Bool { return .boolean(b) }
        case .id:        if let s = value as? String, !s.isEmpty { return .id(s) }
        case .date:      if let s = value as? String { return .date(s) }
        case .stringset:
            if let set = value as? Set<String> { return .stringset(set) }
            if let arr = value as? [String]    { return .stringset(Set(arr)) }
        case .json:
            if let s = value as? String { return .json(Data(s.utf8)) }
            if let d = value as? Data   { return .json(d) }
        }
        return nil
    }
}
