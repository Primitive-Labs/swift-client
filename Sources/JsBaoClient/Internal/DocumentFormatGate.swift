import Foundation

/// What the client decides about a document's format before anything about
/// it reaches the wire: the socket's receive limit, and the refusal of a large
/// document (`documentFormat: 2`), which the platform no longer serves.
extension JsBaoClient {

    /// Receive limit for a socket that may carry a record-log document's
    /// frames.
    ///
    /// Foundation's default is 1 MiB, and a record-log open's catch-up can
    /// exceed it. `URLSessionWebSocketTask` fails the RECEIVE, not the handler,
    /// on an oversized message, so the limit has to be raised before the frame
    /// can arrive rather than in response to it. A client whose documents are
    /// all locally known to be format 1 never raises it.
    static let raisedMaximumMessageSize = 16 * 1024 * 1024

    /// Settle the open's format questions that can be answered locally, at
    /// the top of `openDocument`.
    ///
    /// 1. **The refusal.** A local row naming format 2 is a large document a
    ///    pre-removal session opened. It is refused here, before anything is
    ///    opened or sent, and whatever that session stored for it is left
    ///    alone.
    /// 2. **The socket's receive limit.** Raised for any document NOT locally
    ///    known to be format 1, because the answer to "what is this document?"
    ///    may arrive in the very frame the limit protects.
    func prepareDocumentFormat(_ documentId: String) async throws {
        let stored = documentManager.documentFormat(documentId)
        if stored == largeDocumentFormat {
            logger.warn("[open] refused", documentId, "— a large document (format 2) is no longer served")
            throw documentFormatUnsupported(documentId: documentId)
        }
        if stored != 1 {
            await wsManager.setMaximumMessageSize(Self.raisedMaximumMessageSize)
        }
    }

    /// Settle this socket's receive limit BEFORE the socket exists.
    ///
    /// `URLSessionWebSocketTask` honours `maximumMessageSize` only on a task
    /// that has not been resumed, so a raise decided after the connect costs a
    /// rebuilt socket. Deciding it here — at every connect, and once storage
    /// has bound — means the ordinary client never pays that.
    ///
    /// Raise unless EVERY document this client knows of is locally known to
    /// be format 1. A client with no local documents at all is not such a
    /// client: its next open has no row to resolve.
    func ensureReceiveLimitForKnownDocuments() async {
        let known = documentManager.getMetadataIndex()
        let allOrdinary = !known.isEmpty && known.values.allSatisfy { $0.documentFormat == 1 }
        guard !allOrdinary else { return }
        await wsManager.setMaximumMessageSize(Self.raisedMaximumMessageSize)
    }

    /// The documents API's answer to "what format is `documentId`?": `nil`
    /// when the answer names none, which is an ordinary document.
    func lookUpDocumentFormat(_ documentId: String) async throws -> Int? {
        if let hook = documentFormatLookupForTest { return try await hook(documentId) }
        return try await documents.get(documentId: documentId).documentFormat
    }

    /// Drop what a pre-removal build kept for large documents on this device —
    /// the account wipe (`logout(wipeLocal: true)`).
    ///
    /// A large document is no longer served, so nothing reads these tables;
    /// an ordinary close, an eviction and a refused open all leave them where
    /// they are. The account wipe is the exception, because leaving a
    /// previous account's records on the device is what it exists to prevent.
    /// A no-op on a database that never held a large document.
    func purgeLegacyLargeDocumentTables() async {
        guard let provider = await offlineStore.getStorageProvider(),
              let host = provider as? any Format2SqlHost
        else { return }
        do {
            try LegacyLargeDocumentTables.dropAll(host: host)
        } catch {
            logger.warn("[wipe] the large-document tables an older build left could not be dropped:", error.localizedDescription)
        }
    }
}

/// The tables a pre-removal build kept for large documents, named by the
/// shapes it gave them: one records table and one member table per document,
/// and seven shared tables keyed by `doc_id`.
enum LegacyLargeDocumentTables {

    static let sharedTables = [
        "_epoch", "_pending_ops", "_client_acks", "_snapshot_load",
        "_snapshot_base", "_discontinuities", "_query_projection",
    ]

    /// Drop every per-document table, empty every shared one, and take every
    /// row from the derived query tables. Only on a database that holds the
    /// `_epoch` table, which every large document an older build opened wrote.
    static func dropAll(host: any Format2SqlHost) throws {
        try host.withConnection { connection in
            let present = Set(
                try connection.query("SELECT name FROM sqlite_master WHERE type = 'table'")
                    .compactMap { $0["name"].stringValue }
            )
            guard present.contains("_epoch") else { return }
            let perDocument = present.filter {
                $0.hasPrefix("records_f2_") || $0.hasPrefix("stringset_index_f2_")
            }
            // The derived query tables are found by the `_meta_doc_id` column
            // the projection gives each of them; the account wipe empties them
            // whatever document their rows came from.
            var derived: [String] = []
            for table in present.sorted() where !table.hasPrefix("sqlite_") {
                guard !sharedTables.contains(table), !perDocument.contains(table) else { continue }
                let columns = try connection.query("PRAGMA table_info(\"\(table)\")")
                    .compactMap { $0["name"].stringValue }
                if columns.contains("_meta_doc_id") { derived.append(table) }
            }
            try connection.transaction {
                for table in perDocument.sorted() {
                    try connection.executeScript("DROP TABLE IF EXISTS \"\(table)\"")
                }
                for table in derived {
                    try connection.executeScript("DELETE FROM \"\(table)\"")
                }
                for table in sharedTables where present.contains(table) {
                    try connection.executeScript("DELETE FROM \"\(table)\"")
                }
            }
        }
    }
}
