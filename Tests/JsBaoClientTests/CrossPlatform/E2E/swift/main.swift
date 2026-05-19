// Swift mini-app CLI for the cross-language E2E parity harness.
// Mirrors `../js/main.js`; both speak the same JSON-on-stdin /
// JSON-on-stdout protocol. The XCTest driver
// (E2EQueryParityTests.swift) spawns one of each and asserts that
// the same TOML produces the same query results across language
// boundaries.
//
// Commands (one JSON object per stdin line):
//
//   {"cmd":"seed","records":[{...}, ...]}
//     → {"doc":"<base64 Y.Doc update bytes>"}
//
//   {"cmd":"query","doc":"<base64>","filter":{...},
//                  "sort":[{"field":"priority","dir":-1}, ...],
//                  "limit":10,"offset":0}
//     → {"results":[{...}, ...]}
//
//   {"cmd":"find","doc":"<base64>","id":"..."}
//     → {"record":{...}|null}
//
//   {"cmd":"resolveRelationship","doc":"<base64>","model":"users",
//                                "id":"...","relationship":"posts"}
//     → {"results":[{...}, ...]}
//     For refersTo, results has 0 or 1 entry; for hasMany /
//     hasManyThrough / refersToMany, 0..n.
//
// The TaskRecord type used here is generated at build time from
// `Models/schema.toml` by `swift-bao-codegen` (see the
// `E2EMiniApp` target in `Package.swift` — plugins:
// `JsBaoCodegenPlugin`).

import Foundation
import YSwift
import Yniffi
import JsBaoClient

// MARK: - Stdio

func readCommand() -> [String: Any]? {
    guard let line = readLine(strippingNewline: true), !line.isEmpty else {
        return nil
    }
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        emitError("invalid JSON on stdin: \(line)")
        return nil
    }
    return obj
}

func emit(_ obj: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func emitError(_ message: String) -> Never {
    FileHandle.standardError.write(Data("E2EMiniApp(swift): \(message)\n".utf8))
    exit(1)
}

// MARK: - Helpers: Y.Doc <-> base64 update bytes

func decodeDoc(_ base64: String) -> YDocument {
    let doc = YDocument()
    guard let bytes = Data(base64Encoded: base64) else {
        emitError("doc field is not valid base64")
        return doc
    }
    doc.transactSync { txn in
        _ = try? txn.transactionApplyUpdate(update: Array(bytes))
    }
    return doc
}

func encodeDoc(_ doc: YDocument) -> String {
    let bytes = doc.transactSync { txn in
        Data(txn.transactionEncodeStateAsUpdate())
    }
    return bytes.base64EncodedString()
}

// MARK: - Record <-> JSON

/// Convert a `TaskRecord` into a normalized JSON dict that
/// matches the JS side's shape. Stringsets are sorted arrays so
/// equality comparisons across languages don't depend on insertion
/// order.
func taskToJson(_ r: TaskRecord) -> [String: Any] {
    var out: [String: Any] = [
        "id":    r.id,
        "title": r.title,
    ]
    if let v = r.priority   { out["priority"] = v }
    if let v = r.completed  { out["completed"] = v }
    if let v = r.tags       { out["tags"] = Array(v).sorted() }
    if let v = r.createdAt  { out["createdAt"] = v }
    return out
}

/// Build a `[String: PrimitiveValue]` from a JSON record. Used by
/// the seed command to write records into the doc.
func recordToValues(_ json: [String: Any]) -> [String: PrimitiveValue] {
    var out: [String: PrimitiveValue] = [:]
    if let s = json["title"] as? String { out["title"] = .string(s) }
    if let n = json["priority"] as? Double { out["priority"] = .number(n) }
    if let i = json["priority"] as? Int    { out["priority"] = .number(Double(i)) }
    if let b = json["completed"] as? Bool  { out["completed"] = .boolean(b) }
    if let arr = json["tags"] as? [String] { out["tags"] = .stringset(Set(arr)) }
    if let s = json["createdAt"] as? String { out["createdAt"] = .date(s) }
    return out
}

/// Translate the wire-protocol sort array (`[{field, dir}]`) into
/// the runtime's ordered `QueryOptions.sortOrder` array. The
/// dict-form `QueryOptions.sort` doesn't preserve insertion order,
/// so multi-field sorts have to use `sortOrder` for deterministic
/// ordering across Swift and JS clients.
func parseSort(_ arr: [[String: Any]]) -> [(String, Int)] {
    var out: [(String, Int)] = []
    for entry in arr {
        if let f = entry["field"] as? String, let d = entry["dir"] as? Int {
            out.append((f, d))
        }
    }
    return out
}

// MARK: - Modes
//
// The CLI supports two execution paths for every command:
//
//   - "typed"   (default): goes through `TypedModel<TaskRecord>` /
//                          codegen-emitted struct (the canonical path)
//   - "dynamic":           goes through `DynamicModel` with a schema
//                          loaded at runtime from `Models/schema.toml`
//                          via `TomlSchemaLoader` (stringly access via
//                          `PrimitiveRecord`)
//
// Both modes emit the JSON shape expected by `taskToJson(...)` so
// the harness can compare them directly. The `everything` model
// below is exercised by the comprehensive test fixture; only `tasks`
// has a codegen-emitted typed wrapper.
//
// Source-of-truth note: the dynamic-mode schemas come from the SAME
// `Models/schema.toml` file that the codegen plugin consumes at
// build time. Loading at runtime (instead of hand-writing a
// `PrimitiveSchema` literal here) means the typed path and the
// dynamic path can never drift apart — both ultimately reflect
// the TOML.

/// Schemas keyed by model name, loaded once from the bundled
/// `Models/schema.toml` via the runtime `TomlSchemaLoader`.
/// Resolving the path through `#filePath` ties the location to the
/// source layout — the binary always reads the same TOML the
/// codegen plugin consumed.
let dynamicSchemas: [String: PrimitiveSchema] = {
    let tomlURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Models")
        .appendingPathComponent("schema.toml")
    do {
        let schemas = try TomlSchemaLoader.load(from: tomlURL)
        return Dictionary(uniqueKeysWithValues: schemas.map { ($0.name, $0) })
    } catch {
        emitError("failed to load schema.toml at \(tomlURL.path): \(error)")
    }
}()

// MARK: - Field-name → PrimitiveValue normalization
//
// Used by dynamic-mode `cmdSeed*` to convert the JSON record from
// stdin into a `[String: PrimitiveValue]` ready for
// `dynamic.create`. Models that use different field types (numbers
// vs strings vs stringsets) need a schema-aware mapping — this
// helper takes the schema as input and produces the correct
// `PrimitiveValue` for each field.

func recordToValuesForSchema(
    _ json: [String: Any],
    schema: PrimitiveSchema
) -> [String: PrimitiveValue] {
    var out: [String: PrimitiveValue] = [:]
    for (fname, desc) in schema.fields {
        if fname == "id" { continue }  // id is passed separately to .create
        guard let raw = json[fname] else { continue }
        switch desc.type {
        case .id, .string:
            if let s = raw as? String { out[fname] = .string(s) }
        case .number:
            if let n = raw as? Double { out[fname] = .number(n) }
            else if let i = raw as? Int { out[fname] = .number(Double(i)) }
        case .boolean:
            if let b = raw as? Bool { out[fname] = .boolean(b) }
        case .date:
            if let s = raw as? String { out[fname] = .date(s) }
        case .stringset:
            if let arr = raw as? [String] { out[fname] = .stringset(Set(arr)) }
        case .json:
            break  // unused in fixtures
        }
    }
    return out
}

/// Convert a query-row dict (`[String: Any]` from
/// `dynamic.query`) into the harness's normalized JSON shape.
/// Stringsets become sorted arrays; everything else passes through.
/// Internal `_meta_*` columns (added by the shared-engine path
/// when the engine hosts multiple docs) get filtered out — they're
/// not user fields.
func dynamicRowToJson(_ row: [String: Any]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (k, v) in row {
        if k.hasPrefix("_meta_") { continue }
        if let arr = v as? [String] {
            out[k] = arr.sorted()
        } else if let i = v as? Int, !(v is Bool) {
            out[k] = i
        } else {
            out[k] = v
        }
    }
    return out
}

/// Convert a `PrimitiveRecord` (Y.Map view) into the same
/// normalized JSON shape used by typed-mode results. Read every
/// declared field via the appropriate `.asXxx` accessor.
func primitiveRecordToJson(
    _ rec: PrimitiveRecord,
    schema: PrimitiveSchema
) -> [String: Any] {
    var out: [String: Any] = ["id": rec.id]
    for (fname, desc) in schema.fields {
        if fname == "id" { continue }
        switch desc.type {
        case .id:
            if let v = rec[fname]?.asId { out[fname] = v }
        case .string:
            if let v = rec[fname]?.asString { out[fname] = v }
        case .number:
            if let v = rec[fname]?.asNumber {
                // Match typed-mode int/double dispatch: integer-
                // valued doubles emit as plain Int so JSON sees
                // `5` not `5.0`. Mirrors swift-bao-codegen's
                // `formatDouble` and js-bao's behaviour.
                if v.truncatingRemainder(dividingBy: 1) == 0,
                   abs(v) < 1e16 {
                    out[fname] = Int(v)
                } else {
                    out[fname] = v
                }
            }
        case .boolean:
            if let v = rec[fname]?.asBoolean { out[fname] = v }
        case .date:
            if let v = rec[fname]?.asDateString { out[fname] = v }
        case .stringset:
            if let v = rec[fname]?.asStringSet { out[fname] = Array(v).sorted() }
        case .json:
            break  // unused in fixtures
        }
    }
    return out
}

// MARK: - Commands

/// Seed records into a doc. If `existingDoc` is provided, the new
/// records are appended to its existing state — letting callers
/// build a doc up across multiple CLI invocations (Swift seeds A,
/// JS adds B, etc.) to exercise CRDT merge semantics.
func cmdSeed(
    records: [[String: Any]],
    existingDoc: String?,
    mode: String,
    model modelName: String
) {
    let doc = existingDoc.map { decodeDoc($0) } ?? YDocument()
    SchemaSync.clearCache()

    if mode == "dynamic" {
        let schema = schemaForModel(modelName)
        let dyn = DynamicModel(doc: doc, schema: schema)
        for r in records {
            guard let id = r["id"] as? String else {
                emitError("seed record missing id: \(r)")
            }
            do {
                try dyn.create(id: id, values: recordToValuesForSchema(r, schema: schema))
            } catch {
                emitError("seed create failed for id=\(id): \(error)")
            }
        }
    } else {
        // Typed mode currently only supports the `tasks` model —
        // there's no codegen-emitted struct for `everything`.
        // Tests using comprehensive fixture should call dynamic mode.
        guard modelName == "tasks" else {
            emitError("typed mode only supports model='tasks'; use mode='dynamic' for other models")
        }
        let model = TypedModel<TaskRecord>(doc: doc)
        for r in records {
            guard let id = r["id"] as? String else {
                emitError("seed record missing id: \(r)")
            }
            do {
                try model.dynamic.create(id: id, values: recordToValues(r))
            } catch {
                emitError("seed create failed for id=\(id): \(error)")
            }
        }
    }
    emit(["doc": encodeDoc(doc)])
}

func cmdQuery(
    docB64: String,
    filter: [String: Any]?,
    sort: [[String: Any]]?,
    limit: Int?,
    cursor: String?,
    mode: String,
    model modelName: String
) {
    let doc = decodeDoc(docB64)
    SchemaSync.clearCache()
    let opts = QueryOptions(
        sortOrder: sort.map { parseSort($0) },
        limit: limit,
        cursor: cursor
    )
    if mode == "dynamic" {
        let schema = schemaForModel(modelName)
        let dyn = DynamicModel(doc: doc, schema: schema)
        do {
            let page = try dyn.queryPaged(filter, options: opts)
            emitPage(rows: page.data.map(dynamicRowToJson),
                     nextCursor: page.nextCursor)
        } catch {
            emitError("queryPaged failed: \(error)")
        }
    } else {
        guard modelName == "tasks" else {
            emitError("typed mode only supports model='tasks'; use mode='dynamic'")
        }
        let model = TypedModel<TaskRecord>(doc: doc)

        // Two paths through the typed API:
        //
        //   (a) The non-paginated case (no `limit`, no `cursor`) is
        //       what the user-facing typed query looks like — one
        //       call returns `[TaskRecord]` already hydrated. This is
        //       the closest Swift analog to JS's
        //       `await TaskRecord.query(filter)` and is what we want
        //       readers of this CLI to see when comparing the two
        //       languages' code samples.
        //
        //   (b) The paginated case has to fall through to
        //       `model.dynamic.queryPaged(...)` because
        //       `TypedModel<T>.query` doesn't currently expose the
        //       `nextCursor` from the paged result — it returns
        //       `[T]`, dropping the cursor on the floor. The cursor
        //       pagination test (`testCursorPaginationAgreesAcrossLanguages`)
        //       relies on `nextCursor` being round-tripped, so we
        //       drop down for that flow only. If/when `TypedModel`
        //       grows a `queryPaged(...) -> (data: [T], nextCursor: String?)`
        //       overload, this branch can collapse into the (a) path.
        let isPaginated = limit != nil || cursor != nil
        if !isPaginated {
            // (a) user-facing typed query — JS-parity ergonomic.
            let results: [TaskRecord] = model.query(filter, options: opts)
            emitPage(rows: results.map(taskToJson), nextCursor: nil)
        } else {
            // (b) cursor/limit pagination — drop to dynamic + cast.
            do {
                let page = try model.dynamic.queryPaged(filter, options: opts)
                let results = page.data.compactMap(TaskRecord.init(row:))
                emitPage(rows: results.map(taskToJson),
                         nextCursor: page.nextCursor)
            } catch {
                emitError("queryPaged failed: \(error)")
            }
        }
    }
}

/// Emit a paged result. `nextCursor` is included only when present
/// so the JSON shape stays minimal for non-paginating callers.
func emitPage(rows: [[String: Any]], nextCursor: String?) {
    var out: [String: Any] = ["results": rows]
    if let nextCursor { out["nextCursor"] = nextCursor }
    emit(out)
}

func cmdFind(docB64: String, id: String, mode: String, model modelName: String) {
    let doc = decodeDoc(docB64)
    SchemaSync.clearCache()
    if mode == "dynamic" {
        let schema = schemaForModel(modelName)
        let dyn = DynamicModel(doc: doc, schema: schema)
        if let rec = dyn.find(id: id) {
            emit(["record": primitiveRecordToJson(rec, schema: schema)])
        } else {
            emit(["record": NSNull()])
        }
    } else {
        guard modelName == "tasks" else {
            emitError("typed mode only supports model='tasks'; use mode='dynamic'")
        }
        let model = TypedModel<TaskRecord>(doc: doc)
        if let r = model.find(id: id) {
            emit(["record": taskToJson(r)])
        } else {
            emit(["record": NSNull()])
        }
    }
}

/// **Inspect command — wire-byte equality.** Returns the
/// *decoded* value stored under each declared field of the record's
/// nested Y.Map. The Swift Yniffi FFI surfaces stored values as
/// their JSON-encoded form (`"\"hello\""` for a string), while
/// js-bao's Yjs surfaces them already JSON-decoded (`"hello"`) —
/// even though the on-wire bytes are identical. We decode here so
/// both sides emit the same native shape, which is what
/// cross-language tests need to compare.
///
/// Stringsets dump their nested-Y.Map sorted key list (or for
/// JS-written docs, the plain-Y.Object key list — see the
/// _KNOWN_DIVERGENCE tests).
func cmdInspect(docB64: String, id: String, model modelName: String) {
    let doc = decodeDoc(docB64)
    let schema = schemaForModel(modelName)
    var fields: [String: Any] = [:]
    doc.transactSync { txn in
        guard let root = txn.transactionGetMap(name: modelName),
              let rec = root.getMap(tx: txn, key: id) else {
            return
        }
        for (fname, desc) in schema.fields {
            if desc.type == .stringset {
                if let nested = rec.getMap(tx: txn, key: fname) {
                    let collector = KeyCollector()
                    nested.keys(tx: txn, delegate: collector)
                    fields[fname] = collector.keys.sorted()
                }
            } else {
                guard let raw = try? rec.get(tx: txn, key: fname) else {
                    continue
                }
                // Decode through PrimitiveValue so the emitted shape
                // matches js-bao's Yjs Map.get(key) return value.
                if let v = PrimitiveValue.decode(yrsString: raw, as: desc.type) {
                    switch v {
                    case let .string(s):  fields[fname] = s
                    case let .number(n):
                        // Match js-bao: integer-valued doubles emit
                        // as plain Int.
                        if n.truncatingRemainder(dividingBy: 1) == 0,
                           abs(n) < 1e16 {
                            fields[fname] = Int(n)
                        } else {
                            fields[fname] = n
                        }
                    case let .boolean(b): fields[fname] = b
                    case let .id(s):      fields[fname] = s
                    case let .date(s):    fields[fname] = s
                    default:              fields[fname] = raw
                    }
                } else {
                    fields[fname] = raw
                }
            }
        }
    }
    emit(["fields": fields])
}

/// Pick the right schema given a model name. `tasks` exists in
/// both modes; `everything` is dynamic-only (no codegen).
func schemaForModel(_ name: String) -> PrimitiveSchema {
    guard let schema = dynamicSchemas[name] else {
        emitError("unknown model: \(name) (loaded: \(dynamicSchemas.keys.sorted()))")
    }
    return schema
}

/// Resolve a relationship by name on the record `id` of `modelName`.
/// Routes to the appropriate `PrimitiveRecord` accessor based on the
/// relationship's declared `type` and converts the resolved
/// `PrimitiveRecord`(s) into the harness's normalized JSON shape.
///
/// Always emits `{ "results": [...] }`. For `refersTo` the array has
/// 0 or 1 entries; for `hasMany` / `hasManyThrough` / `refersToMany`,
/// 0..n. Uniform shape keeps the JS↔Swift parity assertions simple.
func cmdResolveRelationship(
    docB64: String,
    modelName: String,
    id: String,
    relationship: String
) {
    let doc = decodeDoc(docB64)
    SchemaSync.clearCache()

    let sourceSchema = schemaForModel(modelName)
    guard let rel = sourceSchema.relationships[relationship] else {
        emitError("unknown relationship '\(relationship)' on model '\(modelName)'")
    }
    guard let relType = rel.properties["type"] else {
        emitError("relationship '\(relationship)' missing 'type'")
    }
    guard let targetModelName = rel.properties["model"] else {
        emitError("relationship '\(relationship)' missing 'model'")
    }

    let sourceModel = DynamicModel(doc: doc, schema: sourceSchema)
    let targetSchema = schemaForModel(targetModelName)
    let targetModel = DynamicModel(doc: doc, schema: targetSchema)

    guard let sourceRec = sourceModel.find(id: id) else {
        emit(["results": [Any]()])
        return
    }

    do {
        let resolved: [PrimitiveRecord]
        switch relType {
        case "refersTo":
            if let r = try sourceRec.refersTo(
                relationship: relationship, target: targetModel
            ) {
                resolved = [r]
            } else {
                resolved = []
            }
        case "hasMany":
            resolved = try sourceRec.hasMany(
                relationship: relationship, target: targetModel
            )
        case "hasManyThrough":
            guard let joinModelName = rel.properties["joinModel"] else {
                emitError("hasManyThrough '\(relationship)' missing 'joinModel'")
            }
            let joinSchema = schemaForModel(joinModelName)
            let joinModel = DynamicModel(doc: doc, schema: joinSchema)
            resolved = try sourceRec.hasManyThrough(
                relationship: relationship,
                joinModel: joinModel,
                target: targetModel
            )
        case "refersToMany":
            resolved = try sourceRec.refersToMany(
                relationship: relationship, target: targetModel
            )
        default:
            emitError("unsupported relationship type '\(relType)'")
        }

        let rows = resolved.map { primitiveRecordToJson($0, schema: targetSchema) }
        emit(["results": rows])
    } catch {
        emitError("resolveRelationship failed: \(error)")
    }
}

private final class KeyCollector: YrsMapIteratorDelegate {
    var keys: [String] = []
    func call(value: String) { keys.append(value) }
}

// MARK: - Main loop

while let cmd = readCommand() {
    guard let kind = cmd["cmd"] as? String else {
        emitError("missing cmd field: \(cmd)")
    }

    let mode      = (cmd["mode"]  as? String) ?? "typed"
    let modelName = (cmd["model"] as? String) ?? "tasks"

    switch kind {
    case "seed":
        let records = (cmd["records"] as? [[String: Any]]) ?? []
        let existingDoc = cmd["doc"] as? String
        cmdSeed(records: records, existingDoc: existingDoc,
                mode: mode, model: modelName)

    case "query":
        guard let docB64 = cmd["doc"] as? String else {
            emitError("query: missing doc")
        }
        let filter = cmd["filter"] as? [String: Any]
        let sort   = cmd["sort"]   as? [[String: Any]]
        let limit  = cmd["limit"]  as? Int
        let cursor = cmd["cursor"] as? String
        cmdQuery(docB64: docB64, filter: filter, sort: sort,
                 limit: limit, cursor: cursor,
                 mode: mode, model: modelName)

    case "find":
        guard let docB64 = cmd["doc"] as? String,
              let id = cmd["id"] as? String else {
            emitError("find: missing doc/id")
        }
        cmdFind(docB64: docB64, id: id, mode: mode, model: modelName)

    case "inspect":
        guard let docB64 = cmd["doc"] as? String,
              let id = cmd["id"] as? String else {
            emitError("inspect: missing doc/id")
        }
        cmdInspect(docB64: docB64, id: id, model: modelName)

    case "resolveRelationship":
        guard let docB64 = cmd["doc"] as? String,
              let id = cmd["id"] as? String,
              let relationship = cmd["relationship"] as? String else {
            emitError("resolveRelationship: missing doc/id/relationship")
        }
        cmdResolveRelationship(
            docB64: docB64, modelName: modelName,
            id: id, relationship: relationship
        )

    default:
        emitError("unknown cmd: \(kind)")
    }
}
