import XCTest
@testable import JsBaoClient

/// A Swift app gets-or-creates a tagged LARGE document behind an alias against a
/// real room (#3757, behavior 23).
///
/// The hermetic suite proves the options are encoded. What only a real Durable
/// Object can answer is whether the document the server made is actually large,
/// whether the second call hands back the same one, and what a stated format
/// that the existing document does not have LOOKS like to a Swift caller — the
/// 409's code has to reach the app as `HttpError.serverCode`, because an app
/// branches on that and on nothing else.
final class Format2AliasCreateLiveTests: XCTestCase {

    private var ctx: TestContext!
    private var testApp: TestApp!
    private var directory: String!
    private var clients: [JsBaoClient] = []

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-alias-3757")
        directory = NSTemporaryDirectory() + "f2-alias-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        for client in clients { await client.destroy() }
        clients = []
        try? FileManager.default.removeItem(atPath: directory)
        await ctx?.cleanup()
    }

    private func makeClient() async -> JsBaoClient {
        let client = createTestClient(
            appId: testApp.appId,
            token: testApp.ownerJWT,
            storageConfig: .sqlite(directory: directory + "/store.sqlite"),
            autoNetwork: false
        )
        clients.append(client)
        _ = await client.waitForStorageReady()
        return client
    }

    /// The room's own view — only a large document has an epoch to seal.
    private func sealEpoch(_ documentId: String) async throws -> (Int, String) {
        var request = URLRequest(
            url: URL(string:
                "\(TestConfig.httpUrl)/__test__/document/\(testApp.appId)/\(documentId)/seal-epoch"
            )!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(TestConfig.testAdminToken, forHTTPHeaderField: "X-Test-Auth")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["reason": "format-discriminator-3757"]
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        return (
            (response as? HTTPURLResponse)?.statusCode ?? 0,
            String(data: data, encoding: .utf8) ?? ""
        )
    }

    private var counter = 0
    private func aliasKey() -> String {
        counter += 1
        return "swift-3757-\(Int(Date().timeIntervalSince1970))-\(counter)"
    }

    func testGetOrCreateWithAliasMakesATaggedLargeDocumentAndIsIdempotent() async throws {
        let client = await makeClient()
        let key = aliasKey()

        let first = try await client.documents.getOrCreateWithAlias(
            options: GetOrCreateWithAliasOptions(
                alias: AliasRef(scope: .user, aliasKey: key),
                title: "Ledger",
                tags: ["ledger"],
                documentFormat: 2
            )
        )

        XCTAssertTrue(first.created, "the first call must create the document")
        XCTAssertEqual(first.documentFormat, 2, "the 201 echoes the format it applied")
        XCTAssertEqual(first.tags, ["ledger"])

        // The room classifies it as large — the discriminator, rather than the
        // records projection, which answers for an ordinary document too.
        let (status, body) = try await sealEpoch(first.documentId)
        XCTAssertEqual(status, 200, "seal-epoch answered \(status): \(body)")
        XCTAssertFalse(
            body.contains("not a large document"),
            "the room does not consider the document large: \(body)"
        )

        // The second call is idempotent: the SAME document.
        let second = try await client.documents.getOrCreateWithAlias(
            options: GetOrCreateWithAliasOptions(
                alias: AliasRef(scope: .user, aliasKey: key),
                title: "Ledger",
                tags: ["ledger"],
                documentFormat: 2
            )
        )
        XCTAssertFalse(second.created, "the second call must not create a second document")
        XCTAssertEqual(second.documentId, first.documentId)
        XCTAssertEqual(second.documentFormat, 2, "a matching stated format is echoed")
    }

    func testAStatedFormatTheDocumentDoesNotHaveSurfacesAsTheServerCode() async throws {
        let client = await makeClient()
        let key = aliasKey()

        // An ORDINARY document behind the alias, created the same way — the
        // positive control that the refusal below is about the format and not
        // about the route or the caller.
        let ordinary = try await client.documents.getOrCreateWithAlias(
            options: GetOrCreateWithAliasOptions(
                alias: AliasRef(scope: .user, aliasKey: key),
                title: "Ordinary"
            )
        )
        XCTAssertTrue(ordinary.created)
        XCTAssertNil(
            ordinary.documentFormat,
            "an ordinary create's response names no format"
        )

        do {
            _ = try await client.documents.getOrCreateWithAlias(
                options: GetOrCreateWithAliasOptions(
                    alias: AliasRef(scope: .user, aliasKey: key),
                    title: "Ordinary",
                    documentFormat: 2
                )
            )
            XCTFail("a stated format the document does not have must be refused")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 409)
            // An app branches on the code and on nothing else, so the code is
            // what has to arrive — not merely a 409.
            XCTAssertEqual(error.serverCode, "DOCUMENT_FORMAT_MISMATCH")
            XCTAssertTrue(
                (error.serverMessage ?? "").contains(ordinary.documentId),
                "the refusal does not name the document: \(error.serverMessage ?? "")"
            )
        }

        // Nothing was created: the alias still names the same document.
        let again = try await client.documents.getOrCreateWithAlias(
            options: GetOrCreateWithAliasOptions(
                alias: AliasRef(scope: .user, aliasKey: key),
                title: "Ordinary"
            )
        )
        XCTAssertFalse(again.created)
        XCTAssertEqual(again.documentId, ordinary.documentId)
    }

    func testCreateWithAliasStoresTagsAndMetadata() async throws {
        let client = await makeClient()

        let created = try await client.documents.createWithAlias(
            options: CreateWithAliasOptions(
                title: "Ledger",
                alias: AliasRef(scope: .user, aliasKey: aliasKey()),
                tags: ["ledger", "q3"],
                metadata: .object(["owner": .string("finance")]),
                documentFormat: 2
            )
        )

        XCTAssertEqual(created.tags?.sorted(), ["ledger", "q3"])
        XCTAssertEqual(created.metadata, .object(["owner": .string("finance")]))
        XCTAssertEqual(created.documentFormat, 2)

        // Stored, not merely echoed.
        let info = try await client.documents.get(documentId: created.documentId)
        XCTAssertEqual(info.documentFormat, 2)
        XCTAssertEqual(info.tags?.sorted(), ["ledger", "q3"])
    }
}
