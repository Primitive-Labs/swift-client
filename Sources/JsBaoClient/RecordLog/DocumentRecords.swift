import Foundation

/// The records of one open format-3 document by model name, with no model
/// class: from `client.documents.records(documentId)`.
///
/// Any model of the document can be written and read, declared or not. A
/// field holds a ``DocumentRecordValue``: a string, a number, a boolean,
/// `null` or a string set, and a set can be edited in place with
/// `.setChange(add:remove:clear:)`. Reads answer from the document's local
/// copy at once, offline too; writes show there at once and reach the room
/// when the client is connected.
///
/// ```swift
/// let records = client.documents.records(documentId)
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
        try readable().store.read(model: model, id: id).map(PrimitiveRow.init(raw:))
    }

    /// The records of `model` matching `filter`, one page, answered from the
    /// local copy: the model API's filter grammar on any field, declared or
    /// not (`$contains`, `$all` and `$size` read a string set), the stored
    /// value's type deciding a comparison (`["n": 5]` does not match a stored
    /// `"5"`). `options` sorts (`sortOrder`, else `sort`; `id` breaks ties),
    /// pages (`limit`, `cursor`, `direction`; a backward page is answered in
    /// sort order), keeps or drops row keys (`projection`; `id` is always
    /// kept), and scopes (`documents`: `nil`, or a list naming this document).
    public func query(_ model: String, _ filter: DocumentFilter? = nil, options: QueryOptions? = nil) throws
        -> PagedQueryResult<PrimitiveRow>
    {
        let page = try readable().store.queryView(model, filter ?? [:], options: options)
        return PagedQueryResult(
            data: page.data.map(PrimitiveRow.init(raw:)), nextCursor: page.nextCursor, prevCursor: page.prevCursor,
            hasMore: page.hasMore
        )
    }

    /// How many records of `model` match `filter`, matched as ``query(_:_:options:)`` matches.
    public func count(_ model: String, _ filter: DocumentFilter? = nil) throws -> Int {
        try readable().store.countView(model, filter ?? [:])
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
            return (kind == .delete ? nil : try binding.store.read(model: model, id: id), seq)
        }
        // The commit told the change listeners; the model's listeners hear it here.
        binding.notify([RecordLogRecordKey(model: model, id: id)], origin: nil)
        return Written(row: row, seq: seq, binding: binding)
    }
}
