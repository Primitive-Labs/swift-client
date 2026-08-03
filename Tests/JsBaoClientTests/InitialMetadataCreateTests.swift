import XCTest
@testable import JsBaoClient

/// Live tests for create-time `initialMetadata` on the Swift client's
/// collection- and database-create surfaces (issue #1451, parity with #1420).
///
/// These cover what the Swift surface owns: the parameter reaches the server on
/// both create endpoints and the categories it names are stamped on the new
/// resource, and an invalid entry fails the whole create (all-or-nothing) so the
/// error surfaces to the Swift caller. The server-side rule semantics — the
/// `writeRule` waiver at create and the 10-category cap — are covered by
/// `tests/api/http/app-metadata-initial-create.test.ts`.
///
/// The Swift client has no metadata-categories API yet, so the category configs
/// and the read-back go through `TestContext.appRequest`.
final class InitialMetadataCreateTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-initial-metadata")
        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    /// Define a metadata category config (owner-gated).
    private func createCategory(
        resourceType: String,
        category: String,
        field: String
    ) async throws {
        _ = try await ctx.appRequest(
            method: "POST",
            appId: testApp.appId,
            path: "/metadata-categories",
            body: [
                "resourceType": resourceType,
                "category": category,
                "schema": ["fields": [field: ["type": "string", "required": true]]],
                "readRule": "true",
                "writeRule": "true",
            ],
            jwt: testApp.ownerJWT
        )
    }

    private func readMetadata(
        resourceType: String,
        resourceId: String,
        category: String
    ) async throws -> [String: Any] {
        let result = try await ctx.appRequest(
            method: "GET",
            appId: testApp.appId,
            path: "/resources/\(resourceType)/\(resourceId)/metadata/\(category)",
            body: nil,
            jwt: testApp.ownerJWT
        )
        return (result["data"] as? [String: Any]) ?? [:]
    }

    /// Behavior 6: `collections.create` stamps the named category on the new
    /// collection in the same call.
    func testCollectionCreateStampsInitialMetadata() async throws {
        try await createCategory(resourceType: "collection", category: "gov", field: "tier")

        let created = try await client.collections.create(params: CreateCollectionParams(
            name: "gov-\(Int(Date().timeIntervalSince1970))",
            initialMetadata: ["gov": ["tier": .string("pro")]]
        ))
        XCTAssertFalse(created.collectionId.isEmpty)

        let stamped = try await readMetadata(
            resourceType: "collection",
            resourceId: created.collectionId,
            category: "gov"
        )
        XCTAssertEqual(stamped["tier"] as? String, "pro")
    }

    /// Behavior 7: `databases.create` stamps the named category on the new
    /// database.
    func testDatabaseCreateStampsInitialMetadata() async throws {
        try await createCategory(resourceType: "database", category: "settings", field: "visibility")

        let created = try await client.databases.create(params: CreateDatabaseParams(
            title: "Class Roster",
            databaseType: "roster",
            initialMetadata: ["settings": ["visibility": .string("class-only")]]
        ))
        XCTAssertFalse(created.databaseId.isEmpty)

        let stamped = try await readMetadata(
            resourceType: "database",
            resourceId: created.databaseId,
            category: "settings"
        )
        XCTAssertEqual(stamped["visibility"] as? String, "class-only")
    }

    /// Behavior 8: an unknown category fails the whole create — the Swift call
    /// throws and no collection is left behind.
    func testCollectionCreateWithUnknownCategoryFailsAtomically() async throws {
        let name = "orphan-\(Int(Date().timeIntervalSince1970))"
        await XCTAssertThrowsErrorAsync(
            try await self.client.collections.create(params: CreateCollectionParams(
                name: name,
                initialMetadata: ["nonexistent": ["x": .string("1")]]
            )),
            "create with an unknown metadata category should fail"
        )

        let list = try await client.collections.listAll()
        XCTAssertFalse(list.items.contains { $0.name == name })
    }
}
