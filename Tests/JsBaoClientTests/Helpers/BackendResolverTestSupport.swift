import Foundation
import XCTest
@testable import JsBaoClient

/// A home app's server for the backend resolver suites (#6185): the policy
/// route answers whatever `policy` holds, and the next `hold` policy reads are
/// held until `releaseHeld()`; every other request answers `{}`.
final class ResolverWorld: @unchecked Sendable {
    static let policyPath = "/settings/client-versions"

    let api: LoopbackAPIServer
    let apiUrl: String
    let appId: String
    let policy = LockedBox(LoopbackAPIServer.Response.json(#"{"clients":{}}"#))
    let hold = LockedBox(0)
    private let held = LockedBox<[@Sendable () -> Void]>([])

    init(appId: String = "home-\(UUID().uuidString.prefix(8).lowercased())") throws {
        self.appId = appId
        let policy = policy, hold = hold, held = held
        api = try LoopbackAPIServer(deferredResponder: { request, respond in
            guard request.apiPathOnly == ResolverWorld.policyPath else { return respond(.json("{}")) }
            let holding = hold.withValue { count -> Bool in
                guard count > 0 else { return false }
                count -= 1
                return true
            }
            if holding {
                held.withValue { $0.append { respond(policy.value) } }
            } else {
                respond(policy.value)
            }
        })
        apiUrl = try api.start()
    }

    func setPolicy(_ body: String) { policy.value = .json(body) }

    /// Answer every held policy read with the policy as it is now.
    func releaseHeld() {
        let pending = held.withValue { list -> [@Sendable () -> Void] in
            defer { list = [] }
            return list
        }
        pending.forEach { $0() }
    }

    var heldCount: Int { held.value.count }

    var policyReads: [LoopbackAPIServer.Request] {
        api.requests.filter { $0.apiPathOnly == Self.policyPath }
    }

    func options(
        version: String? = "2.0",
        platform: String? = "ios",
        storage: StorageConfig = .memory,
        token: String? = nil,
        apiUrl: String? = nil,
        logLevel: LogLevel = .none,
        prefix: String? = nil,
        persistSession: Bool = false
    ) -> JsBaoClientOptions {
        JsBaoClientOptions(
            apiUrl: apiUrl ?? self.apiUrl,
            wsUrl: "ws://127.0.0.1:\(api.port)",
            appId: appId,
            token: token,
            offline: false,
            globalAdminAppId: "global-admin-6185",
            logLevel: logLevel,
            storageConfig: storage,
            auth: AuthConfig(persistJwtInStorage: persistSession, storageKeyPrefix: prefix),
            autoNetwork: false,
            appVersion: version,
            platform: platform
        )
    }

    func stop() { api.stop() }
}

/// A fresh SQLite path for one test: the database file, the record file
/// beside it, and the directory holding both.
struct ResolverStore {
    let dir: URL
    let databasePath: String
    var storage: StorageConfig { .sqlite(directory: databasePath) }
    var recordPath: String { databasePath + ".backend-resolver.json" }

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("backend-resolver-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        databasePath = dir.appendingPathComponent("store.sqlite").path
    }

    var recordExists: Bool { FileManager.default.fileExists(atPath: recordPath) }
    var recordBytes: Data? { FileManager.default.contents(atPath: recordPath) }

    /// The record of `appId` in `namespace`, or `nil`.
    func record(_ appId: String, namespace: String = "default") -> [String: JSONValue]? {
        guard let data = recordBytes,
              let file = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return file.objectValue?["records"]?.objectValue?[resolverRecordKey(appId, namespace)]?.objectValue
    }

    /// The targets the record of `appId` says this copy was sent to, as `appId apiUrl`.
    func sentTargets(_ appId: String, namespace: String = "default") -> [String] {
        (record(appId, namespace: namespace) ?? [:]).compactMap { key, value -> String? in
            guard key.hasPrefix("sent:"), let target = value.objectValue,
                  let id = target["appId"]?.stringValue, let url = target["apiUrl"]?.stringValue else { return nil }
            return "\(id) \(url)"
        }.sorted()
    }

    /// Write the record file as given.
    func writeRecordFile(_ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: recordPath))
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }
}

/// The key of one record in the record file: `[appId, namespace]` as JSON.
func resolverRecordKey(_ appId: String, _ namespace: String) -> String {
    #"[\#(jsonString(appId)),\#(jsonString(namespace))]"#
}

private func jsonString(_ text: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return String(decoding: try! encoder.encode(text), as: UTF8.self)
}

/// The base URL of a loopback port nothing listens on.
func unboundLoopbackUrl() throws -> String {
    let server = try LoopbackAPIServer(responder: { _ in .json("{}") })
    let url = try server.start()
    server.stop()
    return url
}

/// Captures the lines the resolver logs, by level, while installed.
final class ResolverLogCapture: @unchecked Sendable {
    private let lines = LockedBox<[(LogLevel, String)]>([])

    init() {
        let lines = lines
        Logger.lineForTest = { level, scope, message in
            guard scope == "resolveBackend" else { return }
            lines.withValue { $0.append((level, message)) }
        }
    }

    func infoLines(home: String) -> [String] {
        lines.value.filter { $0.0 == .info && $0.1.hasPrefix("home=\(home) ") }.map(\.1)
    }

    var debugLines: [String] { lines.value.filter { $0.0 == .debug }.map(\.1) }

    func uninstall() { Logger.lineForTest = nil }
}
