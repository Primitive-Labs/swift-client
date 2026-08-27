import XCTest
@testable import JsBaoClient

/// Live tests for the resource-metadata value API (`client.resourceMetadata.*`)
/// against the local dev server — the Swift mirror of the JS client's
/// `tests/client/js-bao-client-resource-metadata.test.ts` (#1352 / #1402 /
/// #1373).
///
/// Category *definitions* are admin-scoped and deliberately have no client
/// surface, so they are seeded over the admin-gated `metadata-categories` REST
/// route through `TestContext.appRequest` (the same approach
/// `InitialMetadataCreateTests` uses). Everything after that goes through the
/// Swift client.
///
/// These run as the app owner, which carries the app-level rule bypass, so the
/// per-category *rule denial* arms are not exercised here — a second app
/// identity would be needed and `TestContext.createTestUser` currently fails
/// server-side on this environment (`add-by-email` 500, #1951/#2070, which also
/// fails on untouched tests such as `DocumentPermissionsTests`). The denial
/// shapes are pinned instead by `ResourceMetadataAPITests` (single-call 403 →
/// `HttpError`; per-category `ok: false` decode; a rule-denied `resolve`
/// decoding identically to a miss) and by the JS client suite, which exercises
/// them against the same endpoints. The partial-success behavior itself IS
/// covered live below, using an undefined category as the failing entry.
final class ResourceMetadataTests: XCTestCase {
    var ctx: TestContext!
    var testApp: TestApp!
    var client: JsBaoClient!

    /// A resource id that exists (the app owner's user).
    private var subjectId: String { testApp.ownerUserId }
    /// A second, never-written resource id — for the "nothing stored" reads.
    private let untouchedId = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        testApp = try await ctx.createTestApp(name: "swift-resource-metadata")

        try await createCategory(
            category: "profile",
            fields: [
                "tier": ["type": "string", "required": true],
                "note": ["type": "string"],
            ]
        )
        try await createCategory(
            category: "prefs",
            fields: ["theme": ["type": "string"]]
        )
        // The reverse-resolve category (#2139): one activated `unique` field
        // plus a plain one, so both the hit/miss arms and the
        // `NOT_UNIQUE_FIELD` config error are reachable.
        try await createCategory(
            category: "billing",
            fields: [
                "stripeCustomerId": ["type": "string", "unique": true],
                "status": ["type": "string"],
            ]
        )

        client = createTestClient(appId: testApp.appId, token: testApp.ownerJWT)
    }

    override func tearDown() async throws {
        await client?.destroy()
        await ctx.cleanup()
    }

    private func createCategory(
        resourceType: String = "user",
        category: String,
        fields: [String: [String: Any]],
        readRule: String = "true",
        writeRule: String = "true"
    ) async throws {
        _ = try await ctx.appRequest(
            method: "POST",
            appId: testApp.appId,
            path: "/metadata-categories",
            body: [
                "resourceType": resourceType,
                "category": category,
                "schema": ["fields": fields],
                "readRule": readRule,
                "writeRule": writeRule,
            ],
            jwt: testApp.ownerJWT
        )
    }

    // MARK: - set / get round trip (behaviors 1, 2)

    func testSetThenGetRoundTripsTheStoredValue() async throws {
        let written = try await client.resourceMetadata.set(
            resourceType: "user",
            resourceId: subjectId,
            category: "profile",
            data: ["tier": "pro", "note": "hello"]
        )
        XCTAssertEqual(written.resourceType, "user")
        XCTAssertEqual(written.resourceId, subjectId)
        XCTAssertEqual(written.category, "profile")
        XCTAssertEqual(written.data["tier"], .string("pro"))
        XCTAssertEqual(written.data["note"], .string("hello"))
        XCTAssertGreaterThan(written.schemaVersion, 0)
        XCTAssertGreaterThan(written.size, 0)

        let read = try await client.resourceMetadata.get(
            resourceType: "user", resourceId: subjectId, category: "profile"
        )
        XCTAssertTrue(read.exists)
        XCTAssertEqual(read.schemaVersion, written.schemaVersion)
        XCTAssertEqual(read.data["tier"], .string("pro"))
        XCTAssertEqual(read.data["note"], .string("hello"))

        // `set` is a full replace, not a merge: the omitted `note` is gone.
        _ = try await client.resourceMetadata.set(
            resourceType: "user",
            resourceId: subjectId,
            category: "profile",
            data: ["tier": "free"]
        )
        let replaced = try await client.resourceMetadata.get(
            resourceType: "user", resourceId: subjectId, category: "profile"
        )
        XCTAssertEqual(replaced.data["tier"], .string("free"))
        XCTAssertNil(replaced.data["note"], "set is a replace — the omitted key must be gone")
    }

    // MARK: - Empty read (behavior 3)

    func testGetOnAResourceWithNothingStoredSucceedsWithExistsFalse() async throws {
        let read = try await client.resourceMetadata.get(
            resourceType: "user", resourceId: untouchedId, category: "profile"
        )
        XCTAssertFalse(read.exists, "An unwritten category reads as exists: false")
        XCTAssertNil(read.schemaVersion)
        XCTAssertTrue(read.data.isEmpty)
        XCTAssertEqual(read.resourceId, untouchedId)
    }

    // MARK: - Batch (behaviors 4, 5, 6)

    func testGetBatchReturnsPerResourcePerCategoryResults() async throws {
        _ = try await client.resourceMetadata.set(
            resourceType: "user", resourceId: subjectId,
            category: "profile", data: ["tier": "pro"]
        )
        _ = try await client.resourceMetadata.set(
            resourceType: "user", resourceId: subjectId,
            category: "prefs", data: ["theme": "dark"]
        )

        let batch = try await client.resourceMetadata.getBatch(requests: [
            .init(resourceType: "user", resourceId: subjectId, categories: ["profile", "prefs"]),
            .init(resourceType: "user", resourceId: untouchedId, categories: ["profile"]),
        ])

        // Results come back in request order, one entry per request item.
        XCTAssertEqual(batch.results.count, 2)
        XCTAssertEqual(batch.results.map(\.resourceId), [subjectId, untouchedId])

        let written = try XCTUnwrap(batch.results.first)
        XCTAssertTrue(written.ok)
        let profile = try XCTUnwrap(written.categories?["profile"])
        XCTAssertTrue(profile.ok)
        XCTAssertEqual(profile.exists, true)
        XCTAssertEqual(profile.data?["tier"], .string("pro"))
        XCTAssertNil(profile.error)
        let prefs = try XCTUnwrap(written.categories?["prefs"])
        XCTAssertEqual(prefs.data?["theme"], .string("dark"))

        // A resource with nothing stored is a successful entry with exists:false
        // — the batch never turns an empty read into an error.
        let empty = try XCTUnwrap(batch.results.last?.categories?["profile"])
        XCTAssertTrue(empty.ok)
        XCTAssertEqual(empty.exists, false)
    }

    /// Behavior 5: a per-category failure (here, a category that is not defined
    /// for the resource type) is reported as an `ok: false` entry inside a
    /// successful call, and its readable sibling still resolves.
    func testGetBatchIsPartialSuccessWhenOneCategoryFails() async throws {
        _ = try await client.resourceMetadata.set(
            resourceType: "user", resourceId: subjectId,
            category: "profile", data: ["tier": "pro"]
        )

        let batch = try await client.resourceMetadata.getBatch(requests: [
            .init(
                resourceType: "user",
                resourceId: subjectId,
                categories: ["profile", "no-such-category"]
            ),
        ])

        let item = try XCTUnwrap(batch.results.first)
        XCTAssertTrue(item.ok, "A per-category failure must not fail the whole item")

        let good = try XCTUnwrap(item.categories?["profile"])
        XCTAssertTrue(good.ok, "The readable sibling category still resolves")
        XCTAssertEqual(good.data?["tier"], .string("pro"))

        let bad = try XCTUnwrap(item.categories?["no-such-category"])
        XCTAssertFalse(bad.ok)
        XCTAssertNil(bad.data, "A failed entry never carries data")
        let error = try XCTUnwrap(bad.error)
        XCTAssertGreaterThanOrEqual(error.status, 400)
        XCTAssertFalse(error.code.isEmpty)
        XCTAssertFalse(error.message.isEmpty)
    }

    /// Behavior 6: an item that omits its categories is a whole-item fault — a
    /// per-resource `ok: false` entry with no `categories` map, still inside a
    /// 200.
    func testGetBatchReportsWholeItemFaultsWithoutFailingTheCall() async throws {
        let batch = try await client.resourceMetadata.getBatch(requests: [
            .init(resourceType: "user", resourceId: subjectId, categories: []),
        ])

        let item = try XCTUnwrap(batch.results.first)
        XCTAssertFalse(item.ok, "An empty `categories` list is an item-level fault")
        XCTAssertNil(item.categories)
        let error = try XCTUnwrap(item.error)
        XCTAssertEqual(error.status, 400)
        XCTAssertFalse(error.code.isEmpty)
    }

    // MARK: - list (behavior 7)

    func testListReturnsEveryReadableStoredCategory() async throws {
        _ = try await client.resourceMetadata.set(
            resourceType: "user", resourceId: subjectId,
            category: "profile", data: ["tier": "pro"]
        )
        _ = try await client.resourceMetadata.set(
            resourceType: "user", resourceId: subjectId,
            category: "prefs", data: ["theme": "dark"]
        )

        let listed = try await client.resourceMetadata.list(
            resourceType: "user", resourceId: subjectId
        )
        XCTAssertEqual(listed.resourceType, "user")
        XCTAssertEqual(listed.resourceId, subjectId)
        let names = Set(listed.categories.map(\.category))
        XCTAssertTrue(names.contains("profile"))
        XCTAssertTrue(names.contains("prefs"))

        let profile = try XCTUnwrap(listed.categories.first { $0.category == "profile" })
        XCTAssertEqual(profile.data["tier"], .string("pro"))
        XCTAssertNotNil(profile.schemaVersion)
    }

    func testListOnAResourceWithNoMetadataReturnsAnEmptyArray() async throws {
        let listed = try await client.resourceMetadata.list(
            resourceType: "user", resourceId: untouchedId
        )
        XCTAssertTrue(listed.categories.isEmpty, "No stored metadata is an empty list, not an error")
    }

    // MARK: - delete (behavior 8)

    func testDeleteRemovesTheCategoryAndIsIdempotent() async throws {
        _ = try await client.resourceMetadata.set(
            resourceType: "user", resourceId: subjectId,
            category: "profile", data: ["tier": "pro"]
        )

        let deleted = try await client.resourceMetadata.delete(
            resourceType: "user", resourceId: subjectId, category: "profile"
        )
        XCTAssertTrue(deleted.deleted)
        XCTAssertEqual(deleted.category, "profile")

        let afterDelete = try await client.resourceMetadata.get(
            resourceType: "user", resourceId: subjectId, category: "profile"
        )
        XCTAssertFalse(afterDelete.exists)

        // Idempotent: deleting the now-absent item is a success, not a 404.
        let again = try await client.resourceMetadata.delete(
            resourceType: "user", resourceId: subjectId, category: "profile"
        )
        XCTAssertFalse(again.deleted, "Deleting an absent item succeeds with deleted: false")
    }

    // MARK: - resolve (#2139)

    /// A written unique value resolves back to the resource that owns it, and a
    /// value nobody owns is a SUCCESS with `resourceId == nil` — not an error.
    func testResolveReturnsTheOwningResourceAndNilForAMiss() async throws {
        _ = try await client.resourceMetadata.set(
            resourceType: "user", resourceId: subjectId,
            category: "billing", data: ["stripeCustomerId": "cus_SWIFT_A"]
        )

        let hit = try await client.resourceMetadata.resolve(
            resourceType: "user",
            category: "billing",
            key: "stripeCustomerId",
            value: "cus_SWIFT_A"
        )
        XCTAssertEqual(hit.resourceId, subjectId)
        XCTAssertEqual(hit.resourceType, "user")
        XCTAssertEqual(
            hit.resolved,
            ResourceMetadataResolvedResource(resourceId: subjectId, resourceType: "user")
        )

        let miss = try await client.resourceMetadata.resolve(
            resourceType: "user",
            category: "billing",
            key: "stripeCustomerId",
            value: "cus_NOT_A_REAL_VALUE"
        )
        XCTAssertNil(miss.resourceId, "A value nobody owns is a miss, not an error")
        XCTAssertNil(miss.resourceType)
        XCTAssertNil(miss.resolved)
    }

    /// Edge case: the empty string is a valid `string` value and IS indexed on
    /// write, so it must resolve like any other value rather than reading as a
    /// miss.
    func testResolveFindsAnEmptyStringValue() async throws {
        _ = try await client.resourceMetadata.set(
            resourceType: "user", resourceId: subjectId,
            category: "billing", data: ["stripeCustomerId": ""]
        )

        let hit = try await client.resourceMetadata.resolve(
            resourceType: "user",
            category: "billing",
            key: "stripeCustomerId",
            value: ""
        )
        XCTAssertEqual(hit.resourceId, subjectId, "The empty string is a value, not a miss")
        XCTAssertEqual(hit.resourceType, "user")
    }

    /// A key that is not the category's activated unique field is a
    /// configuration error (`400 NOT_UNIQUE_FIELD`), deliberately distinct from
    /// a miss, and surfaces through the namespace's usual `HttpError` mapping.
    func testResolveOnANonUniqueKeyThrowsNotUniqueField() async throws {
        _ = try await client.resourceMetadata.set(
            resourceType: "user", resourceId: subjectId,
            category: "billing",
            data: ["stripeCustomerId": "cus_SWIFT_B", "status": "active"]
        )

        do {
            _ = try await client.resourceMetadata.resolve(
                resourceType: "user",
                category: "billing",
                key: "status",
                value: "active"
            )
            XCTFail("A non-unique key must throw a config error, not report a miss")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.serverCode, "NOT_UNIQUE_FIELD")
        }
    }

    /// A category that is not defined for the resource type is a 404 on the
    /// resolve path too — a third outcome, distinct from both a miss and the
    /// non-unique-key error.
    func testResolveOnAnUndefinedCategoryThrowsHttpError404() async throws {
        do {
            _ = try await client.resourceMetadata.resolve(
                resourceType: "user",
                category: "no-such-category",
                key: "stripeCustomerId",
                value: "cus_SWIFT_A"
            )
            XCTFail("An undefined category should have thrown")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 404)
        }
    }

    // MARK: - Error surfacing on the single calls (behavior 10)

    /// A category that is not defined for the resource type is a thrown
    /// `HttpError` (404) on the single-read path — the single calls surface
    /// server errors rather than folding them into the result, which is what
    /// makes the batch's per-item entries the deliberate exception.
    func testUndefinedCategoryThrowsHttpError404() async throws {
        do {
            _ = try await client.resourceMetadata.get(
                resourceType: "user", resourceId: subjectId, category: "no-such-category"
            )
            XCTFail("An undefined category should have thrown")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 404)
        }
    }
}
