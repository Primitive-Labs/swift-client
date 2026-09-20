import Foundation

/// Whether this client's storage can host a large document, and the refusal
/// when it cannot (#3436, behavior 14).
public enum Format2Storage {

    /// Why a large document cannot be stored here. The JS client's
    /// `Format2StorageUnavailableError` reasons, verbatim.
    public enum Reason: String, Sendable {
        /// The provider keeps nothing on disk, so the document could not
        /// outlive the session — and a large document IS its local store.
        case notPersistent = "not-persistent"
        /// The device has no room for it.
        case overQuota = "over-quota"
    }

    /// The typed refusal.
    public static func unavailable(reason: Reason, documentId: String? = nil) -> JsBaoError {
        var details: [String: JSONValue] = ["reason": .string(reason.rawValue)]
        if let documentId { details["documentId"] = .string(documentId) }
        return JsBaoError(
            code: .format2StorageUnavailable,
            message: message(for: reason),
            details: details
        )
    }

    /// The record-store host for a provider, or the typed refusal.
    ///
    /// The capability is a CONFORMANCE, not a probe: a provider that cannot
    /// host a large document does not implement ``Format2SqlHost``, so the
    /// question is answered by the type system and there is no runtime state
    /// that could answer it differently on the second call.
    ///
    /// Called from `openDocument` BEFORE any frame goes out, so an app that
    /// configured `.memory` storage and opened a large document is told what
    /// is wrong instead of being connected to a document it cannot store.
    public static func host(
        for provider: any StorageProvider,
        documentId: String? = nil
    ) throws -> any Format2SqlHost {
        guard let host = provider as? any Format2SqlHost else {
            throw unavailable(reason: .notPersistent, documentId: documentId)
        }
        return host
    }

    private static func message(for reason: Reason) -> String {
        switch reason {
        case .notPersistent:
            return "A large document needs persistent on-device storage. "
                + "Configure the client with `.sqlite` storage — an in-memory "
                + "provider cannot hold one, because a large document IS its local store."
        case .overQuota:
            return "There is not enough room on this device for this large document."
        }
    }
}
