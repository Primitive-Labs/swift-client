import Foundation

/// What a caller may ask for when creating a document, and the refusal of a
/// large document (`documentFormat: 2`), which the platform no longer serves.
///
/// The Swift half of `src/client/internal/document-format.ts`: the same
/// conditions, the same codes, the same messages.

/// The sentence a refused large document is named with — the server's own.
let documentFormatUnsupportedMessage =
    "documentFormat 2 (large document) is no longer served; create a record-log document with documentFormat 3"

/// `documentFormat` of a large document: recognised only so it can be refused.
let largeDocumentFormat = 2

/// The refusal of a large document, naming it when there is one.
func documentFormatUnsupported(documentId: String? = nil, message: String? = nil) -> JsBaoError {
    var details: [String: JSONValue] = ["documentFormat": .number(Double(largeDocumentFormat))]
    if let documentId { details["documentId"] = .string(documentId) }
    let text = message ?? documentId.map {
        "Document \($0) is a large document (format 2): \(documentFormatUnsupportedMessage)"
    } ?? documentFormatUnsupportedMessage
    return JsBaoError(code: .documentFormatUnsupported, message: text, details: details)
}

/// Refuse a create that asks for a large document, before anything is
/// created or sent. Called from every create door: `documents.create` and
/// `createDocument` (through the manager's `createLocalDocument`),
/// `createWithAlias` and `getOrCreateWithAlias`.
func assertRequestedDocumentFormat(_ documentFormat: Int?) throws {
    guard documentFormat == largeDocumentFormat else { return }
    throw documentFormatUnsupported()
}

/// Refuse a record-log document that is also local-only.
///
/// A record-log document's writes are sequenced by the server's room; a
/// local-only document is never sent to the server, in this session or any
/// later one, so it can never reach it. The combination is not a document
/// that syncs late — it is a document that can never work, so it is refused
/// where every other impossible `localOnly` combination is, with the same code.
///
/// One function, called from every door a create reaches: the top of
/// `DocumentManager.createLocalDocument`, which is the only writer of a
/// create's local state, and the isolated fallback in `DocumentsAPI.create`,
/// which writes no local state but must not silently ignore the option either.
/// A check one level up, in `JsBaoClient.createDocument`, would leave the
/// manager's direct callers unguarded.
func assertDocumentFormatAllowsLocalOnly(
    documentFormat: Int?,
    localOnly: Bool
) throws {
    try assertRequestedDocumentFormat(documentFormat)
    guard documentFormat == 3, localOnly else { return }
    throw JsBaoError(
        code: .localOnlyUnsupportedOption,
        message: "documentFormat: 3 (a record-log document) cannot be combined with "
            + "localOnly: true — its writes are sequenced by the server's room, "
            + "which a local-only document never reaches"
    )
}
