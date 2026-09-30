import Foundation

/// Refuse a large document that is also local-only.
///
/// A large document's records live in an epoch store the server's room opens
/// and in a `records` table the room maintains; a local-only document is never
/// sent to the server, in this session or any later one, so it can never reach
/// either. The combination is not a document that syncs late — it is a document
/// that can never work, so it is refused where every other impossible
/// `localOnly` combination is, with the same code.
///
/// This is the Swift half of `assertDocumentFormatAllowsLocalOnly` in
/// `src/client/internal/large-documents/document-format.ts`: the same
/// condition, the same code, the same message, and no `details` — the JS
/// client passes none.
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
    guard documentFormat == 2, localOnly else { return }
    throw JsBaoError(
        code: .localOnlyUnsupportedOption,
        message: "documentFormat: 2 (a large document) cannot be combined with "
            + "localOnly: true — a large document's records live in a store the "
            + "server's room opens, which a local-only document never reaches"
    )
}
