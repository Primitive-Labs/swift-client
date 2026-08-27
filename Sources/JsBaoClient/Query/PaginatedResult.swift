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
///  - `nextCursor`: opaque cursor that continues paging in the CURRENT
///    direction. Nil when `hasMore` is false (no further rows that way).
///  - `prevCursor`: opaque cursor that reverses the paging direction.
///    Nil on the first page.
///  - `hasMore`: `true` iff more rows exist past `data`'s last row in
///    the current paging direction (the over-fetch signal — one extra
///    row was seen and dropped). It is NOT "a prevCursor is present":
///    backward pages report `hasMore` for earlier rows the same way
///    forward pages report it for later rows.
public struct PagedQueryResult<Row> {
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

/// `Sendable` **conditionally**, not as a declaration requirement.
///
/// The requirement used to sit on the type declaration
/// (`struct PagedQueryResult<Row>: Sendable where Row: Sendable`), which made
/// every `PagedQueryResult<Row>` a hard error for any non-`Sendable` `Row`
/// even when the page never crossed an isolation boundary. As a conditional
/// conformance the container tracks the row instead of constraining it: a page
/// of `Sendable` rows (`PrimitiveRow`, `PrimitiveRecord`, a generated model
/// struct) is `Sendable`; a page of some non-`Sendable` row type still
/// compiles and simply can't be sent — which is the honest answer rather than
/// a compile error at the declaration. (#1992, Phase C.)
extension PagedQueryResult: Sendable where Row: Sendable {}
