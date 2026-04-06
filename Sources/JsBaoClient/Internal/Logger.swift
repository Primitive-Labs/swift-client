import Foundation

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
    }
}

public func createLogger(level: LogLevel, scope: String = "") -> Logger {
    Logger(level: level, scope: scope)
}
