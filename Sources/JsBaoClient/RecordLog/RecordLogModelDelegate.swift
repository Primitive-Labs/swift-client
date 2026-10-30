import Foundation
import YSwift

/// What a model's reads and writes do when its document is a record-log
/// (format-3) one: reads answer from the document's view, filtered reads too
/// (with the room's statement, ``RecordLogViewReader``), and every write is an
/// entry the store commits with its guess on the view.
///
/// Values are spelled as format 1 spells them (`PrimitiveValue.encodedForYrs`
/// and `PrimitiveValue.decode`), so one schema and one decoder describe every
/// format. A model's declaration reaches the room in `record.declare`, never
/// through the `YDocument`: a format-3 document carries no Yjs traffic.
///
/// A view of the binding; it holds no state of its own.
final class RecordLogModelDelegate: LocalRecordDelegate {

    let binding: RecordLogDocumentBinding
    let schema: PrimitiveSchema

    var modelName: String { schema.name }

    /// Bind `schema` to the document (its query tables rebuilt from the view
    /// when they do not hold it).
    init(binding: RecordLogDocumentBinding, schema: PrimitiveSchema) throws {
        self.binding = binding
        self.schema = schema
        try binding.registerModel(schema)
    }

    private var stringSetFields: [String] {
        schema.fields.compactMap { $0.value.type == .stringset ? $0.key : nil }.sorted()
    }

    private var store: RecordLogStore { binding.store }

    // MARK: - Reads

    /// The record as this document's view holds it — or, inside a
    /// `transact` on this thread, as the transaction's saves leave it.
    func row(id: String) throws -> [String: JSONValue]? {
        if let staged = binding.stagedRow(RecordLogRecordKey(model: modelName, id: id)) { return staged }
        return try store.read(model: modelName, id: id)
    }

    /// The row a handle reads: the record's own, or — when the room applied
    /// an upsert of this client's under this id to another record — that one.
    private func handleRow(id: String) throws -> [String: JSONValue]? {
        if let row = try row(id: id) { return row }
        guard let target = binding.aliasTarget(model: modelName, id: id) else { return nil }
        return try row(id: target)
    }

    /// This document, narrowed by what the caller asked for.
    private func scope(narrowedTo requested: [String]?) -> [String] {
        guard let requested else { return [binding.documentId] }
        return requested.contains(binding.documentId) ? [binding.documentId] : []
    }

    /// The reader over this document's view, narrowed to `requested`.
    private func reader(_ requested: [String]?) -> RecordLogViewReader {
        RecordLogViewReader(store: store, documents: scope(narrowedTo: requested))
    }

    /// How the model API answers a record: declared sets as arrays, the document tagged.
    private var shape: RecordLogViewReader.RowShape { .model(setFields: Set(stringSetFields)) }

    // The filtered reads answer from the document's view with the room's
    // statement and the db3 limits (``RecordLogViewReader``).

    func query(filter: DocumentFilter?, options: QueryOptions?) throws -> [[String: JSONValue]] {
        try query(filter: filter, options: options, include: nil)
    }

    func query(filter: DocumentFilter?, options: QueryOptions?, include: [Include]?) throws -> [[String: JSONValue]] {
        try reader(options?.documentScope()).page(modelName, filter ?? [:], options: options, shape: shape, include: include).rows
    }

    func queryPaged(filter: DocumentFilter?, options: QueryOptions?) throws -> PagedQueryResult<PrimitiveRow> {
        try queryPaged(filter: filter, options: options, include: nil)
    }

    func queryPaged(filter: DocumentFilter?, options: QueryOptions?, include: [Include]?) throws -> PagedQueryResult<PrimitiveRow> {
        RecordLogViewReader.paged(
            try reader(options?.documentScope()).page(modelName, filter ?? [:], options: options, shape: shape, include: include)
        )
    }

    func count(filter: DocumentFilter?) throws -> Int {
        try reader(nil).count(modelName, filter ?? [:])
    }

    func aggregate(_ options: AggregateOptions) throws -> [[String: JSONValue]] {
        try reader(resolvedDocumentScope(documents: options.documents, db3: options.db3))
            .aggregate(modelName, options, setFields: Set(stringSetFields))
    }

    func exists(id: String) throws -> Bool { try row(id: id) != nil }

    func allIds() throws -> [String] {
        var ids: [String] = []
        var after: String?
        while true {
            let page = try store.recordIdsAfter(model: modelName, after: after, limit: 1_000)
            ids.append(contentsOf: page)
            guard page.count == 1_000, let last = page.last else { return ids }
            after = last
        }
    }

    /// The raw JSON spelling of one field, as the nested-map path would have
    /// handed it back.
    func readRaw(id: String, field: String) throws -> String? {
        guard let value = try handleRow(id: id)?[field], value != .null else { return nil }
        return RecordLogJSON.text(value)
    }

    /// The members of a string-set field, in code-point order.
    func members(id: String, field: String) throws -> [String] {
        try handleRow(id: id)?[field]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// The id of the record of this model whose `fields` hold `values` in the
    /// view — or, inside a `transact` on this thread, as the transaction's
    /// saves leave it: a record it saved holding them is the holder, and a
    /// view holder it deleted or changed no longer is.
    func findId(fields: [String], values: [PrimitiveValue]) throws -> String? {
        let json = values.compactMap(Self.jsonValue)
        guard json.count == fields.count else { return nil }
        let staged = binding.stagedRows(model: modelName)
        for (id, row) in staged {
            guard let row else { continue }
            if zip(fields, json).allSatisfy({ row[$0.0] == $0.1 }) { return id }
        }
        guard let holder = try store.findIdByFields(model: modelName, fields: fields, values: json) else { return nil }
        return staged.contains { $0.id == holder } ? nil : holder
    }

    func fieldNames(id: String) throws -> Set<String> {
        guard let row = try handleRow(id: id) else { return [] }
        var names = Set<String>()
        for (field, value) in row where field != "id" && value != .null {
            if case .array(let items) = value, items.isEmpty { continue }
            names.insert(field)
        }
        return names
    }

    // MARK: - Writes

    /// One local write, as one entry. A create carries every value; a patch
    /// the values given, a string set as member deltas against the view (a
    /// member another device added is not removed because this caller did not
    /// name it).
    @discardableResult
    func write(id: String, values: [String: PrimitiveValue], isUpdate: Bool, upsertOn: String?) throws -> Int? {
        try write(id: id, values: values, isUpdate: isUpdate, upsertOn: upsertOn, guards: RecordLogWriteGuards())
    }

    /// ``write(id:values:isUpdate:upsertOn:)`` carrying the write's guards:
    /// `condition` rides the mutation, `ifNotExists` makes it a create of the
    /// whole state whatever the view holds. The room judges both.
    ///
    /// `cleared` names the fields an update sets to nil: each is touched with
    /// no value, which the plan writes as `null` (a string set as the removal
    /// of every member the view holds).
    @discardableResult
    func write(
        id: String, values: [String: PrimitiveValue], isUpdate: Bool, upsertOn: String?, guards: RecordLogWriteGuards,
        cleared: Set<String> = []
    ) throws -> Int? {
        var dataToSave: [String: JSONValue] = ["id": .string(id)]
        var stringSetChanges: [String: (additions: [String], removals: [String])] = [:]
        let existing = isUpdate ? try row(id: id) : nil
        let clearedFields = isUpdate ? cleared.filter { $0 != "id" && values[$0] == nil }.sorted() : []
        for name in clearedFields where stringSetFields.contains(name) {
            stringSetChanges[name] = (additions: [], removals: recordLogCanonicalStringSet(Set(try self.members(id: id, field: name))))
        }
        for (name, value) in values where name != "id" {
            if case let .stringset(members) = value {
                dataToSave[name] = .array(recordLogCanonicalStringSet(members).map { .string($0) })
                if isUpdate {
                    let held = Set(try self.members(id: id, field: name))
                    stringSetChanges[name] = (
                        additions: recordLogCanonicalStringSet(members.subtracting(held)),
                        removals: recordLogCanonicalStringSet(held.subtracting(members))
                    )
                }
            } else {
                dataToSave[name] = try Self.wireValue(value, field: name, model: modelName, documentId: binding.documentId)
            }
        }
        let mutation = planRecordLogSave(RecordLogSaveInput(
            model: modelName, recordId: id, existing: isUpdate ? (existing ?? ["id": .string(id)]) : nil,
            dataToSave: dataToSave, touchedFields: values.keys.filter { $0 != "id" } + clearedFields,
            stringSetChanges: stringSetChanges, stringSetFieldNames: Set(stringSetFields), guards: guards
        ))
        return try commit([mutation], upsertOn: isUpdate ? nil : upsertOn, existing: existing)
    }

    /// Add each of `fields` to the record's field (0 when not a number), as one
    /// increment entry, inside the document's operation — or, inside a
    /// `transact` on this thread, folded into the transaction's entry. A
    /// record neither the view nor the transaction holds is refused
    /// `.db3RecordNotFound`, and a result that would not be finite
    /// `.documentEntryInvalid`, both before anything is sent and both reported
    /// as `DocumentWriteRefusedEvent`. Answers each field's new value as this
    /// device now shows it, and the entry's `seq` (`nil` when a transaction
    /// holds it).
    func increment(id: String, fields: [String: Double], condition: JSONValue?) throws -> (values: [String: Double], seq: Int?) {
        let mutation = planRecordLogIncrement(
            model: modelName, recordId: id, fields: fields.mapValues { .number($0) }, condition: condition
        )
        let report: (DocumentWriteRefusedEvent) -> Void = { [binding] event in binding.reportRefused(event) }
        func refuse(_ code: JsBaoErrorCode, _ message: String) -> JsBaoError {
            let error = JsBaoError(code: code, message: message, details: ["documentId": .string(binding.documentId), "scope": "local"])
            report(recordLogLocalRefusal(error, documentId: binding.documentId, mutations: [mutation]))
            return error
        }
        return try binding.withOperation {
            try assertRecordLogEntry(documentId: binding.documentId, mutations: [mutation], report: report)
            guard let existing = try row(id: id) else {
                throw refuse(
                    .db3RecordNotFound,
                    "Cannot increment \(modelName) \(id) in `\(binding.documentId)`: no such record here (never created, or deleted). Nothing was sent."
                )
            }
            for (field, delta) in fields.sorted(by: { $0.key < $1.key })
            where !(recordLogNumeric(existing[field]) + delta).isFinite {
                throw refuse(.documentEntryInvalid, "Cannot increment \(modelName) \(id): increment of `\(field)` overflows. Nothing was sent.")
            }
            let after = recordLogPlainRowAfter(existing, mutation) ?? existing
            let values = Dictionary(uniqueKeysWithValues: fields.keys.map { ($0, recordLogNumeric(after[$0])) })
            if binding.stage(mutation, upsertOn: nil, existing: existing) { return (values, nil) }
            try assertRecordLogDeclaredTypes(documentId: binding.documentId, mutations: [mutation], type: binding.declaredType, report: report)
            let seq = try binding.commit([RecordLogWrite(mutations: [mutation])]).first?.seq
            return (values, seq)
        }
    }

    /// Clear one field: `null` for a scalar, every member removed for a string set.
    func clearField(id: String, field: String) throws {
        if schema.fields[field]?.type == .stringset {
            let held = try members(id: id, field: field)
            guard !held.isEmpty else { return }
            try commit([RecordLogMutation(
                model: modelName, id: id, kind: .patch,
                stringSetDeltas: [field: Dictionary(held.map { ($0, false) }, uniquingKeysWith: { first, _ in first })]
            )])
            return
        }
        try commit([RecordLogMutation(model: modelName, id: id, kind: .patch, fields: [field: .null])])
    }

    /// Add ONE member: a patch carrying one member delta, so two devices adding
    /// different members both land. The record must exist; `maxCount` is
    /// checked against the view inside the document's operation.
    func addMember(id: String, field: String, member: String, maxCount: Int?) throws {
        try binding.withOperation {
            guard try exists(id: id) else { throw Self.noSuchRecord(id, model: modelName) }
            let held = try members(id: id, field: field)
            if let maxCount {
                let willHave = held.contains(member) ? held.count : held.count + 1
                if willHave > maxCount {
                    throw FieldValidationError.stringsetMaxCountExceeded(
                        field: field, modelName: modelName, limit: maxCount, got: willHave
                    )
                }
            }
            try commit([RecordLogMutation(model: modelName, id: id, kind: .patch, stringSetDeltas: [field: [member: true]])])
        }
    }

    /// Remove ONE member. A member the record does not hold is a no-op.
    @discardableResult
    func removeMember(id: String, field: String, member: String) throws -> Bool {
        try binding.withOperation {
            guard try exists(id: id) else { throw Self.noSuchRecord(id, model: modelName) }
            guard try members(id: id, field: field).contains(member) else { return false }
            try commit([RecordLogMutation(model: modelName, id: id, kind: .patch, stringSetDeltas: [field: [member: false]])])
            return true
        }
    }

    func delete(id: String) throws {
        try commit([planRecordLogDelete(model: modelName, recordId: id)])
    }

    /// A delete carrying `condition`, which the room judges; answers the entry's `seq`.
    @discardableResult
    func delete(id: String, condition: JSONValue?) throws -> Int? {
        try commit([planRecordLogDelete(model: modelName, recordId: id, condition: condition)])
    }

    /// Run a mutation whose public entry point cannot throw. A refusal has
    /// already been reported as a `DocumentWriteRefusedEvent` where it was
    /// made, so nothing is lost by swallowing it here.
    func quietly(recordId: String, _ body: () throws -> Void) {
        _ = recordId
        do { try body() } catch {}
    }

    func settle() {}

    /// A format-3 document declares its models in `record.declare`; the
    /// `YDocument` is never written.
    func publishDeclaration(doc: YDocument, schema: PrimitiveSchema) {}

    func constraintInForce(_ name: String) -> Bool { binding.constraintInForce(name) }

    var viewStore: RecordLogStore { binding.store }

    func withOperation<T>(_ body: () throws -> T) throws -> T {
        try binding.withOperation(body)
    }

    /// Check an entry and commit it, answering its seq — or, inside a
    /// `transact` on this thread, hold it for the transaction's one entry.
    @discardableResult
    private func commit(
        _ mutations: [RecordLogMutation], upsertOn: String? = nil, existing: RecordLogRow?? = nil
    ) throws -> Int? {
        let base: RecordLogRow?
        if let existing { base = existing } else { base = try row(id: mutations[0].id) }
        if binding.stage(mutations[0], upsertOn: upsertOn, existing: base) { return nil }
        try assertRecordLogEntry(documentId: binding.documentId, mutations: mutations, upsertOn: upsertOn) { [binding] event in
            binding.reportRefused(event)
        }
        // A typed db3's declarations, as the room judges the entry (#5020); a
        // transaction's are judged whole when it commits.
        try assertRecordLogDeclaredTypes(documentId: binding.documentId, mutations: mutations, type: binding.declaredType) { [binding] event in
            binding.reportRefused(event)
        }
        return try binding.commit([RecordLogWrite(mutations: mutations, upsertOn: upsertOn)]).first?.seq
    }

    private static func noSuchRecord(_ id: String, model: String) -> JsBaoError {
        JsBaoError(code: .notFound, message: "Record `\(id)` not found on model `\(model)`")
    }

    // MARK: - Value bridging

    /// A field's value as the entry carries it — the JSON format 1 stores —
    /// keeping a non-finite number so the entry check refuses it rather than
    /// the value being dropped.
    static func wireValue(
        _ value: PrimitiveValue, field: String, model: String, documentId: String
    ) throws -> JSONValue {
        switch value {
        case .number(let number) where !number.isFinite:
            return .number(number)
        case .stringset(let members):
            return .array(recordLogCanonicalStringSet(members).map { .string($0) })
        default:
            guard let json = jsonValue(value) else {
                throw JsBaoError(
                    code: .documentEntryInvalid,
                    message: "Cannot save \(model).\(field): its value is not JSON the room can carry.",
                    details: ["documentId": .string(documentId), "scope": "local", "field": .string(field)]
                )
            }
            return json
        }
    }

    /// The JSON a field is stored as, the nested-map path's spelling.
    static func jsonValue(_ value: PrimitiveValue) -> JSONValue? {
        guard let encoded = value.encodedForYrs() else { return nil }
        return JSONValue(jsonText: encoded)
    }
}
