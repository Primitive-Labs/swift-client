import Foundation
import YSwift

/// What a model's reads and writes go through when its document keeps its
/// records in a local store rather than in nested Y.Maps: a record-log
/// (format-3) document's view.
///
/// `DynamicModel` and `MultiDocModel` route every read and write of such a
/// member through this one surface, and every other member through the
/// Y.Map path.
protocol LocalRecordDelegate: AnyObject, Sendable {
    var modelName: String { get }

    // Reads
    func row(id: String) throws -> [String: JSONValue]?
    func query(filter: DocumentFilter?, options: QueryOptions?) throws -> [[String: JSONValue]]
    /// ``query(filter:options:)`` with `_related` attached, each leg read within this document.
    func query(filter: DocumentFilter?, options: QueryOptions?, include: [Include]?) throws -> [[String: JSONValue]]
    func queryPaged(filter: DocumentFilter?, options: QueryOptions?) throws -> PagedQueryResult<PrimitiveRow>
    func queryPaged(filter: DocumentFilter?, options: QueryOptions?, include: [Include]?) throws -> PagedQueryResult<PrimitiveRow>
    func count(filter: DocumentFilter?) throws -> Int
    func aggregate(_ options: AggregateOptions) throws -> [[String: JSONValue]]
    func exists(id: String) throws -> Bool
    func allIds() throws -> [String]
    func readRaw(id: String, field: String) throws -> String?
    func members(id: String, field: String) throws -> [String]
    func findId(fields: [String], values: [PrimitiveValue]) throws -> String?
    func fieldNames(id: String) throws -> Set<String>

    // Writes
    /// One local write. `upsertOn` names the field a create travels as an
    /// upsert on, for a store whose room resolves upserts; others ignore it.
    /// Answers the writer's sequence number of the entry it committed, for a
    /// store that numbers them; `nil` otherwise.
    @discardableResult
    func write(id: String, values: [String: PrimitiveValue], isUpdate: Bool, upsertOn: String?) throws -> Int?
    func clearField(id: String, field: String) throws
    func addMember(id: String, field: String, member: String, maxCount: Int?) throws
    @discardableResult
    func removeMember(id: String, field: String, member: String) throws -> Bool
    func delete(id: String) throws
    /// Run a mutation whose public entry point cannot throw.
    func quietly(recordId: String, _ body: () throws -> Void)

    /// Let whatever has arrived land before a read or a write decides.
    func settle()
    /// Publish the model's declaration the way this format declares it.
    func publishDeclaration(doc: YDocument, schema: PrimitiveSchema)
    /// Whether the local uniqueness pre-check holds saves to this constraint.
    func constraintInForce(_ name: String) -> Bool
    /// The store whose connection a filtered read over several documents runs on.
    var viewStore: RecordLogStore { get }
    /// Run `body` with the document's writes serialized: a save's read, its
    /// uniqueness check and its commit are one operation.
    func withOperation<T>(_ body: () throws -> T) throws -> T
}

// MARK: - Scoping a routed read

extension QueryOptions {
    /// The caller's options, scoped to `documents`.
    ///
    /// `QueryOptions.documents` is the engine's existing several-document
    /// scope (`WHERE _meta_doc_id IN (…)`), which is what the query tables
    /// need: they hold the rows of every document stored in them, including
    /// documents a read must not answer from because they are closed.
    static func scoped(_ options: QueryOptions?, to documents: [String]) -> QueryOptions {
        var scoped = options ?? QueryOptions()
        scoped.documents = documents
        return scoped
    }
}
