import Foundation

/// The backend resolver behind `JsBaoClient.resolveBackend(options:timeout:)`:
/// reads the home app's policy with one unauthenticated request and decides
/// from it, or from the policy an earlier call stored, which app id and URLs
/// the copy constructs its client with.
///
/// Its record lives in a file of its own beside the client's database file
/// (`<database file>.backend-resolver.json`), one record per home app id and
/// auth namespace: the raw `clients` map as served, `storedAt`, and one
/// `sent:` field per target the copy was sent to. The resolver never opens the
/// client's database, and a client never reads this file. Every write replaces
/// the whole file atomically under one process-wide lock and merges only the
/// fields it names, so no call removes a target another call recorded.
enum BackendResolver {
    static let defaultTimeout: TimeInterval = 10
    /// The longest bound used (about 31 years), so nanosecond arithmetic never overflows.
    static let maxTimeout: TimeInterval = 1_000_000_000
    static let maxSentTargets = 16
    static let recordSuffix = ".backend-resolver.json"
    /// Guards every read and write of a record file (internal for tests).
    static let fileLock = NSLock()

    private struct Outcome {
        let answer: ResolvedBackend
        var note: String?
    }

    private enum PolicyRead {
        case ok(JSONValue)
        case failed(String)
    }

    static func resolve(
        options: JsBaoClientOptions,
        timeout: TimeInterval,
        bundleVersion: @escaping @Sendable () -> Any? = { Bundle.main.infoDictionary?["CFBundleShortVersionString"] }
    ) async -> ResolvedBackend {
        let bound = timeout.isFinite && timeout > 0 ? min(timeout, maxTimeout) : defaultTimeout
        let deadline = Date().addingTimeInterval(bound)
        let logger = Logger(level: options.logLevel, scope: "resolveBackend")
        let resolution = ClientVersionRules.resolveClientIdentity(
            optionVersion: options.appVersion,
            optionPlatform: options.platform,
            bundleVersion: bundleVersion(),
            osPlatform: ClientVersionRules.osPlatform
        )
        let version = resolution.identity.version.flatMap { ClientVersionRules.parseClientVersion($0) == nil ? nil : $0 }
        let platform = resolution.identity.platform.flatMap { ClientVersionRules.isLegalPlatformName($0) ? $0 : nil }
        let outcome: Outcome
        if resolution.refusal == nil, let version, let platform {
            let build = BackendBuild(
                appId: options.appId, apiUrl: options.apiUrl, wsUrl: options.wsUrl, version: version, platform: platform
            )
            outcome = await decide(options: options, build: build, bound: bound, deadline: deadline, logger: logger)
        } else {
            outcome = answerBuild(options, "no usable version or platform")
        }
        // The one line says where this copy was sent, so it prints at every
        // level but `.none`, the default `.warn` included.
        let lineLevel: LogLevel = options.logLevel == .none ? .none : min(options.logLevel, .info)
        let answer = outcome.answer
        Logger(level: lineLevel, scope: "resolveBackend").log(
            "home=\(options.appId) version=\(version ?? "(none)") platform=\(platform ?? "(none)") "
                + "appId=\(answer.appId) apiUrl=\(answer.apiUrl) overridden=\(answer.overridden) source=\(answer.source.rawValue)"
                + (outcome.note.map { " (\($0))" } ?? "")
        )
        return answer
    }

    private static func answerBuild(_ options: JsBaoClientOptions, _ note: String) -> Outcome {
        Outcome(
            answer: ResolvedBackend(appId: options.appId, apiUrl: options.apiUrl, wsUrl: options.wsUrl, overridden: false, source: .build),
            note: note
        )
    }

    private static func decide(
        options: JsBaoClientOptions,
        build: BackendBuild,
        bound: TimeInterval,
        deadline: Date,
        logger: Logger
    ) async -> Outcome {
        let path = recordPath(options)
        let key = recordKey(options.appId, options.auth.storageKeyPrefix ?? "default")
        guard let loaded = await beforeDeadline(deadline, {
            path.flatMap { file in fileLock.withLock { readRecords(file)[key]?.objectValue } }
        }) else { return answerBuild(options, "the store did not answer in time") }
        let record = loaded
        let stored = record?["clients"].flatMap { $0.objectValue == nil ? nil : $0 }
        let write: @Sendable ([String: JSONValue]) -> Void = { patch in
            guard let path else { return }
            merge(patch, into: key, at: path, logger: logger)
        }

        func decideFresh(_ clients: JSONValue) async -> Outcome {
            let chosen = BackendOverrideRules.selectOverride(clients: clients, build: build) { position, reason in
                logger.debug("skipped backendOverrides entry \(position) on \(build.platform): \(reason)")
            }
            let choice = BackendOverrideRules.backendFor(chosen, build: build)
            var patch: [String: JSONValue] = ["clients": clients, "storedAt": .number(nowMs())]
            if choice.overridden {
                let target = BackendOverrideRules.normalizeApiUrl(choice.apiUrl)
                patch[sentField(choice.appId, target)] = .object([
                    "appId": .string(choice.appId), "apiUrl": .string(target), "at": .number(nowMs()),
                ])
            }
            // The write keeps going past the deadline; the answer does not wait.
            let written = await beforeDeadline(deadline) { [patch] in write(patch); return true } ?? false
            return Outcome(
                answer: ResolvedBackend(choice, source: .fresh),
                note: written ? nil : "the store write was still pending at the deadline"
            )
        }

        guard let stored else {
            switch await readPolicy(options: options, build: build, until: deadline) {
            case .ok(let clients): return await decideFresh(clients)
            case .failed(let reason): return answerBuild(options, reason)
            }
        }
        guard let storedOverride = BackendOverrideRules.selectOverride(clients: stored, build: build) else {
            let refreshUntil = Date().addingTimeInterval(bound)
            Task {
                switch await readPolicy(options: options, build: build, until: refreshUntil) {
                case .ok(let clients): write(["clients": clients, "storedAt": .number(nowMs())])
                case .failed(let reason): logger.debug("background refresh: \(reason)")
                }
            }
            return Outcome(answer: ResolvedBackend(BackendOverrideRules.backendFor(nil, build: build), source: .stored))
        }
        switch await readPolicy(options: options, build: build, until: deadline) {
        case .ok(let clients):
            return await decideFresh(clients)
        case .failed(let reason):
            let choice = BackendOverrideRules.backendFor(storedOverride, build: build)
            let target = BackendOverrideRules.normalizeApiUrl(choice.apiUrl)
            if sentTargets(record).contains(where: { $0.appId == choice.appId && $0.apiUrl == target }) {
                return Outcome(answer: ResolvedBackend(choice, source: .stored), note: reason)
            }
            return answerBuild(options, "\(reason); this copy was never sent to \(choice.appId) at \(target)")
        }
    }

    /// One read of the home app's policy, cancelled at `until`. Never throws.
    private static func readPolicy(options: JsBaoClientOptions, build: BackendBuild, until: Date) async -> PolicyRead {
        let remaining = until.timeIntervalSinceNow
        guard remaining > 0 else { return .failed("read timed out") }
        let base = BackendOverrideRules.normalizeApiUrl(build.apiUrl)
        guard let url = URL(string: "\(base)/app/\(build.appId)/api/settings/client-versions") else {
            return .failed("read failed (the build's apiUrl is not a URL)")
        }
        var headers = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: remaining)
        let versionHeaders = ClientVersionHeaders(version: build.version, platform: build.platform)
        headers.setValue(options.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        versionHeaders.apply(to: &headers)
        let request = headers
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let first: PolicyRead? = await withTaskGroup(of: PolicyRead?.self) { group in
            group.addTask {
                do {
                    let (data, response) = try await NetworkSession.data(for: request, using: session)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else { return .failed("read failed (HTTP \(status))") }
                    guard let body = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue else {
                        return .failed("read failed (the body is not a JSON object)")
                    }
                    return .ok(.object(body["clients"]?.objectValue ?? [:]))
                } catch {
                    return .failed("read failed (\(error.localizedDescription))")
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let first, Date() < until else { return .failed("read timed out") }
        return first
    }

    /// Answers a redirect with the 3xx response itself, so a redirected read
    /// is a failed read and its destination is never requested.
    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// `work` run off the caller's thread, or `nil` when `deadline` passes
    /// first (a value arriving after it is `nil` too). A late `work` still runs
    /// to the end: the file lock and the file system cannot be cut short.
    private static func beforeDeadline<T: Sendable>(_ deadline: Date, _ work: @escaping @Sendable () -> T) async -> T? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global().async { let value = work(); once.resume(Date() < deadline ? value : nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + remaining) { once.resume(nil) }
        }
    }

    private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
        func resume(_ value: T?) {
            let taken: CheckedContinuation<T?, Never>? = lock.withLock { defer { continuation = nil }; return continuation }
            taken?.resume(returning: value)
        }
    }

    // MARK: - The record file

    static func recordPath(_ options: JsBaoClientOptions) -> String? {
        guard case .sqlite(let path) = options.storageConfig else { return nil }
        return (path ?? SQLiteStorageProvider.defaultDatabasePath(appId: options.appId)) + recordSuffix
    }

    private static func recordKey(_ appId: String, _ namespace: String) -> String {
        json(.array([.string(appId), .string(namespace)]))
    }

    private static func sentField(_ appId: String, _ apiUrl: String) -> String {
        "sent:" + json(.array([.string(appId), .string(apiUrl)]))
    }

    private static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    private static func nowMs() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    /// The file's records by key; empty when it is missing or unreadable.
    private static func readRecords(_ path: String) -> [String: JSONValue] {
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        return file.objectValue?["records"]?.objectValue ?? [:]
    }

    /// The targets `record` says this copy was sent to that count: the 16 most recent.
    private static func sentTargets(_ record: [String: JSONValue]?) -> [(field: String, appId: String, apiUrl: String, at: Double)] {
        let all = (record ?? [:]).compactMap { field, value -> (field: String, appId: String, apiUrl: String, at: Double)? in
            guard field.hasPrefix("sent:"), let target = value.objectValue,
                  let appId = target["appId"]?.stringValue, let apiUrl = target["apiUrl"]?.stringValue,
                  let at = target["at"]?.numberValue, field == sentField(appId, apiUrl) else { return nil }
            return (field, appId, apiUrl, at)
        }
        return Array(all.sorted { $0.at > $1.at }.prefix(maxSentTargets))
    }

    /// Merge `patch` into the record under `key`, keeping its 16 most recent
    /// targets, and replace the file. A failure is logged at debug and changes
    /// no answer.
    private static func merge(_ patch: [String: JSONValue], into key: String, at path: String, logger: Logger) {
        do {
            try fileLock.withLock {
                var records = readRecords(path)
                var record = records[key]?.objectValue ?? [:]
                record.merge(patch) { _, new in new }
                let kept = Set(sentTargets(record).map(\.field))
                record = record.filter { !$0.key.hasPrefix("sent:") || kept.contains($0.key) }
                records[key] = .object(record)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
                let data = try encoder.encode(JSONValue.object(["records": .object(records)]))
                let directory = (path as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        } catch {
            logger.debug("could not write the record at \(path): \(error.localizedDescription)")
        }
    }
}

extension ResolvedBackend {
    init(_ choice: BackendChoice, source: Source) {
        self.init(appId: choice.appId, apiUrl: choice.apiUrl, wsUrl: choice.wsUrl, overridden: choice.overridden, source: source)
    }
}
