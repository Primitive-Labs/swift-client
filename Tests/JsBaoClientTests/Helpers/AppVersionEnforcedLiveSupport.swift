import XCTest
@testable import JsBaoClient

// Set-up for `AppVersionEnforcedLiveTests`: an enforcing `[clients.ios]`
// policy written with the owner's `PUT settings`, and an `ios` client of a
// given version straight against the dev server. Nothing here asks the client
// for its status.

extension TestContext {
    /// Store `[clients.ios]` with `minRequired` and `enforce = true` as the app's policy.
    func pushEnforcingPolicy(_ app: TestApp, minRequired: String) async throws {
        try await updateAppSettings(
            appId: app.appId,
            updates: ["clientVersions": ["ios": ["latest": "3.0", "minRequired": minRequired, "enforce": true]]],
            jwt: app.ownerJWT
        )
    }
}

/// A signed-in `ios` client reporting `version`, with no automatic network
/// and no reconnect jitter, so the test decides its first contact.
func makeEnforcedLiveClient(_ app: TestApp, version: String) -> JsBaoClient {
    let client = JsBaoClient(options: JsBaoClientOptions(
        apiUrl: TestConfig.httpUrl,
        wsUrl: TestConfig.wsUrl,
        appId: app.appId,
        token: app.ownerJWT,
        offline: false,
        globalAdminAppId: TestConfig.globalAdminAppId,
        wsHeaders: ["X-Global-Admin-App-Id": TestConfig.globalAdminAppId],
        logLevel: .warn,
        storageConfig: .memory,
        autoNetwork: false,
        appVersion: version,
        platform: "ios"
    ))
    client.appVersionController.reconnectJitter = 0
    return client
}
