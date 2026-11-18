import XCTest
@testable import JsBaoClient

/// Analytics events carry the client's version as `app_version` with no
/// further call (#6036). `setAppVersionOverride` wins over it, and an event's
/// own `app_version` is kept over the client's version.
final class AppVersionAnalyticsHermeticTests: XCTestCase {

    private var world: AppVersionWorld!
    private var clients: [JsBaoClient] = []

    override func setUp() async throws {
        world = try AppVersionWorld()
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        world.stop()
    }

    private func loggedEvents(
        _ client: JsBaoClient,
        _ inputs: [AnalyticsEventInput],
        before: (() async -> Void)? = nil
    ) async throws -> [[String: JSONValue]] {
        let logged = LockedBox<[[String: JSONValue]]>([])
        await client.analyticsQueue.setOnEventLogged { event in
            if event["action"]?.stringValue?.hasPrefix("probe") == true { logged.withValue { $0.append(event) } }
        }
        await before?()
        for input in inputs { await client.analytics.logEventAsync(input) }
        try await eventually(description: "the events are logged") { logged.value.count == inputs.count }
        return logged.value
    }

    // MARK: - Behavior 31

    func testAnEventCarriesTheClientsVersion() async throws {
        let client = world.client(appVersion: "2.3.1")
        clients.append(client)
        let events = try await loggedEvents(client, [AnalyticsEventInput(action: "probe")])
        XCTAssertEqual(events.first?["app_version"], .string("2.3.1"))
    }

    func testAnEventCarriesTheBundleVersionWithNoOption() async throws {
        let client = world.client(appVersion: nil, bundleVersion: { "5.0" })
        clients.append(client)
        let events = try await loggedEvents(client, [AnalyticsEventInput(action: "probe")])
        XCTAssertEqual(events.first?["app_version"], .string("5.0"))
    }

    // MARK: - Behavior 32

    func testTheOverrideWinsAndClearingItRestoresTheClientsVersion() async throws {
        let client = world.client(appVersion: "2.3.1")
        clients.append(client)
        let overridden = try await loggedEvents(
            client,
            [AnalyticsEventInput(action: "probe-override"), AnalyticsEventInput(action: "probe-own", app_version: "1.0")],
            before: { await client.setAnalyticsAppVersionOverrideAsync("9.9.9") }
        )
        XCTAssertEqual(overridden.map { $0["app_version"] }, [.string("9.9.9"), .string("9.9.9")])

        let cleared = try await loggedEvents(
            client,
            [AnalyticsEventInput(action: "probe-cleared"), AnalyticsEventInput(action: "probe-own", app_version: "1.0")],
            before: { await client.setAnalyticsAppVersionOverrideAsync(nil) }
        )
        XCTAssertEqual(
            cleared.map { $0["app_version"] }, [.string("2.3.1"), .string("1.0")],
            "the client's version is back, and an event's own version is kept over it"
        )
    }
}
