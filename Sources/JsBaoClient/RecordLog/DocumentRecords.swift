import Foundation

/// The records of one open format-3 document by model name, with no model
/// class: from `client.db3.records(db3Id)`.
///
/// Any model of the document can be written and read, declared or not. A
/// field holds a ``DocumentRecordValue``: a string, a number, a boolean,
/// `null` or a string set, and a set can be edited in place with
/// `.setChange(add:remove:clear:)`. A vector field the db3's type or a
/// registered model declares (#5225) is written as `.vector([Float])` and read
/// as an array of its numbers (`floatArrayValue`); any other field is left as
/// it is stored. Reads answer from the document's local
/// copy at once, offline too; writes show there at once and reach the room
/// when the client is connected.
///
/// ```swift
/// let records = client.db3.records(db3Id)
/// let note = try records.put("Note", ["title": "Groceries", "tags": ["home"]])
/// try records.patch("Note", id: note["id"]!.stringValue!, ["tags": .setChange(add: ["weekly"])])
/// let page = try records.query("Note", ["tags": ["$contains": "home"]], options: QueryOptions(limit: 20))
/// let stop = try records.subscribe("Note") { print("notes changed") }
/// ```
///
/// Every call resolves the document when it runs: a document that is not
/// open throws `.notFound`, and one that is not format 3 throws
/// `.documentFormatMismatch`, so a handle kept across a close works again
/// after the document is reopened. A db3 stays readable after its close while
/// its store is bound here; a read of one whose rows have not loaded on this
/// device throws `.db3NotResident`, and a write to it is queued. A write the room would refuse (a name that
/// is not an identifier, a reserved field name, an empty id) throws
/// `.documentEntryInvalid` before anything is sent and is reported once as a
/// `DocumentWriteRefusedEvent`; a write the room hands back arrives as that
/// event too, and the `confirm:` overloads throw it.
public final class DocumentRecords: Sendable {
    /// The document.
    public let documentId: String
    private let resolve: @Sendable () throws -> RecordLogDocumentBinding
    /// The binding a read goes through: a db3 whose rows have not loaded is refused there.
    private let readable: @Sendable () throws -> RecordLogDocumentBinding
    private let logger: Logger?

    init(
        documentId: String, logger: Logger? = nil,
        readable: (@Sendable () throws -> RecordLogDocumentBinding)? = nil,
        binding resolve: @escaping @Sendable () throws -> RecordLogDocumentBinding
    ) {
        self.documentId = documentId
        self.logger = logger
        self.resolve = resolve
        self.readable = readable ?? resolve
    }

    // MARK: - Writes

    /// Create a record of `model`, replacing any record its id names. The id
    /// is `data["id"]` when it is a non-empty string, else a new ULID. Every
    /// field travels; a string set's members are added, a set change's `add`
    /// members only. Answers the record as the local copy shows it after the write.
    @discardableResult
    public func put(_ model: String, _ data: [String: DocumentRecordValue]) throws -> PrimitiveRow {
        let id: String
        if case .string(let given)? = data["id"], !given.isEmpty { id = given } else { id = ULID.generate() }
        return PrimitiveRow(raw: try write(.put, model, id, data).row ?? ["id": .string(id)])
    }

    /// ``put(_:_:)``, returning once the room has acknowledged the write; throws
    /// the room's refusal when it hands the write back.
    @discardableResult
    public func put(_ model: String, _ data: [String: DocumentRecordValue], confirm: Bool) async throws -> PrimitiveRow {
        let id: String
        if case .string(let given)? = data["id"], !given.isEmpty { id = given } else { id = ULID.generate() }
        let written = try write(.put, model, id, data)
        if confirm { try await written.acknowledged() }
        return PrimitiveRow(raw: written.row ?? ["id": .string(id)])
    }

    /// Change the fields `data` names on record `id` of `model`: a value
    /// replaces the field's, a string set replaces the record's members (a
    /// member another writer adds concurrently is kept), `nil` clears a field
    /// (a string set, emptied), and a set change edits the members in place.
    /// The `id` key of `data` is ignored. Answers the record as the local copy
    /// shows it after the write, `nil` when the copy holds no such record (the
    /// patch is sent all the same).
    @discardableResult
    public func patch(_ model: String, id: String, _ data: [String: DocumentRecordValue]) throws -> PrimitiveRow? {
        try write(.patch, model, id, data).row.map(PrimitiveRow.init(raw:))
    }

    /// ``patch(_:id:_:)``, returning once the room has acknowledged the write;
    /// throws the room's refusal when it hands the write back.
    @discardableResult
    public func patch(
        _ model: String, id: String, _ data: [String: DocumentRecordValue], confirm: Bool
    ) async throws -> PrimitiveRow? {
        let written = try write(.patch, model, id, data)
        if confirm { try await written.acknowledged() }
        return written.row.map(PrimitiveRow.init(raw:))
    }

    /// Delete record `id` of `model`.
    public func delete(_ model: String, id: String) throws {
        _ = try write(.delete, model, id, [:])
    }

    /// ``delete(_:id:)``, returning once the room has acknowledged the write;
    /// throws the room's refusal when it hands the write back.
    public func delete(_ model: String, id: String, confirm: Bool) async throws {
        let written = try write(.delete, model, id, [:])
        if confirm { try await written.acknowledged() }
    }

    // MARK: - Reads

    /// Record `id` of `model` as the local copy holds it, or `nil`.
    public func get(_ model: String, id: String) throws -> PrimitiveRow? {
        let binding = try readable()
        return try binding.store.read(model: model, id: id).map { PrimitiveRow(raw: Self.decoded($0, model, binding)) }
    }

    /// `row` with each vector field this device knows read as its numbers (#5225).
    private static func decoded(_ row: RecordLogRow, _ model: String, _ binding: RecordLogDocumentBinding) -> RecordLogRow {
        binding.decodedVectors(row, model: model, encodings: binding.vectorEncodings(model: model))
    }

    /// The records of `model` matching `filter`, one page, answered from the
    /// local copy: the model API's filter grammar on any field, declared or
    /// not (`$contains`, `$all` and `$size` read a string set), the stored
    /// value's type deciding a comparison (`["n": 5]` does not match a stored
    /// `"5"`). `options` sorts (`sortOrder`, else `sort`; `id` breaks ties),
    /// pages (`limit`, `cursor`, `direction`; a backward page is answered in
    /// sort order), keeps or drops row keys (`projection`; `id` is always
    /// kept), and scopes (`documents`: `nil`, or a list naming this document).
    /// The page's `drift` says how far behind the server the local copy was;
    /// with `options.maxDrift`, a copy further behind is refused
    /// `DB3_DRIFT_EXCEEDED`.
    public func query(_ model: String, _ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws
        -> PagedQueryResult<PrimitiveRow>
    {
        let binding = try readable()
        let page = try binding.store.queryView(model, filter ?? [:], options: options)
        let encodings = binding.vectorEncodings(model: model)
        return PagedQueryResult(
            data: page.data.map { PrimitiveRow(raw: binding.decodedVectors($0, model: model, encodings: encodings)) },
            nextCursor: page.nextCursor, prevCursor: page.prevCursor, hasMore: page.hasMore, drift: page.drift
        )
    }

    /// How many records of `model` match `filter`, matched as ``query(_:_:options:)`` matches;
    /// with `maxDrift`, refused as a query is.
    public func count(_ model: String, _ filter: DocumentFilter? = nil, maxDrift: Db3MaxDrift? = nil) throws -> Int {
        try readable().store.countView(model, filter ?? [:], maxDrift: maxDrift)
    }

    /// Explain how this device answers a read of `model`: the read runs on the
    /// local copy as ``query(_:_:options:)``, ``count(_:_:maxDrift:)`` or an
    /// aggregate would run it, and the answer names, per statement, SQLite's
    /// plan, the indexes it used (by their names in the db3's index list) and
    /// whether it scanned, in the shape the server's explain answers.
    /// `request.index` forces the read through one field or member index, or
    /// through none (`"none"`), to compare. Nothing is written or sent. A
    /// facet tells set fields by the db3's type, or `request.setFields`, for
    /// the read's model only: the device never facets an include, so an
    /// include's model has no set fields and reads as the ordinary read's do.
    ///
    /// ```swift
    /// let records = client.db3.records(db3Id)
    /// let plain = try records.explain("Note", Db3ExplainRequest(op: .query, filter: ["year": 2024]))
    /// let none = try records.explain("Note", Db3ExplainRequest(op: .query, filter: ["year": 2024], index: "none"))
    /// print(plain.indexes, none.scanned) // ["idx_records_note_year"] ["Note"]
    /// ```
    ///
    /// - Throws: `JsBaoError` `.db3IndexNotFound` for an index the db3's list
    ///   does not have for `model`; `.db3IndexCannotServe` (with
    ///   `details["reason"]`) for one that cannot serve the read;
    ///   `.invalidArgument` for an empty index name. Refused as a query is on
    ///   a copy that is not here.
    public func explain(_ model: String, _ request: Db3ExplainRequest) throws -> Db3Explain {
        try readable().store.explainView(model, request)
    }

    /// Call `callback` after any change to `model`'s records in this document:
    /// a write here, a change the room sends (another client's write, a
    /// catch-up), or a generated model's save once the room's result arrives.
    /// Returns the unsubscribe; calling it twice is harmless. A listener never
    /// fires after the document closes.
    @discardableResult
    public func subscribe(_ model: String, _ callback: @escaping @Sendable () -> Void) throws -> @Sendable () -> Void {
        let binding = try resolve()
        let token = binding.onModelChanged(model, callback)
        return { [weak binding] in binding?.removeModelListener(model, token) }
    }

    // MARK: - The write

    private struct Written {
        let row: RecordLogRow?
        let seq: Int?
        let binding: RecordLogDocumentBinding

        func acknowledged() async throws {
            if let seq { try await binding.whenAcknowledged(seq) }
        }
    }

    /// Check, plan against the view and commit it as one entry (its mutations
    /// `m` then `also`, more than one when it names two spellings of a member),
    /// so the room accepts or refuses the write whole and `confirm` waits for
    /// that one outcome; tell the model's listeners. A model-free write
    /// commits on its own, never inside a `DynamicModel.transact` open on this
    /// thread.
    private func write(
        _ kind: RecordLogRecordWriteKind, _ model: String, _ id: String, _ data: [String: DocumentRecordValue]
    ) throws -> Written {
        let binding = try resolve()
        let documentId = binding.documentId
        let report: (DocumentWriteRefusedEvent) -> Void = { [logger] event in
            logger?.warn("[record-log] write refused locally —", documentId, model, id, event.error.code.rawValue)
            binding.reportRefused(event)
        }
        try assertRecordLogRecordInput(documentId: documentId, model: model, id: id, kind: kind, data: data, report: report)
        let data = try Self.encodedVectors(data, binding: binding, model: model, id: id, kind: kind)
        if binding.isReadOnly {
            throw JsBaoError(
                code: .accessDenied,
                message: "Cannot save \(model) \(id) to document `\(documentId)`: the room allows this client to read it only.",
                details: ["documentId": .string(documentId)]
            )
        }
        let (row, seq) = try binding.withOperation { () -> (RecordLogRow?, Int?) in
            let mutations: [RecordLogMutation]
            if kind == .delete {
                mutations = [planRecordLogDelete(model: model, recordId: id)]
            } else {
                mutations = planRecordLogRecordWrites(RecordLogRecordWriteInput(
                    model: model, id: id, kind: kind, existing: try binding.store.read(model: model, id: id), data: data
                ))
            }
            try assertRecordLogEntry(documentId: documentId, mutations: mutations, report: report)
            let seq = try binding.commit([RecordLogWrite(mutations: mutations)]).last?.seq
            return (kind == .delete ? nil : try binding.store.read(model: model, id: id).map { Self.decoded($0, model, binding) }, seq)
        }
        // The commit told the change listeners; the model's listeners hear it here.
        binding.notify([RecordLogRecordKey(model: model, id: id)], origin: nil)
        return Written(row: row, seq: seq, binding: binding)
    }

    /// `data` with each vector's numbers as the stored base64 of its field's
    /// encoding (#5225), refused as ``RecordLogDocumentBinding/encodedVectors(_:numbers:model:id:kind:)`` refuses.
    private static func encodedVectors(
        _ data: [String: DocumentRecordValue], binding: RecordLogDocumentBinding, model: String, id: String,
        kind: RecordLogRecordWriteKind
    ) throws -> [String: DocumentRecordValue] {
        var numbers: [String: [Float]] = [:]
        for (field, value) in data { if case .vector(let vector) = value { numbers[field] = vector } }
        guard !numbers.isEmpty else { return data }
        let encoded = try binding.encodedVectors([:], numbers: numbers, model: model, id: id, kind: kind.mutationKind)
        var out = data
        for (field, value) in encoded { if case .string(let text) = value { out[field] = .string(text) } }
        return out
    }
}
