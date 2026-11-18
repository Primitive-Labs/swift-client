import Foundation
import Network
import XCTest
@testable import JsBaoClient

/// An in-process app server and socket server for the client version policy
/// suites (#6036). The policy route answers whatever `policy` holds (after
/// `policyDelay`, so a test can keep a fetch in flight); `/probe` and blob
/// downloads answer `probe`, so a test can hand any request a 426; every other
/// request answers `{}`.
final class AppVersionWorld: @unchecked Sendable {
    /// Version 2.0 on `ios` is below `minRequired`.
    static let requiredPolicy =
        #"{"clients":{"ios":{"latest":"4.0","minRecommended":"3.5","minRequired":"3.0","updateUrl":"itms-apps://example"}}}"#
    /// Version 2.0 on `ios` is current.
    static let currentPolicy = #"{"clients":{"ios":{"latest":"2.0"}}}"#
    /// Version 2.0 on `ios` has an update available.
    static let availablePolicy = #"{"clients":{"ios":{"latest":"2.5"}}}"#
    /// The server's refusal of an outdated client.
    static let refusal = LoopbackAPIServer.Response(
        status: 426, body: #"{"error":"Update required","code":"CLIENT_UPDATE_REQUIRED"}"#
    )

    let api: LoopbackAPIServer
    let apiUrl: String
    let ws: LoopbackWebSocketServer
    let wsUrl: String
    let policy: LockedBox<LoopbackAPIServer.Response>
    let probe: LockedBox<LoopbackAPIServer.Response>
    let policyDelay: LockedBox<TimeInterval>

    init(policy initialPolicy: String = AppVersionWorld.currentPolicy) throws {
        let policy = LockedBox(LoopbackAPIServer.Response.json(initialPolicy))
        let probe = LockedBox(LoopbackAPIServer.Response.json("{}"))
        let policyDelay = LockedBox<TimeInterval>(0)
        self.policy = policy
        self.probe = probe
        self.policyDelay = policyDelay
        api = try LoopbackAPIServer(deferredResponder: { request, respond in
            let path = request.apiPathOnly
            if path == "/settings/client-versions" {
                let answer = policy.value
                let wait = policyDelay.value
                if wait > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + wait) { respond(answer) }
                } else {
                    respond(answer)
                }
            } else if path.hasPrefix("/probe") || path.hasSuffix("/download") {
                respond(probe.value)
            } else {
                respond(.json("{}"))
            }
        })
        apiUrl = try api.start()
        ws = try LoopbackWebSocketServer()
        let url = try ws.start()
        wsUrl = url.absoluteString.hasSuffix("/") ? String(url.absoluteString.dropLast()) : url.absoluteString
    }

    /// Requests for the policy so far.
    var policyFetches: Int {
        api.requests.filter { $0.apiPathOnly == "/settings/client-versions" }.count
    }

    func setPolicy(_ body: String) { policy.value = .json(body) }

    func options(
        appId: String = "app-version-hermetic",
        token: String? = makeTestJwt(userId: "user-av"),
        appVersion: String? = "2.0",
        platform: String? = "ios",
        storage: StorageConfig = .memory,
        autoNetwork: Bool = false
    ) -> JsBaoClientOptions {
        JsBaoClientOptions(
            apiUrl: apiUrl,
            wsUrl: wsUrl,
            appId: appId,
            token: token,
            offline: false,
            logLevel: .none,
            storageConfig: storage,
            autoNetwork: autoNetwork,
            appVersion: appVersion,
            platform: platform
        )
    }

    /// A client of this world. `autoNetwork` clients get a fake monitor that
    /// reports the network up, so nothing depends on the host's real path.
    func client(
        appVersion: String? = "2.0",
        token: String? = makeTestJwt(userId: "user-av"),
        storage: StorageConfig = .memory,
        autoNetwork: Bool = false,
        monitor: FakeConnectivityMonitor? = nil,
        bundleVersion: (@Sendable () -> Any?)? = nil,
        storageSetupHold: (@Sendable () async -> Void)? = nil
    ) -> JsBaoClient {
        let client = JsBaoClient(
            options: options(token: token, appVersion: appVersion, storage: storage, autoNetwork: autoNetwork),
            connectivityMonitor: autoNetwork ? (monitor ?? FakeConnectivityMonitor(initialValue: true)) : nil,
            storageSetupHoldForTest: storageSetupHold,
            bundleVersionForTest: bundleVersion
        )
        // A reconnect's fetch waits a random time (up to 30 s by default).
        // These suites count fetches, so it runs at once unless a test says otherwise.
        client.appVersionController.reconnectJitter = 0
        return client
    }

    /// Hand the client one HTTP refusal, through the client's own transport.
    func refuse(_ client: JsBaoClient) async {
        let previous = probe.value
        probe.value = Self.refusal
        _ = try? await client.gatedTransport.execute(method: .get, path: "/probe", body: nil, options: nil)
        probe.value = previous
    }

    /// Close the socket server's connection `index` with the refusal code.
    func closeWithRefusal(connection index: Int) {
        ws.close(connection: index, code: .privateCode(4426))
    }

    func stop() {
        api.stop()
        ws.stop()
    }
}

/// Records each status a handler is called with.
final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _statuses: [AppVersionStatus] = []
    var statuses: [AppVersionStatus] { lock.withLock { _statuses } }
    func record(_ status: AppVersionStatus) { lock.withLock { _statuses.append(status) } }
}

/// A fresh SQLite directory for one test.
func appVersionTempStore() -> (StorageConfig, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("app-version-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (.sqlite(directory: dir.appendingPathComponent("store.sqlite").path), dir)
}
