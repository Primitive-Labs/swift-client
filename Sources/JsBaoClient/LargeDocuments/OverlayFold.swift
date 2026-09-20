import Foundation

/// Fold a format-2 epoch overlay into a `records` table (#3436).
///
/// A port of `packages/js-bao/src/utils/overlaySql.ts`, statement for
/// statement. That module is shared by BOTH ends of the JS implementation —
/// the Durable Object's authoritative table and the client's merged view — so
/// "what the server says the record is" and "what the client reads back"
/// cannot drift. Swift is the third implementation, and the only thing keeping
/// it from being a fourth dialect is the parity suite.
///
/// On a format-2 document the SQLite `records` table IS the document; the Y.Doc
/// holds only the current epoch's overlay. Every applied update therefore has
/// to reach `records` in one transaction boundary, for a document that may be
/// 2 GB. That rules out read-modify-write of the record: each overlay entry is
/// one merge-upsert whose RFC 7396 semantics SQLite's `json_patch` already
/// implements (an explicit `null` deletes the key), plus incremental
/// `stringset_index` maintenance for the member deltas.
enum OverlayFold {

    /// The statements for one table pair.
    ///
    /// The patch JSON is bound TWICE in the upserts, and the two branches use
    /// it differently:
    ///
    /// - INSERT: `json_patch('{}', ?)` strips the explicit nulls an unset
    ///   carries, so a brand-new row never persists a `null` placeholder;
    /// - UPDATE: the RAW patch is merged into the stored row, where those same
    ///   nulls do their RFC 7396 job of removing keys. (`excluded._data` is
    ///   the already-stripped insert value, so it cannot be used here.)
    ///
    /// `_replace` instead discards the stored row entirely: the create's
    /// fields ARE the record, so base fields the re-created record omitted
    /// must not survive.
    struct Statements {
        let deleteRecord: String
        let deleteAllMembers: String
        let deleteMember: String
        let insertMember: String
        let selectMembers: String
        let mergeUpsert: String
        let replaceUpsert: String

        init(tables: Format2TableNames) {
            let records = tables.records
            let members = tables.stringSetIndex
            deleteRecord = "DELETE FROM \(records) WHERE _type = ? AND _id = ?"
            deleteAllMembers = "DELETE FROM \(members) WHERE _type = ? AND _record_id = ?"
            deleteMember = """
                DELETE FROM \(members) \
                WHERE _type = ? AND _record_id = ? AND field = ? AND value = ?
                """
            insertMember = """
                INSERT OR IGNORE INTO \(members) (_record_id, _type, field, value) \
                VALUES (?, ?, ?, ?)
                """
            selectMembers = """
                SELECT value FROM \(members) \
                WHERE _type = ? AND _record_id = ? AND field = ? ORDER BY rowid
                """
            mergeUpsert = """
                INSERT INTO \(records) (_id, _type, _data)
                VALUES (?, ?, json_patch('{}', ?))
                ON CONFLICT(_type, _id) DO UPDATE SET
                  _data = json_patch(\(records)._data, ?)
                """
            replaceUpsert = """
                INSERT INTO \(records) (_id, _type, _data)
                VALUES (?, ?, json_patch('{}', ?))
                ON CONFLICT(_type, _id) DO UPDATE SET
                  _data = json_patch('{}', ?)
                """
        }
    }

    /// Project one record's overlay entry into `records` + `stringset_index`.
    ///
    /// Callers pass the entry for the keys the update TOUCHED, not the
    /// record's whole overlay: materialization is a fold, so `row ⊕ delta`
    /// over the stored row is the same record as replaying the epoch from its
    /// base. The one exception is `_replace`, which the CALLER completes from
    /// the whole overlay first (see ``OverlayDocument/complete(_:model:)``).
    static func project(
        _ connection: any Format2SqlConnection,
        model: String,
        entry: OverlayRecordEntry,
        statements: Statements
    ) throws {
        let id = entry.id

        if entry.deleted {
            try connection.execute(statements.deleteRecord, [.text(model), .text(id)])
            try connection.execute(statements.deleteAllMembers, [.text(model), .text(id)])
            return
        }

        if !entry.replace && entry.fields.isEmpty && entry.stringSets.isEmpty {
            // A bare `_deleted → false` (the marker a re-create clears)
            // carries no content of its own — writing it would mint an empty
            // row for a record that was never created here.
            return
        }

        if entry.replace {
            // The base row is gone, so its members are too — a `_replace` that
            // omits a stringset must not leave the old members behind.
            try connection.execute(statements.deleteAllMembers, [.text(model), .text(id)])
        }

        var patch = entry.fields
        patch["id"] = .string(id)

        for field in entry.stringSets.keys.sorted() {
            let members = entry.stringSets[field] ?? [:]
            for member in members.keys.sorted() {
                if members[member] == true {
                    try connection.execute(
                        statements.insertMember,
                        [.text(id), .text(model), .text(field), .text(member)]
                    )
                } else {
                    try connection.execute(
                        statements.deleteMember,
                        [.text(model), .text(id), .text(field), .text(member)]
                    )
                }
            }
            // `_data` carries stringsets as arrays as well — that is what
            // query results read — so re-read the field's members after the
            // deltas land rather than trying to express add/remove as a JSON
            // merge patch.
            let rows = try connection.query(
                statements.selectMembers, [.text(model), .text(id), .text(field)]
            )
            patch[field] = .array(rows.compactMap { $0["value"].stringValue }.map(JSONValue.string))
        }

        let patchJSON = try encodePatch(patch)
        try connection.execute(
            entry.replace ? statements.replaceUpsert : statements.mergeUpsert,
            [.text(id), .text(model), .text(patchJSON), .text(patchJSON)]
        )
    }

    /// The patch object as JSON text, with explicit nulls preserved — they are
    /// the unsets `json_patch` acts on.
    ///
    /// Keys are SORTED. `json_patch` emits the merged object in the patch's
    /// key order, and a Swift dictionary has no stable one — so without this,
    /// folding the same content twice rewrites `_data` with the keys shuffled.
    /// The record is identical either way, but a stored blob that changes on a
    /// re-fold is a difference anything comparing text would report, and the
    /// fold is deliberately idempotent.
    private static func encodePatch(_ patch: [String: JSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(patch)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Format2SqlError.executionFailed(
                sql: "<patch encoding>", message: "patch JSON is not UTF-8"
            )
        }
        return text
    }
}
