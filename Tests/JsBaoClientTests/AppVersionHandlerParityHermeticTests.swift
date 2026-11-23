import XCTest
@testable import JsBaoClient

/// `onStatusChange` is called on the same reads as the JavaScript client's
/// listener: on any change of what the client reports (the status, this
/// platform's policy entry, or a refusal), not only on a change of status.
final class AppVersionHandlerParityHermeticTests: XCTestCase {

    private var world: AppVersionWorld!
    private var clients: [JsBaoClient] = []

    override func setUp() async throws {
        world = try AppVersionWorld(policy: AppVersionWorld.availablePolicy)
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        world.stop()
    }

    private func client(appVersion: String? = "2.0", bundleVersion: (@Sendable () -> Any?)? = nil) -> JsBaoClient {
        let client = world.client(appVersion: appVersion, bundleVersion: bundleVersion)
        clients.append(client)
        return client
    }

    func testARaisedLatestThatKeepsTheStatusCallsTheHandlerOnce() async throws {
        let client = client()
        let first = await client.appVersion.getStatus()
        XCTAssertEqual(first, .updateAvailable)
        let recorder = StatusRecorder()
        let subscription = client.appVersion.onStatusChange { recorder.record($0) }
        defer { subscription.cancel() }

        world.setPolicy(#"{"clients":{"ios":{"latest":"2.6"}}}"#)
        let raised = await client.appVersion.refresh()
        XCTAssertEqual(raised, .updateAvailable, "the status stays the same")
        try await eventually(description: "the raised latest reaches the handler") {
            recorder.statuses == [.updateAvailable]
        }
        let entry = await client.appVersion.getPolicy()
        XCTAssertEqual(entry?.latest, "2.6")

        _ = await client.appVersion.refresh()
        try await delay(0.1)
        XCTAssertEqual(recorder.statuses, [.updateAvailable], "the same entry again calls nobody")
    }

    func testAnAddedUpdateUrlCallsTheHandler() async throws {
        let client = client()
        _ = await client.appVersion.getStatus()
        let recorder = StatusRecorder()
        let subscription = client.appVersion.onStatusChange { recorder.record($0) }
        defer { subscription.cancel() }

        world.setPolicy(#"{"clients":{"ios":{"latest":"2.5","updateUrl":"itms-apps://example"}}}"#)
        _ = await client.appVersion.refresh()
        try await eventually(description: "the new entry reaches the handler") {
            recorder.statuses == [.updateAvailable]
        }
    }

    func testARefusalWhileThePolicyAlreadyRequiresAnUpdateCallsTheHandler() async throws {
        world.setPolicy(AppVersionWorld.requiredPolicy)
        let client = client()
        let required = await client.appVersion.getStatus()
        XCTAssertEqual(required, .updateRequired)
        let recorder = StatusRecorder()
        let subscription = client.appVersion.onStatusChange { recorder.record($0) }
        defer { subscription.cancel() }

        await world.refuse(client)
        XCTAssertTrue(client.appVersionController.isRefused)
        try await eventually(description: "the refusal reaches the handler") {
            recorder.statuses == [.updateRequired]
        }
        try await eventually(description: "the refusal fetches") { self.world.policyFetches == 2 }
        try await delay(0.1)
        XCTAssertEqual(recorder.statuses, [.updateRequired], "a fetch that keeps the refusal calls nobody")
    }

    func testWithoutAVersionAnEntryChangeCallsNobody() async throws {
        let client = client(appVersion: nil, bundleVersion: { nil })
        XCTAssertNil(client.appVersion.version)
        let first = await client.appVersion.getStatus()
        XCTAssertEqual(first, .unknown)
        let recorder = StatusRecorder()
        let subscription = client.appVersion.onStatusChange { recorder.record($0) }
        defer { subscription.cancel() }

        world.setPolicy(#"{"clients":{"ios":{"latest":"2.6"}}}"#)
        _ = await client.appVersion.refresh()
        try await delay(0.1)
        XCTAssertEqual(recorder.statuses, [], "with no version nothing is reported, so nothing changes")
    }
}
