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
        let (data, response) = try await URLSession.shared.data(for: request)
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

    func client(_ name: String, models: [PrimitiveSchema], token: String? = nil) async throws -> JsBaoClient {
        let client = createTestClient(
            appId: app.appId, token: token ?? app.ownerJWT,
            storageConfig: .sqlite(directory: directory + "/\(name)-\(UUID().uuidString.prefix(4)).sqlite"), autoNetwork: true
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
        try await eventually(timeout: 20, description: "the create to commit") {
            client.documentManager.getLocalMetadata(documentId)?.pendingCreate != true
        }
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
