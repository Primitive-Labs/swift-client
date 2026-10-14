import Foundation
import YSwift

/// What a model's reads and writes do when its document is a record-log
/// (format-3) one: reads answer from the document's view, filtered reads from
/// the query tables the view is projected into, and every write is an entry
/// the store commits with its guess on the view.
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

    func requireProjection() throws {
        guard binding.isProjected(modelName) else {
            throw JsBaoError(
                code: .format2ModelNotHydrated,
                message: "`\(modelName)` in document `\(binding.documentId)` is not projected into the query "
                    + "tables, so a filtered read cannot answer from them. Reopen the document; `find(id:)` and "
                    + "`findAll()` read the document's own store.",
                details: ["model": .string(modelName), "documentId": .string(binding.documentId)]
            )
        }
    }

    /// This document, narrowed by what the caller asked for: the query tables
    /// hold every document's rows, so this one is the ceiling.
    private func scope(narrowedTo requested: [String]?) -> [String] {
        guard let requested else { return [binding.documentId] }
        return requested.contains(binding.documentId) ? [binding.documentId] : []
    }

    private static func scoped(_ options: QueryOptions?, to documents: [String]) -> QueryOptions {
        var scoped = options ?? QueryOptions()
        scoped.documents = documents
        return scoped
    }

    func query(filter: DocumentFilter?, options: QueryOptions?) throws -> [[String: JSONValue]] {
        try requireProjection()
        return try binding.engine.query(
            modelName: modelName, filter: filter,
            options: Self.scoped(options, to: scope(narrowedTo: options?.documents)),
            stringsetFields: Set(stringSetFields)
        )
    }

    func queryPaged(filter: DocumentFilter?, options: QueryOptions?) throws -> PagedQueryResult<PrimitiveRow> {
        try requireProjection()
        return try binding.engine.queryPaged(
            modelName: modelName, filter: filter,
            options: Self.scoped(options, to: scope(narrowedTo: options?.documents)),
            stringsetFields: Set(stringSetFields)
        )
    }

    func count(filter: DocumentFilter?) throws -> Int {
        try requireProjection()
        return try binding.engine.count(
            modelName: modelName, filter: filter,
            stringsetFields: Set(stringSetFields), documents: [binding.documentId]
        )
    }

    func aggregate(_ options: AggregateOptions) throws -> [[String: JSONValue]] {
        try requireProjection()
        var narrowed = options
        narrowed.documents = scope(narrowedTo: options.documents)
        return try binding.engine.aggregate(
            modelName: modelName, options: narrowed,
            stringsetFields: Set(stringSetFields), documents: narrowed.documents
        )
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
        var dataToSave: [String: JSONValue] = ["id": .string(id)]
        var stringSetChanges: [String: (additions: [String], removals: [String])] = [:]
        let existing = isUpdate ? try row(id: id) : nil
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
            dataToSave: dataToSave, touchedFields: values.keys.filter { $0 != "id" },
            stringSetChanges: stringSetChanges, stringSetFieldNames: Set(stringSetFields)
        ))
        return try commit([mutation], upsertOn: isUpdate ? nil : upsertOn, existing: existing)
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

    var queryEngine: BaoModelQueryEngine { binding.engine }

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
        try assertRecordLogEntry(documentId: binding.documentId, mutations: mutations) { [binding] event in
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
