import Foundation
import XCTest
@testable import JsBaoClient
import YSwift

/// Create a test JsBaoClient configured for integration testing.
func createTestClient(
    appId: String,
    token: String,
    globalAdminAppId: String = TestConfig.globalAdminAppId,
    offline: Bool = false,
    storageConfig: StorageConfig = .memory,
    autoNetwork: Bool = false,
    logLevel: LogLevel = .warn
) -> JsBaoClient {
    JsBaoClient(options: JsBaoClientOptions(
        apiUrl: TestConfig.httpUrl,
        wsUrl: TestConfig.wsUrl,
        appId: appId,
        token: token,
        offline: offline,
        globalAdminAppId: globalAdminAppId,
        wsHeaders: ["X-Global-Admin-App-Id": globalAdminAppId],
        logLevel: logLevel,
        storageConfig: storageConfig,
        autoNetwork: autoNetwork
    ))
}

/// Wait for the client to reach "connected" status.
func waitForConnection(client: JsBaoClient, timeout: TimeInterval = 5) async throws {
    if client.isConnected { return }

    let deadline = Date().addingTimeInterval(timeout)
    while !client.isConnected {
        if Date() > deadline {
            throw JsBaoError(code: .unavailable, message: "Timeout waiting for connection")
        }
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
    }
}

/// Wait for a document to be synced.
func waitForSync(client: JsBaoClient, documentId: String, timeout: TimeInterval = 10) async throws {
    if client.isSynced(documentId) { return }

    let deadline = Date().addingTimeInterval(timeout)
    while !client.isSynced(documentId) {
        if Date() > deadline {
            throw JsBaoError(code: .unavailable, message: "Timeout waiting for sync on \(documentId)")
        }
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
    }
}

/// Poll until a condition is true or timeout.
func eventually(
    timeout: TimeInterval = 5,
    interval: TimeInterval = 0.05,
    description: String = "condition",
    check: () async throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    var lastError: Error?
    while Date() < deadline {
        do {
            if try await check() { return }
        } catch {
            lastError = error
        }
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    XCTFail("Timeout waiting for \(description)\(lastError.map { ": \($0)" } ?? "")")
}

/// Poll until check returns a non-nil value or timeout.
func eventuallyValue<T>(
    timeout: TimeInterval = 5,
    interval: TimeInterval = 0.05,
    description: String = "value",
    check: () async throws -> T?
) async throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    var lastError: Error?
    while Date() < deadline {
        do {
            if let value = try await check() { return value }
        } catch {
            lastError = error
        }
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    throw JsBaoError(
        code: .unavailable,
        message: "Timeout waiting for \(description)\(lastError.map { ": \($0)" } ?? "")"
    )
}

/// Collect events emitted during a block.
func collectEvents(
    from emitter: EventEmitter,
    event: JsBaoEvent,
    during block: () async throws -> Void
) async rethrows -> [Any] {
    var events: [Any] = []
    let sub = emitter.onAny(event) { payload in
        events.append(payload)
    }
    try await block()
    sub.cancel()
    return events
}

/// Sleep for given seconds.
func delay(_ seconds: TimeInterval) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}
