import Foundation

/// What a model's reads and writes do when the document behind them is a
/// large one (#3436, decision 3436-SO-04).
///
/// A format-1 document keeps its records as nested Y.Maps — `{model}` →
/// `{id}` → fields — and `DynamicModel` reads and writes them directly. A
/// large document has none of that: its Y.Doc holds only the current epoch's
/// OVERLAY, and the records live in SQL tables the fold maintains. So every
/// entry point that would have touched a nested map comes here instead, and
/// that includes the accessors a `PrimitiveRecord` handle uses — a `find` that
/// succeeded and then answered empty fields is worse than one that failed.
///
/// The delegate is a VIEW of the binding and holds no state of its own, so a
/// fold that breaks, a hold that is set, or a purge that unbinds are visible
/// through it at once.
///
/// **Values are spelled exactly as format 1 spells them.** Every conversion
/// goes through `PrimitiveValue.encodedForYrs()` / `PrimitiveValue.decode`,
/// the same pair the nested-map path uses, so the two layouts hold the same
/// JSON for the same value — which is what lets one schema, one decoder and
/// one set of tests describe both, and what keeps the Swift rows equal to the
/// TypeScript client's.
final class Format2ModelDelegate: @unchecked Sendable {

    let binding: Format2DocumentBinding
    let schema: PrimitiveSchema

    var modelName: String { schema.name }

    init(binding: Format2DocumentBinding, schema: PrimitiveSchema) {
        self.binding = binding
        self.schema = schema
        // Watch this model's overlay map, fold whatever it already holds, and
        // project the result. A model registered after the bind has missed
        // every update so far, so registering without folding would leave its
        // records out of the merged view — and out of the query tables the
        // projection then marks as done.
        binding.registerModel(schema)
    }

    /// The stringset fields of this schema — the ones that live in the member
    /// index rather than in the row.
    private var stringSetFields: [String] {
        schema.fields.compactMap { $0.value.type == .stringset ? $0.key : nil }
    }

    // MARK: - Reads

    /// The merged row, or `nil` when the document does not hold the record.
    /// Refuses with `FORMAT2_FOLD_BROKEN` when the merged view is known wrong.
    func row(id: String) throws -> [String: JSONValue]? {
        binding.settleFolds()
        return try binding.observer.read(model: modelName, recordId: id)
    }

    // MARK: - Filtered reads

    /// The documents this read may answer from: this one.
    private var scope: [String] { [binding.documentId] }

    /// This document, NARROWED by what the caller asked for (#3760).
    ///
    /// The query tables hold every large document of the store, so this
    /// delegate's own document is the ceiling — a member of A must never
    /// answer B's rows. Within that, `documents` means what it means
    /// everywhere else: naming another document narrows to nothing, and an
    /// explicit empty list matches nothing. Before #3760 the caller's value
    /// was simply overwritten here, so a read asking for B was answered with
    /// A's rows; now the two disagree loudly (empty) rather than quietly.
    private func scope(narrowedTo requested: [String]?) -> [String] {
        guard let requested else { return scope }
        return requested.contains(binding.documentId) ? scope : []
    }

    /// Refuse a filtered read this model cannot answer.
    ///
    /// The rows live in the query tables and a fold keeps them current; if the
    /// projection has not committed — the connect's copy failed, and left no
    /// mark — the tables hold nothing for this document and the read would
    /// silently answer short. It says so instead.
    func requireProjection() throws {
        binding.settleFolds()
        try binding.observer.assertWritable()
        // A model a capped load left out is the same wrong answer arriving
        // through a different door (#3437, behavior 34). Its projection mark
        // may well be there — it was made when the document connected, before
        // the load decided what this device could hold — and the rows behind
        // it are whatever a later overlay happened to touch, not the model.
        guard try binding.store.isHydrated(modelName) else {
            throw JsBaoError(
                code: .format2ModelNotHydrated,
                message: "`\(modelName)` in large document `\(binding.documentId)` "
                    + "is not held on this device: the snapshot did not fit, so "
                    + "this model was left out. `find(id:)` and a filtered read "
                    + "both refuse rather than answer from a fragment.",
                details: [
                    "model": .string(modelName),
                    "documentId": .string(binding.documentId),
                ]
            )
        }
        guard binding.isProjected(modelName) else {
            throw JsBaoError(
                code: .format2ModelNotHydrated,
                message: "`\(modelName)` in large document `\(binding.documentId)` is "
                    + "not projected into the query tables, so a filtered read "
                    + "cannot answer from them. Reopen the document; `find(id:)` "
                    + "and `findAll()` read the document's own store.",
                details: [
                    "model": .string(modelName),
                    "documentId": .string(binding.documentId),
                ]
            )
        }
    }

    func query(
        filter: DocumentFilter?, options: QueryOptions?
    ) throws -> [[String: JSONValue]] {
        try requireProjection()
        return try binding.projection.engine.query(
            modelName: modelName, filter: filter,
            options: Self.scoped(options, to: scope(narrowedTo: options?.documents)),
            stringsetFields: stringSetFieldSet
        )
    }

    func queryPaged(
        filter: DocumentFilter?, options: QueryOptions?
    ) throws -> PagedQueryResult<PrimitiveRow> {
        try requireProjection()
        return try binding.projection.engine.queryPaged(
            modelName: modelName, filter: filter,
            options: Self.scoped(options, to: scope(narrowedTo: options?.documents)),
            stringsetFields: stringSetFieldSet
        )
    }

    func count(filter: DocumentFilter?) throws -> Int {
        try requireProjection()
        return try binding.projection.engine.count(
            modelName: modelName, filter: filter,
            stringsetFields: stringSetFieldSet, documents: scope
        )
    }

    func aggregate(_ options: AggregateOptions) throws -> [[String: JSONValue]] {
        try requireProjection()
        var narrowed = options
        narrowed.documents = scope(narrowedTo: options.documents)
        return try binding.projection.engine.aggregate(
            modelName: modelName, options: narrowed,
            stringsetFields: stringSetFieldSet, documents: narrowed.documents
        )
    }

    /// The caller's options, scoped to `documents`.
    ///
    /// `QueryOptions.documents` is the engine's existing several-document
    /// scope (`WHERE _meta_doc_id IN (…)`), which is what the query tables
    /// need: they hold every large document's rows, including documents this
    /// read must not answer from because they are closed.
    static func scoped(_ options: QueryOptions?, to documents: [String]) -> QueryOptions {
        var scoped = options ?? QueryOptions()
        scoped.documents = documents
        return scoped
    }

    private var stringSetFieldSet: Set<String> { Set(stringSetFields) }

    func exists(id: String) throws -> Bool {
        try row(id: id) != nil
    }

    func allIds() throws -> [String] {
        try binding.observer.assertWritable()
        return try binding.store.recordIds(model: modelName)
    }

    /// The raw JSON spelling of one field, as the nested-map path would have
    /// handed it back from the FFI — so the caller's existing decode applies
    /// unchanged.
    func readRaw(id: String, field: String) throws -> String? {
        guard let row = try row(id: id), let value = row[field], value != .null else {
            return nil
        }
        return Self.rawJSON(value)
    }

    /// The members of a stringset field, in rowid order.
    func members(id: String, field: String) throws -> [String] {
        try binding.observer.assertWritable()
        return try binding.store.members(model: modelName, recordId: id, field: field)
    }

    /// The id of the record holding `values` on `fields`, if any — the
    /// uniqueness question, asked of the whole merged view rather than of an
    /// index map a large document does not keep.
    ///
    /// A value that has no scalar JSON spelling (a stringset) makes the
    /// constraint unanswerable here, and `nil` is "no owner": the same null
    /// semantics the nested-map path gets from `buildKey` returning nil.
    func findId(fields: [String], values: [PrimitiveValue]) throws -> String? {
        try binding.observer.assertWritable()
        let json = values.compactMap { Self.jsonValue($0) }
        guard json.count == fields.count else { return nil }
        return try binding.store.findIdByFields(
            model: modelName, fields: fields, values: json
        )
    }

    /// Every field the record carries: the row's own keys, plus any stringset
    /// the member index holds for it.
    func fieldNames(id: String) throws -> Set<String> {
        guard let row = try row(id: id) else { return [] }
        var names = Set(row.keys.filter { row[$0] != .null })
        for field in stringSetFields where !(try members(id: id, field: field).isEmpty) {
            names.insert(field)
        }
        return names
    }

    // MARK: - Writes

    /// One local write, through the document's serialized
    /// commit-then-publish operation.
    ///
    /// `isUpdate` decides the mutation's kind, and the difference is not
    /// cosmetic: a create REPLACES whatever the overlay held for the id, so a
    /// re-created record does not inherit a tombstone or a stale field, while
    /// a patch touches only the fields it names.
    func write(id: String, values: [String: PrimitiveValue], isUpdate: Bool) throws {
        var fields: [String: JSONValue] = [:]
        var stringSetDeltas: [String: [String: Bool]] = [:]
        for (name, value) in values where name != "id" {
            if case let .stringset(members) = value {
                var delta: [String: Bool] = [:]
                if isUpdate {
                    // A full-set assignment on a PATCH is a diff against what
                    // the merged view holds, exactly as the nested-map path
                    // diffs against the existing Y.Map: a member another device
                    // added concurrently is not dropped because this caller did
                    // not name it.
                    let existing = Set(try self.members(id: id, field: name))
                    for member in members.subtracting(existing) { delta[member] = true }
                    for member in existing.subtracting(members) { delta[member] = false }
                } else {
                    // A create REPLACES the record, and the fold drops every
                    // member the base row held before it applies these entries
                    // (`_replace` → `deleteAllMembers`). So a replacement has to
                    // name every member it wants present, not only the ones that
                    // are new: a diff would leave a re-created record with the
                    // members it happened to gain and none of the ones it kept.
                    for member in members { delta[member] = true }
                }
                if !delta.isEmpty { stringSetDeltas[name] = delta }
            } else if let json = Self.jsonValue(value) {
                fields[name] = json
            }
        }
        try commit(
            OverlayMutation(
                id: id,
                kind: isUpdate ? .patch : .create,
                fields: fields,
                stringSetDeltas: stringSetDeltas
            ),
            fields: Array(fields.keys) + Array(stringSetDeltas.keys)
        )
    }

    /// Remove one field. An explicit unset, not an absence: the overlay holds
    /// a null for the key, and the fold applies it as `json_patch`'s removal.
    func clearField(id: String, field: String) throws {
        guard schema.fields[field]?.type == .stringset else {
            try commit(
                OverlayMutation(id: id, kind: .patch, fields: [field: .null]),
                fields: [field]
            )
            return
        }
        let existing = try members(id: id, field: field)
        guard !existing.isEmpty else { return }
        try commit(
            OverlayMutation(
                id: id,
                kind: .patch,
                stringSetDeltas: [
                    field: Dictionary(uniqueKeysWithValues: existing.map { ($0, false) }),
                ]
            ),
            fields: [field]
        )
    }

    /// Add ONE member to a stringset field, leaving the rest of the set alone.
    ///
    /// The nested-map path writes a single `insert` into the field's member
    /// map; the overlay's equivalent is a `patch` carrying one member key,
    /// which converges the same way — two devices adding different members
    /// both land, because the keys are different.
    ///
    /// The record must exist, exactly as it must on the nested-map path, and
    /// the `maxCount` check is made against the merged view under the
    /// document's operation so it cannot be raced by a concurrent add.
    func addMember(
        id: String, field: String, member: String, maxCount: Int?
    ) throws {
        try refuseIfStopped()
        binding.settleFolds()
        try binding.writePath.withOperation {
            guard try exists(id: id) else { throw Self.noSuchRecord(id, model: modelName) }
            let existing = try members(id: id, field: field)
            if let maxCount {
                let willHave = existing.contains(member)
                    ? existing.count : existing.count + 1
                if willHave > maxCount {
                    throw FieldValidationError.stringsetMaxCountExceeded(
                        field: field, modelName: modelName,
                        limit: maxCount, got: willHave
                    )
                }
            }
            try binding.writePath.commitInsideOperation(
                model: modelName,
                mutation: OverlayMutation(
                    id: id, kind: .patch, stringSetDeltas: [field: [member: true]]
                ),
                fields: [field]
            )
        }
    }

    /// Remove ONE member. A tombstone on that member's key alone.
    ///
    /// - Returns: whether anything was written. A member the record does not
    ///   hold is a no-op, as it is on the nested-map path, so it leaves no
    ///   pending op and sends no frame.
    @discardableResult
    func removeMember(id: String, field: String, member: String) throws -> Bool {
        try refuseIfStopped()
        binding.settleFolds()
        return try binding.writePath.withOperation {
            guard try exists(id: id) else { throw Self.noSuchRecord(id, model: modelName) }
            guard try members(id: id, field: field).contains(member) else { return false }
            try binding.writePath.commitInsideOperation(
                model: modelName,
                mutation: OverlayMutation(
                    id: id, kind: .patch, stringSetDeltas: [field: [member: false]]
                ),
                fields: [field]
            )
            return true
        }
    }

    /// Refuse before the operation starts when the room has replaced the epoch
    /// this overlay belongs to, so a refused member write leaves no pending op
    /// and publishes nothing — what ``Format2WritePath/write`` does for every
    /// other write.
    private func refuseIfStopped() throws {
        if let stopped = binding.writePath.stoppedReason { throw stopped }
        try binding.observer.assertWritable()
    }

    private static func noSuchRecord(_ id: String, model: String) -> JsBaoError {
        JsBaoError(
            code: .notFound,
            message: "Record `\(id)` not found on model `\(model)`"
        )
    }

    func delete(id: String) throws {
        try commit(OverlayMutation(id: id, kind: .delete), fields: [])
    }

    /// Run a mutation whose PUBLIC entry point cannot throw (#3437,
    /// behavior 2a).
    ///
    /// `DynamicModel.delete(id:)` is declared without `throws`, and a
    /// `PrimitiveRecord` field assignment and an explicit clear swallow the
    /// error with `try?`. Past the offline window every one of them is refused
    /// — so without a channel an application cannot tell a refused mutation
    /// from a completed one, and a delete that did nothing looks exactly like
    /// a delete that worked.
    ///
    /// SWALLOWS ONLY, since #3758. The window refusal is reported by the write
    /// path's gate, which is the one place every door runs through — throwing
    /// or not — so a second report here would be a second copy of one rule,
    /// and a second chance for the doors to disagree about it. `recordId` is
    /// kept because the caller reads as a pair with the mutation it wraps.
    ///
    /// Every other error keeps the handling #3436 left it: a stopped
    /// document's delete is still a quiet no-op, because the channel is the
    /// window's and not a second reporting path for everything that can go
    /// wrong on a mutation.
    func quietly(recordId: String, _ body: () throws -> Void) {
        _ = recordId
        do {
            try body()
        } catch {
            // As before: `try?`'s behavior, kept deliberately.
        }
    }

    @discardableResult
    private func commit(_ mutation: OverlayMutation, fields: [String]) throws -> Int {
        try binding.writePath.write(model: modelName, mutation: mutation, fields: fields)
    }

    // MARK: - Value bridging

    /// The JSON a field is stored as. `nil` for a value the nested-map path
    /// would also refuse to write as a scalar (a stringset, or a non-finite
    /// number), which the caller routes elsewhere or skips.
    static func jsonValue(_ value: PrimitiveValue) -> JSONValue? {
        guard let encoded = value.encodedForYrs(),
              let data = encoded.data(using: .utf8)
        else { return nil }
        return try? JSONCoding.decodeData(JSONValue.self, from: data)
    }

    /// The raw JSON text of a stored value — what the FFI would have handed
    /// back for the same field on a format-1 document.
    static func rawJSON(_ value: JSONValue) -> String? {
        guard let data = try? JSONCoding.encodeData(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
