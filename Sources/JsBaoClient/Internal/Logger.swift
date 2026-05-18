import Foundation
#if canImport(OSLog)
import OSLog
#endif

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

public final class Logger: @unchecked Sendable {
    private var level: LogLevel
    private let scope: String
    private let lock = NSLock()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public init(level: LogLevel, scope: String = "") {
        self.level = level
        self.scope = scope
    }

    public func shouldLog(level: LogLevel) -> Bool {
        level >= self.level
    }

    public func verbose(_ args: Any...) {
        log(level: .verbose, args: args)
    }

    public func debug(_ args: Any...) {
        log(level: .debug, args: args)
    }

    public func log(_ args: Any...) {
        log(level: .info, args: args)
    }

    public func warn(_ args: Any...) {
        log(level: .warn, args: args)
    }

    public func error(_ args: Any...) {
        log(level: .error, args: args)
    }

    public func setLevel(_ level: LogLevel) {
        lock.lock()
        self.level = level
        lock.unlock()
    }

    public func forScope(scope childScope: String) -> Logger {
        let newScope: String
        if self.scope.isEmpty {
            newScope = childScope
        } else {
            newScope = "\(self.scope):\(childScope)"
        }
        return Logger(level: self.level, scope: newScope)
    }

    private func log(level: LogLevel, args: [Any]) {
        guard shouldLog(level: level) else { return }

        let timestamp = Logger.dateFormatter.string(from: Date())
        let scopeTag = scope.isEmpty ? "" : "[\(scope)]"
        let message = args.map { "\($0)" }.joined(separator: " ")

        let output = "[\(timestamp)]\(scopeTag) \(message)"

        lock.lock()
        print(output)
        lock.unlock()

        // Also emit via os_log on Apple platforms so iOS Simulator log
        // streams (which only see os_log, not stdout) can pick it up.
        #if canImport(OSLog)
        Logger.osLog(scope: scope, level: level, message: message)
        #endif
    }

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

public func createLogger(level: LogLevel, scope: String = "") -> Logger {
    Logger(level: level, scope: scope)
}
