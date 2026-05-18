import Foundation

/// Return type of `DynamicModel.queryPaged`. Mirrors js-bao's
/// `PaginatedResult<T>` (the query-engine version).
///
/// Named `PagedQueryResult` to disambiguate from the unrelated
/// `PaginatedResult<T>` in `Types/Options.swift`, which predates this
/// work and ships API-style pagination (items + single cursor) for
/// the HTTP layer.
///
///  - `data`: the page's rows, in query order.
///  - `nextCursor`: opaque cursor to pass back to request the next
///    page. Nil on the last page.
///  - `prevCursor`: opaque cursor for the previous page. Nil on the
///    first page.
///  - `hasMore`: `true` iff more rows exist past `data`'s last row in
///    the current direction.
public struct PagedQueryResult<Row>: Sendable where Row: Sendable {
    public let data: [Row]
    public let nextCursor: String?
    public let prevCursor: String?
    public let hasMore: Bool

    public init(
        data: [Row],
        nextCursor: String? = nil,
        prevCursor: String? = nil,
        hasMore: Bool = false
    ) {
        self.data = data
        self.nextCursor = nextCursor
        self.prevCursor = prevCursor
        self.hasMore = hasMore
    }
}
