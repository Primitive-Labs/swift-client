import Foundation
import YSwift
import Yniffi

/// A full set of discovered model schemas keyed by model name. Mirrors
/// js-bao's `DiscoveredSchema` — see `/tmp/js-bao-ref/yDocSchema.ts`.
public struct DiscoveredSchema: Equatable, Sendable {
    public var models: [String: PrimitiveSchema]

    public init(models: [String: PrimitiveSchema] = [:]) {
        self.models = models
    }
}

/// Reads `_meta_*` YMaps back into `PrimitiveSchema` values. Mirrors
/// js-bao's `discoverSchema` read path, including the infer-from-sampled-
/// records fallback when no `_meta_*` exists for a given model.
///
/// The `modelNames` parameter on every entry point exists because Yniffi's
/// current FFI does not expose yrs's `Doc.root_refs()` — we can't
/// enumerate top-level shared types from the Swift side yet. Callers pass
/// the candidate names they care about; names without data or metadata
/// simply yield no entry in the result.
public enum SchemaDiscovery {

    public static func discoverSchema(
        doc: YDocument,
        modelNames: [String]
    ) -> DiscoveredSchema {
        return doc.transactSync { txn in
            var out: [String: PrimitiveSchema] = [:]
            for name in modelNames {
                // Skip internal-prefixed names entirely — these are never
                // a valid top-level model in the `_meta_*` protocol.
                if name.hasPrefix("_") { continue }
                if let schema = discoverModel(name: name, transaction: txn) {
                    out[name] = schema
                }
            }
            return DiscoveredSchema(models: out)
        }
    }

    // MARK: - Per-model discovery

    private static func discoverModel(
        name: String,
        transaction txn: YrsTransaction
    ) -> PrimitiveSchema? {
        // 1. Explicit `_meta_{name}` → decode from YMap.
        if let meta = txn.transactionGetMap(name: "_meta_\(name)") {
            return readModelMeta(name: name, meta: meta, tx: txn)
        }

        // 2. Fallback: sample a data map with the same name and infer
        //    types from record values.
        if let data = txn.transactionGetMap(name: name) {
            return inferModelFromData(name: name, dataMap: data, tx: txn)
        }

        return nil
    }

    // MARK: - _meta_* decode

    private static func readModelMeta(
        name: String,
        meta: YrsMap,
        tx: YrsTransaction
    ) -> PrimitiveSchema {
        var fields: [String: FieldDescriptor] = [:]
        var constraints: [String: ConstraintDescriptor] = [:]
        var relationships: [String: RelationshipDescriptor] = [:]

        let collector = KeyCollector()
        meta.keys(tx: tx, delegate: collector)

        for key in collector.keys {
            if key == "_constraints" {
                if let c = meta.getMap(tx: tx, key: key) {
                    constraints = readConstraints(cMap: c, tx: tx)
                }
            } else if key == "_relationships" {
                if let r = meta.getMap(tx: tx, key: key) {
                    relationships = readRelationships(rMap: r, tx: tx)
                }
            } else if let fieldMap = meta.getMap(tx: tx, key: key) {
                fields[key] = readFieldMeta(fieldMap: fieldMap, tx: tx)
            }
            // else: scalar value at the top of _meta_*, which shouldn't
            // happen in a valid _meta_ layout — skip quietly.
        }

        return PrimitiveSchema(
            name: name,
            fields: fields,
            constraints: constraints,
            relationships: relationships
        )
    }

    private static func readFieldMeta(
        fieldMap: YrsMap,
        tx: YrsTransaction
    ) -> FieldDescriptor {
        let typeRaw = decodeString(fieldMap.value(tx: tx, key: "type")) ?? "unknown"
        let type = PrimitiveFieldType(rawValue: typeRaw) ?? .string
        let indexed    = decodeBool(fieldMap.value(tx: tx, key: "indexed"))    ?? false
        let unique     = decodeBool(fieldMap.value(tx: tx, key: "unique"))     ?? false
        let required   = decodeBool(fieldMap.value(tx: tx, key: "required"))   ?? false
        let autoAssign = decodeBool(fieldMap.value(tx: tx, key: "autoAssign")) ?? false
        let maxLength  = decodeNumber(fieldMap.value(tx: tx, key: "maxLength")).map { Int($0) }
        let maxCount   = decodeNumber(fieldMap.value(tx: tx, key: "maxCount")).map { Int($0) }

        var defaultValue: DefaultValue? = nil
        if let raw = fieldMap.value(tx: tx, key: "default") {
            defaultValue = decodeDefault(raw)
        }

        // Auto-stamp policy round-trips through `_meta` as a string —
        // mirrors js-bao `metaSync.ts`. Unknown values decode to `nil`.
        let autoStamp = decodeString(fieldMap.value(tx: tx, key: "autoStamp"))
            .flatMap(AutoStamp.init(rawValue:))

        return FieldDescriptor(
            type: type,
            indexed: indexed,
            unique: unique,
            required: required,
            autoAssign: autoAssign,
            maxLength: maxLength,
            maxCount: maxCount,
            default: defaultValue,
            autoStamp: autoStamp
        )
    }

    private static func readConstraints(
        cMap: YrsMap,
        tx: YrsTransaction
    ) -> [String: ConstraintDescriptor] {
        let collector = KeyCollector()
        cMap.keys(tx: tx, delegate: collector)
        var out: [String: ConstraintDescriptor] = [:]
        for name in collector.keys {
            guard let child = cMap.getMap(tx: tx, key: name) else { continue }
            let type = decodeString(child.value(tx: tx, key: "type")) ?? "unknown"
            let fieldsJson = decodeString(child.value(tx: tx, key: "fields")) ?? "[]"
            let fields = ConstraintDescriptor.decodeFields(fieldsJson)
            out[name] = ConstraintDescriptor(name: name, type: type, fields: fields)
        }
        return out
    }

    private static func readRelationships(
        rMap: YrsMap,
        tx: YrsTransaction
    ) -> [String: RelationshipDescriptor] {
        let collector = KeyCollector()
        rMap.keys(tx: tx, delegate: collector)
        var out: [String: RelationshipDescriptor] = [:]
        for name in collector.keys {
            guard let child = rMap.getMap(tx: tx, key: name) else { continue }
            let childKeys = KeyCollector()
            child.keys(tx: tx, delegate: childKeys)
            var props: [String: String] = [:]
            for k in childKeys.keys {
                if let s = decodeString(child.value(tx: tx, key: k)) {
                    props[k] = s
                }
            }
            out[name] = RelationshipDescriptor(properties: props)
        }
        return out
    }

    // MARK: - Fallback inference

    /// Sample up to 5 records and infer field types from values. Mirrors
    /// the fallback in js-bao's `yDocSchema.ts#inferModelFromData`.
    private static func inferModelFromData(
        name: String,
        dataMap: YrsMap,
        tx: YrsTransaction
    ) -> PrimitiveSchema? {
        let recordKeys = KeyCollector()
        dataMap.keys(tx: tx, delegate: recordKeys)
        if recordKeys.keys.isEmpty { return nil }

        var fields: [String: FieldDescriptor] = [:]
        var sampled = 0
        for recordKey in recordKeys.keys {
            if sampled >= 5 { break }
            guard let record = dataMap.getMap(tx: tx, key: recordKey) else { continue }
            sampled += 1

            let fieldKeys = KeyCollector()
            record.keys(tx: tx, delegate: fieldKeys)
            for fieldName in fieldKeys.keys {
                if fieldName.hasPrefix("_") { continue }
                if fields[fieldName] != nil { continue } // first-type-wins
                if let type = inferTypeFromValue(
                    jsonString: record.value(tx: tx, key: fieldName),
                    nestedMap: record.getMap(tx: tx, key: fieldName) != nil
                ) {
                    fields[fieldName] = FieldDescriptor(type: type)
                }
            }
        }

        if fields.isEmpty { return nil }
        return PrimitiveSchema(name: name, fields: fields)
    }

    private static func inferTypeFromValue(
        jsonString: String?,
        nestedMap: Bool
    ) -> PrimitiveFieldType? {
        if nestedMap { return .stringset }
        guard let s = jsonString else { return nil }
        if s == "true" || s == "false" { return .boolean }
        if Double(s) != nil { return .number }
        if PrimitiveValue.decodeJsonString(s) != nil { return .string }
        return nil
    }

    // MARK: - Value decoders

    private static func decodeString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return PrimitiveValue.decodeJsonString(raw)
    }

    private static func decodeBool(_ raw: String?) -> Bool? {
        switch raw {
        case "true":  return true
        case "false": return false
        default:      return nil
        }
    }

    private static func decodeNumber(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        return Double(raw)
    }

    private static func decodeDefault(_ raw: String) -> DefaultValue? {
        if let s = PrimitiveValue.decodeJsonString(raw) {
            return DefaultValue.decode(fromMeta: s)
        }
        if raw == "true" { return .scalar(.boolean(true)) }
        if raw == "false" { return .scalar(.boolean(false)) }
        if let n = Double(raw) { return .scalar(.number(n)) }
        return nil
    }

    // MARK: - Key collector delegate

    private final class KeyCollector: YrsMapIteratorDelegate {
        var keys: [String] = []
        func call(value: String) { keys.append(value) }
    }
}

// Thin accessor so we can `?` through a missing key without try/do.
private extension YrsMap {
    func value(tx: YrsTransaction, key: String) -> String? {
        try? self.get(tx: tx, key: key)
    }
}
