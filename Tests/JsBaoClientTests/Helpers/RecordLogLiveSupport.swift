import Foundation
import XCTest
@testable import JsBaoClient

extension TestContext {
    /// One of a record-log document's test routes:
    /// `POST /__test__/document/{appId}/{documentId}/{action}` with
    /// `X-Test-Auth` — `state`, `rotate`, `checkpoint`, `set-limits`,
    /// `drop-writer`, `fail-delivery` — the lever the JS live suites use.
    @discardableResult
    func documentTestRoute(
        appId: String, documentId: String, action: String, body: [String: Any] = [:]
    ) async throws -> [String: Any] {
        guard let url = URL(string: "\(TestConfig.httpUrl)/__test__/document/\(appId)/\(documentId)/\(action)") else {
            throw TestSetupError("bad test route URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ProcessInfo.processInfo.environment["TEST_ADMIN_TOKEN"] ?? "local-test-secret", forHTTPHeaderField: "X-Test-Auth")
        request.setValue(TestConfig.globalAdminAppId, forHTTPHeaderField: "X-Global-Admin-App-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // A pooled connection the dev server closed while it sat idle fails the
        // next request on it with "the network connection was lost" before the
        // request is read. URLSession sends an idempotent method again on its
        // own but not a POST, so this sends it once more on a fresh connection.
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .networkConnectionLost {
            (data, response) = try await URLSession.shared.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw TestSetupError("\(action) answered \(status): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// The room's authoritative rows of `model`, by id.
    func roomRows(appId: String, documentId: String, model: String, jwt: String) async throws -> [String: [String: Any]] {
        let answer = try await appRequest(
            method: "GET", appId: appId, path: "/documents/\(documentId)/records/\(model)?limit=200", body: nil, jwt: jwt
        )
        let items = (answer["items"] as? [[String: Any]]) ?? (answer["records"] as? [[String: Any]]) ?? []
        var rows: [String: [String: Any]] = [:]
        for item in items {
            if let id = item["id"] as? String { rows[id] = item }
        }
        return rows
    }
}

/// Wait for a create to leave `pendingCreate`. On a timeout the failure names
/// what the client knows about the commit (its last error, the retry count, the
/// next attempt, whether networking is allowed and the socket is up), so a
/// stalled commit says why instead of only that it timed out.
func waitForCreateCommit(
    _ client: JsBaoClient, _ documentId: String, timeout: TimeInterval = 20,
    file: StaticString = #filePath, line: UInt = #line
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if client.documentManager.getLocalMetadata(documentId)?.pendingCreate != true { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let meta = client.documentManager.getLocalMetadata(documentId)
    guard meta?.pendingCreate == true else { return }
    XCTFail(
        "Timeout waiting for the create of \(documentId) to commit: "
            + "commitError=\(meta?.commitError?.message ?? "nil") "
            + "retries=\(meta?.commitRetryCount ?? 0) "
            + "nextAttemptAt=\(meta?.nextCommitAttemptAt ?? "nil") "
            + "networkingAllowed=\(client.networkingAllowed()) "
            + "connected=\(client.isConnected) "
            + "pendingCreates=\(client.documentManager.listPendingCreates())",
        file: file, line: line
    )
}

/// A live format-3 app: clients over their own databases, documents created
/// as `documentFormat: 3`, and what each client's store holds.
final class RecordLogLiveApp {
    let ctx: TestContext
    let app: TestApp
    let directory: String
    private(set) var clients: [JsBaoClient] = []

    init(ctx: TestContext, app: TestApp) throws {
        self.ctx = ctx
        self.app = app
        directory = NSTemporaryDirectory() + "rl-live-app-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    /// A file of this app's directory, for clients that share one store (one at a time).
    func file(_ name: String) -> String { directory + "/\(name).sqlite" }

    func client(_ name: String, models: [PrimitiveSchema], token: String? = nil, file: String? = nil) async throws -> JsBaoClient {
        let client = createTestClient(
            appId: app.appId, token: token ?? app.ownerJWT,
            storageConfig: .sqlite(directory: file ?? directory + "/\(name)-\(UUID().uuidString.prefix(4)).sqlite"), autoNetwork: true
        )
        client.registerModels(models)
        clients.append(client)
        _ = await client.waitForStorageReady()
        try await client.connect()
        try await waitForConnection(client: client, timeout: 10)
        return client
    }

    func createDocument(_ client: JsBaoClient) async throws -> String {
        let created = try await client.createDocument(options: CreateDocumentOptions(title: "record log", documentFormat: 3))
        let documentId = try XCTUnwrap(created.metadata?["documentId"]?.stringValue)
        try await waitForCreateCommit(client, documentId)
        return documentId
    }

    func open(_ client: JsBaoClient, _ documentId: String) async throws {
        _ = try await client.openDocument(documentId, options: OpenDocumentOptions(waitForLoad: .network, enableNetworkSync: true))
        try await waitForSync(client: client, documentId: documentId, timeout: 30)
    }

    func member(_ client: JsBaoClient, _ documentId: String, _ model: String) throws -> DynamicModel {
        try XCTUnwrap(client.sharedModel(model)?.member(docId: documentId))
    }

    func binding(_ client: JsBaoClient, _ documentId: String) throws -> RecordLogDocumentBinding {
        try XCTUnwrap(client.recordLogBinding(documentId))
    }

    /// This client's writer's entries the room has not judged.
    func pending(_ client: JsBaoClient, _ documentId: String) throws -> [RecordLogPendingEntry] {
        let binding = try binding(client, documentId)
        return try binding.store.pendingOf(binding.writer)
    }

    /// Wait until this client holds no unjudged entry of its own writer.
    func settled(_ client: JsBaoClient, _ documentId: String, timeout: TimeInterval = 30) async throws {
        try await eventually(timeout: timeout, description: "\(documentId)'s entries to settle") {
            try self.pending(client, documentId).isEmpty
        }
    }

    func route(_ documentId: String, _ action: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        try await ctx.documentTestRoute(appId: app.appId, documentId: documentId, action: action, body: body)
    }

    func roomRows(_ documentId: String, _ model: String) async throws -> [String: [String: Any]] {
        try await ctx.roomRows(appId: app.appId, documentId: documentId, model: model, jwt: app.ownerJWT)
    }

    func destroy() async {
        for client in clients { await client.destroy() }
        clients = []
        try? FileManager.default.removeItem(atPath: directory)
    }
}

/// #5000 — a live client's db3 commits, held. The client's
/// `documentManager.createRemoteDb3` (the hook that sends a pending db3
/// create's `POST db3`) is wrapped: each commit is recorded, waits until
/// `open()`, and is then forwarded to the original hook, which sends it to
/// the server. `failNext(_:)` makes the next forwarded commit throw that error
/// instead of being sent (once).
final class HeldDb3Commit: @unchecked Sendable {
    private let gate = RecordLogReceiptHarness.Gate()
    private let sent = LockedBox<[[String: JSONValue]]>([])
    private let failure = LockedBox<Error?>(nil)

    /// Every commit body the client handed the hook, in order.
    var bodies: [[String: JSONValue]] { sent.value }

    /// Let every held commit, and every later one, through to the server.
    func open() { gate.open() }

    /// Answer the next forwarded commit with `error`, sending nothing.
    func failNext(_ error: Error) { failure.value = error }

    fileprivate func record(_ body: JSONValue) { sent.withValue { $0.append(body.objectValue ?? [:]) } }
    fileprivate func waitOpen() async { await gate.wait() }
    fileprivate func takeFailure() -> Error? { failure.withValue { error in defer { error = nil }; return error } }
}

/// Hold `client`'s db3 commits until the answer's `open()` (see ``HeldDb3Commit``).
func heldDb3Commit(_ client: JsBaoClient) -> HeldDb3Commit {
    let held = HeldDb3Commit()
    let original = client.documentManager.createRemoteDb3
    client.documentManager.createRemoteDb3 = { body in
        held.record(body)
        await held.waitOpen()
        if let error = held.takeFailure() { throw error }
        guard let original else { throw JsBaoError(code: .unavailable, message: "no db3 commit hook") }
        return try await original(body)
    }
    return held
}

/// #5000 — `client.db3.create`, returning once the server has the db3. A
/// local-first create returns before its commit lands, so a test that reads
/// the server's copy right after one waits here. It asks
/// `commitOfflineCreate(documentId:)` for the verdict: `created`, or
/// `not_pending` once the create is no longer pending (the commit landed
/// first), returns; `refused` throws; a transient failure waits for the
/// backoff's commit, until `timeout`.
func createdOnServer(
    _ client: JsBaoClient, title: String, type: String? = nil, tags: [String]? = nil, timeout: TimeInterval = 10
) async throws -> Db3Info {
    let info = try await client.db3.create(title: title, type: type, tags: tags)
    let verdict: [String: Any]
    do {
        verdict = try await client.commitOfflineCreate(documentId: info.id)
    } catch {
        verdict = [:]
    }
    if verdict["created"] as? Bool == true { return info }
    if verdict["refused"] as? Bool == true {
        throw TestSetupError("the server refused \(info.id): \(verdict["reason"] as? String ?? "")")
    }
    let deadline = Date().addingTimeInterval(timeout)
    while client.isPendingCreate(info.id) {
        guard Date() < deadline else { throw TestSetupError("timed out waiting for \(info.id) on the server (last: \(verdict))") }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    return info
}
