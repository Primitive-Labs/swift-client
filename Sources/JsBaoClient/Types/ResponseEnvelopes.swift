import Foundation

// MARK: - Shared response envelopes
//
// Several endpoints answer with either a single-key envelope or a bare array,
// and the typed API classes have to decode both. Written per call site that
// was the same `Decodable` repeated with a different key and element type —
// including two outright duplicates (`{ fields }`, served by both
// `databases.describeModel` and the DO engine's `/describe`; and the document
// list, served by both `documents.list` and `me.ownedDocuments`). They live
// here once, so the probe order is the same everywhere too.

/// `{ items: [...] }`, with a bare `[Element]` accepted defensively.
///
/// The envelope is tried first and decoded **strictly** when its key is
/// present, so a malformed `items` value is an error rather than a silent
/// empty list; a body with no `items` key is decoded as a bare array.
struct ItemsEnvelope<Element: Decodable & Sendable>: Decodable, Sendable {
    let items: [Element]

    private enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.items) {
            items = try container.decode([Element].self, forKey: .items)
            return
        }
        let container = try decoder.singleValueContainer()
        items = try container.decode([Element].self)
    }
}

/// `{ fields: [...] }` or a bare `[ModelFieldInfo]` — the model-describe
/// shape.
struct ModelFieldsEnvelope: Decodable, Sendable {
    let fields: [ModelFieldInfo]

    private enum CodingKeys: String, CodingKey { case fields }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.fields) {
            fields = try container.decode([ModelFieldInfo].self, forKey: .fields)
            return
        }
        let container = try decoder.singleValueContainer()
        fields = try container.decode([ModelFieldInfo].self)
    }
}

/// A document list: the `{ items, cursor }` (legacy `{ documents }`) page, or
/// a bare `[DocumentInfo]` array, which carries no cursor.
///
/// The probe between the two shapes is shape tolerance, not malformed-body
/// tolerance: bytes that are neither still throw out of the outer decode.
struct DocumentListEnvelope: Decodable, Sendable {
    let items: [DocumentInfo]
    let cursor: String?

    init(from decoder: Decoder) throws {
        if let array = try? [DocumentInfo](from: decoder) {
            items = array
            cursor = nil
            return
        }
        let page = try DocumentListPage(from: decoder)
        items = page.items
        cursor = page.cursor
    }
}

/// The `{ items, hasMore, nextCursor?, cursor? }` pagination envelope, with a
/// bare `[Element]` accepted as the pre-pagination response an older server
/// still sends (`GET /databases` before #1958).
///
/// A bare array carries no continuation token, so it normalizes to a single
/// page — `hasMore: false`, no cursor — which is what the JS client, the CLI,
/// and web-admin all do with the same body. Without this the published client
/// throws while a rolling upgrade is in flight (#2245).
///
/// As with `DocumentListEnvelope`, the probe is shape tolerance, not
/// malformed-body tolerance: the array is tried first because the keyed
/// `PaginatedResult` decoder cannot read one, and bytes that are neither shape
/// still throw out of the outer decode.
struct PaginatedPageEnvelope<Element: Decodable & Sendable>: Decodable, Sendable {
    let page: PaginatedResult<Element>
    /// True when the body was the legacy bare array rather than the keyed
    /// envelope.
    ///
    /// A server old enough to send the bare array also predates the query
    /// filters added alongside pagination, and it ignores query parameters it
    /// does not know — so it answers a filtered request with its complete
    /// list. Callers that sent such a filter must apply it themselves on this
    /// path; see `DatabasesAPI.listPage`'s `owner` handling.
    let isLegacyArray: Bool

    init(from decoder: Decoder) throws {
        if let array = try? [Element](from: decoder) {
            page = PaginatedResult(items: array, hasMore: false)
            isLegacyArray = true
            return
        }
        page = try PaginatedResult<Element>(from: decoder)
        isLegacyArray = false
    }
}
