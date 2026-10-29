import Foundation
@testable import JsBaoClient

/// Records every request a live client's auth controller sends and forwards
/// it, unchanged, to the dev server through a plain `HttpClient`; the
/// response is the server's own. It fabricates nothing: the server stays the
/// oracle, and the recorder only lets a test read the exact body and count.
@discardableResult
func recordAuthRequests(of client: JsBaoClient, appId: String) -> RecordingTransport {
    let http = HttpClient(config: HttpClientConfig(
        apiUrl: TestConfig.httpUrl,
        appId: appId,
        getToken: { [weak client] in client?.authController.getToken() },
        getConnectionId: { nil },
        getGlobalAdminAppId: { TestConfig.globalAdminAppId },
        logger: Logger(level: .error),
        refreshAccessToken: { .invalid }
    ))
    let recorder = RecordingTransport(responder: { call in
        try await http.execute(
            method: call.method,
            path: call.path,
            body: call.body,
            options: call.options
        )
    })
    client.authController.replaceTransportForTesting(recorder)
    return recorder
}

/// A live client for the sign-in suites: memory storage, no socket, and the
/// given auth options. With no `token` it starts signed out.
func createSignInTestClient(appId: String, token: String? = nil, auth: AuthConfig = AuthConfig()) -> JsBaoClient {
    JsBaoClient(options: JsBaoClientOptions(
        apiUrl: TestConfig.httpUrl,
        wsUrl: TestConfig.wsUrl,
        appId: appId,
        token: token,
        offline: false,
        globalAdminAppId: TestConfig.globalAdminAppId,
        wsHeaders: ["X-Global-Admin-App-Id": TestConfig.globalAdminAppId],
        storageConfig: .memory,
        auth: auth,
        autoNetwork: false
    ))
}

extension RecordingTransport {
    /// Calls to one path, in order.
    func calls(to path: String) -> [RecordedRequest] {
        calls.filter { $0.path == path || $0.path.hasPrefix(path + "?") }
    }
}

extension RecordedRequest {
    /// A top-level string field of the JSON body, if present.
    func bodyString(_ key: String) -> String? {
        jsonBody?.objectValue?[key]?.stringValue
    }

    /// Whether the JSON body carries `key` at all.
    func bodyHasKey(_ key: String) -> Bool {
        jsonBody?.objectValue?[key] != nil
    }
}
