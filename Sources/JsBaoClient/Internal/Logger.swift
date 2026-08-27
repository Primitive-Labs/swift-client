import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// The client's internal logger. Module-internal on purpose (#2363): apps
/// configure logging through the public `LogLevel` (`Types/LogLevel.swift`)
/// and never construct or call a `Logger` themselves.
final class Logger: @unchecked Sendable {
    private var level: LogLevel
    private let scope: String
    private let lock = NSLock()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init(level: LogLevel, scope: String = "") {
        self.level = level
        self.scope = scope
    }

    func shouldLog(level: LogLevel) -> Bool {
        level >= self.level
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

    func forScope(scope childScope: String) -> Logger {
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

func createLogger(level: LogLevel, scope: String = "") -> Logger {
    Logger(level: level, scope: scope)
}
