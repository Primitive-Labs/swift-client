import Foundation
import YSwift
import Yniffi

/// Writes `_meta_*` YMaps into a YDoc, byte-compatibly with js-bao's
/// `syncModelMeta`. See `/tmp/js-bao-ref/metaSync.ts` for the source of
/// truth.
///
/// Semantics preserved:
///  - Only truthy boolean flags are written (absence = false).
///  - Defaults encode as raw scalars; function defaults become `"$name"`.
///  - Single-field uniques live on the field; only compound (>=2 fields)
///    go in `_constraints`.
///  - `_constraints.<name>.fields` is stored as a JSON-encoded STRING.
///  - Additive: never deletes existing keys.
///  - Idempotent: relies on the CRDT's `try_update` no-op semantics, plus
///    a session cache keyed by (YDocument identity, model name) to skip
///    redundant traversals entirely.
public enum SchemaSync {

    // Session cache: (YDocument → Set<synced modelName>).
    // Matches js-bao's WeakMap<Y.Doc, Set<string>>. Uses NSMapTable with
    // weak keys so entries auto-evict when the doc deallocates — otherwise
    // a deallocated YDocument's ObjectIdentifier can get re-issued to a
    // fresh YDocument and produce false cache hits across tests. (Ask me
    // how I know.)
    private static let cache = NSMapTable<YDocument, NSMutableSet>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: .strongMemory
    )
    private static let cacheLock = NSLock()

    // MARK: - Public API

    /// Sync the given schema's metadata into `_meta_{schema.name}` on the
    /// doc. Opens a transaction if not already in one.
    public static func syncModelMeta(doc: YDocument, schema: PrimitiveSchema) {
        if cachedContains(doc: doc, model: schema.name) {
            return
        }

        doc.transactSync { txn in
            syncModelMeta(doc: doc, schema: schema, transaction: txn)
        }

        cachedInsert(doc: doc, model: schema.name)
    }

    /// Same as above, but reuses an existing transaction. Prefer this
    /// form when already inside a `transactSync` / `transactAsync` block.
    public static func syncModelMeta(
        doc: YDocument,
        schema: PrimitiveSchema,
        transaction txn: YrsTransaction
    ) {
        let meta = txn.transactionGetOrInsertMap(name: "_meta_\(schema.name)")

        for (fieldName, fieldDesc) in schema.fields {
            syncFieldMeta(meta: meta, name: fieldName, desc: fieldDesc, tx: txn)
        }

        // Compound constraints only: length >= 2. Single-field uniques
        // live on the field itself.
        let compound = schema.constraints.values.filter { $0.fields.count > 1 }
        if !compound.isEmpty {
            let constraints = meta.getOrInsertMap(tx: txn, key: "_constraints")
            for c in compound {
                syncConstraintMeta(parent: constraints, desc: c, tx: txn)
            }
        }

        if !schema.relationships.isEmpty {
            let rels = meta.getOrInsertMap(tx: txn, key: "_relationships")
            for (relName, relDesc) in schema.relationships {
                syncRelationshipMeta(parent: rels, name: relName, desc: relDesc, tx: txn)
            }
        }
    }

    /// Infer a minimal `_meta_{modelName}` map from a sample record's
    /// values. Mirrors js-bao's `syncInferredMeta` (metaSync.ts lines
    /// 221–246):
    ///
    ///  - Skips field names that start with `_`.
    ///  - Only writes `type` if the field's map doesn't already have
    ///    one (never clobbers an explicit schema).
    ///  - Only four runtime types map to a wire type:
    ///    string / number / boolean / stringset. `.date` / `.id` /
    ///    `.json` don't infer — the field is skipped (same as js-bao).
    public static func syncInferredMeta(
        doc: YDocument,
        modelName: String,
        recordData: [String: PrimitiveValue]
    ) {
        doc.transactSync { txn in
            let meta = txn.transactionGetOrInsertMap(name: "_meta_\(modelName)")
            for (fieldName, value) in recordData {
                if fieldName.hasPrefix("_") { continue }
                // js-bao's metaSync.ts (lines 232-236) creates the
                // nested field Y.Map BEFORE checking inference; we do
                // the same so the `_meta_` shape is byte-compatible
                // even for fields whose runtime type doesn't infer.
                let fieldMap = meta.getOrInsertMap(tx: txn, key: fieldName)
                guard let inferred = inferWireType(for: value) else { continue }
                // Only write `type` if absent.
                if (try? fieldMap.get(tx: txn, key: "type")) == nil {
                    _ = fieldMap.tryUpdate(
                        tx: txn,
                        key: "type",
                        value: PrimitiveValue.jsonEncodeString(inferred)
                    )
                }
            }
        }
    }

    /// Mirrors js-bao's `inferFieldType`: only four runtime value
    /// shapes yield a wire type.
    private static func inferWireType(for value: PrimitiveValue) -> String? {
        switch value {
        case .string:    return "string"
        case .number:    return "number"
        case .boolean:   return "boolean"
        case .stringset: return "stringset"
        case .date, .id, .json: return nil
        }
    }

    /// Clear the session cache for a single doc, or for all docs when
    /// called with no argument. Useful for tests and for callers that
    /// mutate a schema at runtime.
    public static func clearCache(doc: YDocument? = nil) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let doc {
            cache.removeObject(forKey: doc)
        } else {
            cache.removeAllObjects()
        }
    }

    // MARK: - Field / Constraint / Relationship writers

    private static func syncFieldMeta(
        meta: YrsMap,
        name: String,
        desc: FieldDescriptor,
        tx: YrsTransaction
    ) {
        let fieldMeta = meta.getOrInsertMap(tx: tx, key: name)

        // Required: always write type
        setScalar(fieldMeta, key: "type", value: desc.type.rawValue, tx: tx)

        // Only truthy boolean flags
        if desc.indexed    { setScalar(fieldMeta, key: "indexed",    value: true, tx: tx) }
        if desc.unique     { setScalar(fieldMeta, key: "unique",     value: true, tx: tx) }
        if desc.required   { setScalar(fieldMeta, key: "required",   value: true, tx: tx) }
        if desc.autoAssign { setScalar(fieldMeta, key: "autoAssign", value: true, tx: tx) }

        // Auto-stamp policy — mirrors js-bao `metaSync.ts`
        // (`if (fieldOpts.autoStamp) setIfChanged(fieldMeta, "autoStamp", ...)`).
        if let autoStamp = desc.autoStamp {
            setScalar(fieldMeta, key: "autoStamp", value: autoStamp.rawValue, tx: tx)
        }

        if let maxLength = desc.maxLength {
            setScalar(fieldMeta, key: "maxLength", value: Double(maxLength), tx: tx)
        }
        if let maxCount = desc.maxCount {
            setScalar(fieldMeta, key: "maxCount", value: Double(maxCount), tx: tx)
        }

        if let def = desc.default {
            setScalar(fieldMeta, key: "default", anyValue: def.encodedForMeta(), tx: tx)
        }
    }

    private static func syncConstraintMeta(
        parent: YrsMap,
        desc: ConstraintDescriptor,
        tx: YrsTransaction
    ) {
        let cMeta = parent.getOrInsertMap(tx: tx, key: desc.name)
        setScalar(cMeta, key: "type", value: desc.type, tx: tx)
        // JSON-encoded string, NOT a Y.Array — matches js-bao exactly.
        setScalar(cMeta, key: "fields", value: desc.fieldsJson, tx: tx)
    }

    private static func syncRelationshipMeta(
        parent: YrsMap,
        name: String,
        desc: RelationshipDescriptor,
        tx: YrsTransaction
    ) {
        let relMeta = parent.getOrInsertMap(tx: tx, key: name)
        for (key, value) in desc.properties {
            setScalar(relMeta, key: key, value: value, tx: tx)
        }
    }

    // MARK: - Primitive writers (route typed values through the Rust FFI)

    /// Set a String value (JSON-encoded on the wire).
    private static func setScalar(
        _ map: YrsMap, key: String, value: String, tx: YrsTransaction
    ) {
        _ = map.tryUpdate(tx: tx, key: key, value: PrimitiveValue.jsonEncodeString(value))
    }

    /// Set a Bool value.
    private static func setScalar(
        _ map: YrsMap, key: String, value: Bool, tx: YrsTransaction
    ) {
        _ = map.tryUpdate(tx: tx, key: key, value: value ? "true" : "false")
    }

    /// Set a Double value. Skip non-finite values (NaN, ±Infinity)
    /// since they can't be JSON-encoded — yrs FFI parses every
    /// scalar as JSON and would panic. Schema-default validation
    /// keeps this path from seeing non-finite inputs in practice.
    private static func setScalar(
        _ map: YrsMap, key: String, value: Double, tx: YrsTransaction
    ) {
        guard let encoded = PrimitiveValue.encodeNumber(value) else { return }
        _ = map.tryUpdate(tx: tx, key: key, value: encoded)
    }

    /// Set a heterogeneous `Any` value produced by `DefaultValue.encodedForMeta()`.
    private static func setScalar(
        _ map: YrsMap, key: String, anyValue: Any, tx: YrsTransaction
    ) {
        if let s = anyValue as? String {
            setScalar(map, key: key, value: s, tx: tx)
        } else if let b = anyValue as? Bool {
            setScalar(map, key: key, value: b, tx: tx)
        } else if let n = anyValue as? Double {
            setScalar(map, key: key, value: n, tx: tx)
        } else if let n = anyValue as? Int {
            setScalar(map, key: key, value: Double(n), tx: tx)
        }
        // Anything else (e.g. NSNull) is dropped silently — matches
        // js-bao's `encodeDefault` returning `undefined` for null/unknown.
    }

    // MARK: - Cache helpers

    private static func cachedContains(doc: YDocument, model: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache.object(forKey: doc)?.contains(model) ?? false
    }

    private static func cachedInsert(doc: YDocument, model: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let set = cache.object(forKey: doc) {
            set.add(model)
        } else {
            let set = NSMutableSet()
            set.add(model)
            cache.setObject(set, forKey: doc)
        }
    }
}
