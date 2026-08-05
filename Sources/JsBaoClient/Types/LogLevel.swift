import Foundation

/// How much the client logs. Set it with `JsBaoClientOptions.logLevel` at
/// construction, or change it at runtime with `JsBaoClient.setLogLevel(_:)`.
///
/// Levels are ordered: a message is emitted when its level is at or above the
/// configured one, so `.warn` (the default) shows warnings and errors, and
/// `.none` silences the client entirely.
///
/// Lives here rather than next to the internal `Logger` it configures: the
/// logger is module-internal plumbing, this enum is public API (#2363).
public enum LogLevel: Int, Sendable, Comparable {
    case verbose = 0
    case debug = 1
    case info = 2
    case warn = 3
    case error = 4
    case none = 5

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
