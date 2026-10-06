import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// The client's internal logger. Module-internal on purpose (#2363): apps
/// configure logging through the public `LogLevel` (`Types/LogLevel.swift`)
/// and never construct or call a `Logger` themselves.
final class Logger: @unchecked Sendable {
    /// This logger's own level, or `nil` for a scoped logger that follows the
    /// logger it was scoped from. Guarded by `lock`.
    private var level: LogLevel?
    private let parent: Logger?
    private let scope: String
    private let lock = NSLock()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init(level: LogLevel, scope: String = "") {
        self.level = level
        self.parent = nil
        self.scope = scope
    }

    private init(parent: Logger, scope: String) {
        self.level = nil
        self.parent = parent
        self.scope = scope
    }

    /// The level in force: this logger's own, or the one it follows.
    var effectiveLevel: LogLevel {
        if let own = lock.withLock({ level }) { return own }
        return parent?.effectiveLevel ?? .none
    }

    func shouldLog(level: LogLevel) -> Bool {
        level >= effectiveLevel
    }

    func verbose(_ args: Any...) {
        log(level: .verbose, args: args)
    }

    func debug(_ args: Any...) {
        log(level: .debug, args: args)
    }

    func log(_ args: Any...) {
        log(level: .info, args: args)
    }

    func warn(_ args: Any...) {
        log(level: .warn, args: args)
    }

    func error(_ args: Any...) {
        log(level: .error, args: args)
    }

    func setLevel(_ level: LogLevel) {
        lock.lock()
        self.level = level
        lock.unlock()
    }

    /// A logger for one component, tagged with `childScope`.
    ///
    /// It follows this logger's level rather than copying it, so a runtime
    /// `JsBaoClient.setLogLevel(_:)` reaches every component — `docMgr`,
    /// `http`, `documents` and the rest — and not only the root.
    func forScope(scope childScope: String) -> Logger {
        let newScope: String
        if self.scope.isEmpty {
            newScope = childScope
        } else {
            newScope = "\(self.scope):\(childScope)"
        }
        return Logger(parent: self, scope: newScope)
    }

    private func log(level: LogLevel, args: [Any]) {
        guard shouldLog(level: level) else { return }

        let timestamp = Logger.dateFormatter.string(from: Date())
        let scopeTag = scope.isEmpty ? "" : "[\(scope)]"
        let message = args.map { "\($0)" }.joined(separator: " ")

        let output = "[\(timestamp)]\(scopeTag) \(message)"

        Logger.lineForTest?(level, scope, message)

        lock.lock()
        print(output)
        lock.unlock()

        // Also emit via os_log on Apple platforms so iOS Simulator log
        // streams (which only see os_log, not stdout) can pick it up.
        #if canImport(OSLog)
        Logger.osLog(scope: scope, level: level, message: message)
        #endif
    }

    /// Test seam: every line that passed its logger's level check, with the
    /// level, the scope and the message. Never set in production code.
    static var lineForTest: (@Sendable (LogLevel, String, String) -> Void)? {
        get { testSinkLock.withLock { _lineForTest } }
        set { testSinkLock.withLock { _lineForTest = newValue } }
    }
    private static let testSinkLock = NSLock()
    nonisolated(unsafe) private static var _lineForTest: (@Sendable (LogLevel, String, String) -> Void)?

    #if canImport(OSLog)
    private static let osLoggerLock = NSLock()
    nonisolated(unsafe) private static var osLoggers: [String: os.Logger] = [:]

    private static func osLog(scope: String, level: LogLevel, message: String) {
        let category = scope.isEmpty ? "JsBaoClient" : scope
        osLoggerLock.lock()
        let logger: os.Logger
        if let existing = osLoggers[category] {
            logger = existing
        } else {
            logger = os.Logger(subsystem: "com.primitivelabs.JsBaoClient", category: category)
            osLoggers[category] = logger
        }
        osLoggerLock.unlock()

        // Privacy: in DEBUG we want full message visibility so devs
        // running `Console.app` / `simctl spawn log stream` can read
        // the output. In release builds, default to `.private` so the
        // SDK doesn't leak document IDs, user IDs, file paths, etc. to
        // anyone with Console access on a non-developer-mode device.
        #if DEBUG
        switch level {
        case .verbose, .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .warn:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        case .none:
            break
        }
        #else
        switch level {
        case .verbose, .debug:
            logger.debug("\(message, privacy: .private)")
        case .info:
            logger.info("\(message, privacy: .private)")
        case .warn:
            logger.warning("\(message, privacy: .private)")
        case .error:
            logger.error("\(message, privacy: .private)")
        case .none:
            break
        }
        #endif
    }
    #endif
}

func createLogger(level: LogLevel, scope: String = "") -> Logger {
    Logger(level: level, scope: scope)
}
