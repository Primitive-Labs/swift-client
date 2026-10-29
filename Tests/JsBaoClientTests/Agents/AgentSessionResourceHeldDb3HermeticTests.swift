import XCTest
@testable import JsBaoClient

/// A db3 a resource holds is opened with no `documents` request (#4884
/// behavior 6, intent criterion 5): once `noteResourceHeldDb3` names it (what
/// a session view's subscribe does first), its format is 3 with the
/// documents API's format lookup never asked, and the open's permission
/// bootstrap takes `reader` (every caller who may open it reads it only) with
/// the document-info refresh never run. A db3 nothing noted still asks both.
///
/// Server-free: the client's two hooks (`documentFormatLookupForTest`, the
/// document manager's `fetchDocumentInfo`) are what it would call, counted.
final class AgentSessionResourceHeldDb3HermeticTests: XCTestCase {
    private var clients: [JsBaoClient] = []
    private var directories: [String] = []

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
    }

    /// A client on SQLite storage (a db3 needs a persistent store), never connecting.
    private func makeClient() async throws -> JsBaoClient {
        let directory = NSTemporaryDirectory() + "resource-held-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1", wsUrl: "ws://127.0.0.1:1", appId: "resource-held-db3",
            token: makeTestJwt(userId: "u1"), offline: false, logLevel: .none,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"), autoNetwork: false
        ))
        clients.append(client)
        _ = await client.waitForStorageReady()
        return client
    }

    private func documentInfo(_ documentId: String, permission: String) throws -> DocumentInfo {
        try JSONDecoder().decode(DocumentInfo.self, from: Data(
            #"{"documentId":"\#(documentId)","title":"t","permission":"\#(permission)","documentFormat":3}"#.utf8
        ))
    }

    func testANotedDb3IsFormatThreeWithoutTheDocumentsFormatLookup() async throws {
        let client = try await makeClient()
        let lookups = LockedBox<[String]>([])
        client.documentFormatLookupForTest = { id in
            lookups.withValue { $0.append(id) }
            return 3
        }
        client.documentManager.fetchDocumentInfo = { [self] id in try documentInfo(id, permission: "read-write") }
        client.noteResourceHeldDb3("held-db3")
        let format = await client.db3FormatOf("held-db3")
        XCTAssertEqual(format, 3)

        // Both opened before the socket is up: the handshake asks the format
        // of a document nothing local names, and of the noted db3 nothing.
        let options = OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        _ = try await client.openDocument("held-db3", options: options)
        _ = try await client.openDocument("plain-db3", options: options)
        client.setNetworkMode(.online)
        _ = await client.resolveRecordLogBeforeHandshake("held-db3")
        _ = await client.resolveRecordLogBeforeHandshake("plain-db3")
        XCTAssertEqual(lookups.value, ["plain-db3"], "only the db3 nothing noted is asked about")
    }

    func testANotedDb3OpensAsAReaderWithoutTheDocumentInfoRefresh() async throws {
        let client = try await makeClient()
        let infos = LockedBox<[String]>([])
        client.documentFormatLookupForTest = { _ in 3 }
        client.documentManager.fetchDocumentInfo = { [self] id in
            infos.withValue { $0.append(id) }
            return try documentInfo(id, permission: "read-write")
        }
        client.noteResourceHeldDb3("held-db3")
        let options = OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        _ = try await client.openDocument("held-db3", options: options)
        XCTAssertEqual(client.documentManager.getPermission("held-db3"), .reader, "a resource-held db3 is read only")
        XCTAssertTrue(client.isDocumentReadOnly("held-db3"))

        _ = try await client.openDocument("plain-db3", options: options)
        try await eventually(description: "the other document's permission refresh") { infos.value == ["plain-db3"] }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(infos.value, ["plain-db3"], "the noted db3's open read no document info")
        XCTAssertEqual(client.documentManager.getPermission("held-db3"), .reader)
    }
}
