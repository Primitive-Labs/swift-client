import Foundation

/// The one place a query row becomes a typed model — and the one place a row
/// that fails to decode is accounted for (#2825).
///
/// The generated read facade (`Model.query` / `queryPaged` / `queryOne` /
/// `findByUnique`) keeps the rows that decode, because JS has no decode step
/// and a single drifted row must not fail the whole read. What it may not do
/// is drop one *quietly*: a mistyped field once made ~1,000 rows disappear
/// from an app with no error and no log while the engine still held them.
///
/// Every drop here is logged at `.warn` with the model, the row id and the
/// unreadable field(s), and handed to ``onDecodeFailure`` for apps that want
/// to route it somewhere (a breadcrumb, a crash reporter, a test).
/// `Model.find` / `Model.findAll` stay louder still — they throw
/// ``PrimitiveDecodeError`` rather than returning a short result.
public enum PrimitiveRowDecoder {

    // MARK: - Failure reporting

    private static let hookLock = NSLock()
    // Every access goes through `hookLock` (see the accessor below), so the
    // mutable static is safe despite not being concurrency-checked.
    nonisolated(unsafe) private static var _onDecodeFailure: (@Sendable (PrimitiveDecodeError) -> Void)?

    /// Called for every query row that fails typed decode, in addition to the
    /// `.warn` log. Set it once at startup; set `nil` to remove it.
    ///
    /// The callback runs on whichever thread ran the query, so anything it
    /// touches must be safe from there — hence `@Sendable`.
    public static var onDecodeFailure: (@Sendable (PrimitiveDecodeError) -> Void)? {
        get { hookLock.withLock { _onDecodeFailure } }
        set { hookLock.withLock { _onDecodeFailure = newValue } }
    }

    /// Fixed at `.warn` for the same reason as the relationship-pagination
    /// advisory: a silently shrinking result set is correctness-relevant and
    /// should surface regardless of the client's configured log level.
    private static let logger = createLogger(level: .warn, scope: "TypedDecode")

    private static func report(_ error: PrimitiveDecodeError) {
        logger.warn(error.errorDescription ?? "\(error)")
        onDecodeFailure?(error)
    }

    // MARK: - Decoding

    /// Decode query rows into `T`, reporting every row that fails.
    public static func decodeAll<T: PrimitiveModel & PrimitiveRowDecodable>(
        _ rows: [[String: JSONValue]],
        as type: T.Type = T.self
    ) -> [T] {
        rows.compactMap { decodeOne($0, as: type) }
    }

    /// Paginated reads hand rows in as `PrimitiveRow`; same decode, same
    /// reporting.
    public static func decodeAll<T: PrimitiveModel & PrimitiveRowDecodable>(
        _ rows: [PrimitiveRow],
        as type: T.Type = T.self
    ) -> [T] {
        rows.compactMap { decodeOne($0.raw, as: type) }
    }

    /// Decode a single row (the `queryOne` / `findByUnique` shape). `nil` in
    /// stays `nil` out and reports nothing — that's "no match", not drift.
    public static func decodeOne<T: PrimitiveModel & PrimitiveRowDecodable>(
        _ row: [String: JSONValue]?,
        as type: T.Type = T.self
    ) -> T? {
        guard let row else { return nil }
        if let decoded = T(row: row) { return decoded }
        report(PrimitiveDecodeError(
            modelName: T.modelName, row: row, schema: T.primitiveSchema
        ))
        return nil
    }
}
