import XCTest
@testable import JsBaoClient

/// Wire-shape and decode tests for `databases.list` / `databases.listPage`
/// (issue #2245).
///
/// Two things are covered here, both about the same method:
///
/// * the `owner` creator filter — parity with the JS client's
///   `databases.list({ owner })` and the CLI's `--owner` (#1965);
/// * tolerance of the pre-#1958 bare-array response, so a published client
///   pointed at a not-yet-upgraded server still lists databases instead of
///   throwing.
///
/// `RecordingTransport` scripts the response bytes and records the request, so
/// these run without a server and still exercise the real decode path.
final class DatabasesListTests: XCTestCase {

    // MARK: - Fixtures

    private static func databaseJSON(_ id: String, createdBy: String = "u1") -> String {
        """
        {"databaseId":"\(id)","title":"DB \(id)","databaseType":"test-type",
         "permission":"owner","createdBy":"\(createdBy)",
         "createdAt":"2024-01-01T00:00:00Z","modifiedAt":"2024-01-02T00:00:00Z"}
        """
    }

    // MARK: - `owner` request parameter

    func test_listPage_owner_buildsOwnerQueryParam() async throws {
        let transport = RecordingTransport(json: #"{"items":[],"hasMore":false}"#)
        let api = DatabasesAPI(transport: transport)

        _ = try await api.listPage(owner: "user-123")

        XCTAssertEqual(transport.lastCall?.method, .get)
        XCTAssertEqual(transport.lastCall?.path, "/databases?owner=user-123")
    }

    func test_listPage_omitsOwnerWhenNotPassed() async throws {
        let transport = RecordingTransport(json: #"{"items":[],"hasMore":false}"#)
        let api = DatabasesAPI(transport: transport)

        _ = try await api.listPage()

        XCTAssertEqual(transport.lastCall?.path, "/databases")
    }

    /// The JS client builds the query as `type`, `owner`, `limit`, `cursor`
    /// (`src/client/api/databasesApi.ts`) — keep the same order so the two
    /// clients produce identical URLs.
    func test_listPage_queryParamOrderMatchesJsClient() async throws {
        let transport = RecordingTransport(json: #"{"items":[],"hasMore":false}"#)
        let api = DatabasesAPI(transport: transport)

        _ = try await api.listPage(
            databaseType: "test-type",
            owner: "user-123",
            limit: 25,
            cursor: "cur-1"
        )

        XCTAssertEqual(
            transport.lastCall?.path,
            "/databases?type=test-type&owner=user-123&limit=25&cursor=cur-1"
        )
    }

    func test_listPage_percentEncodesOwner() async throws {
        let transport = RecordingTransport(json: #"{"items":[],"hasMore":false}"#)
        let api = DatabasesAPI(transport: transport)

        _ = try await api.listPage(owner: "a&b=c d")

        XCTAssertEqual(transport.lastCall?.path, "/databases?owner=a%26b%3Dc%20d")
    }

    func test_list_forwardsOwnerAndReturnsItems() async throws {
        let transport = RecordingTransport(json: """
        {"items":[\(Self.databaseJSON("db1", createdBy: "user-123"))],"hasMore":false}
        """)
        let api = DatabasesAPI(transport: transport)

        let items = try await api.list(databaseType: "test-type", owner: "user-123")

        XCTAssertEqual(transport.lastCall?.path, "/databases?type=test-type&owner=user-123")
        XCTAssertEqual(items.map(\.databaseId), ["db1"])
        XCTAssertEqual(items.first?.createdBy, "user-123")
    }

    // MARK: - Response decoding

    func test_listPage_decodesKeyedEnvelope() async throws {
        let transport = RecordingTransport(json: """
        {"items":[\(Self.databaseJSON("db1")),\(Self.databaseJSON("db2"))],
         "hasMore":true,"nextCursor":"cur-2"}
        """)
        let api = DatabasesAPI(transport: transport)

        let page = try await api.listPage()

        XCTAssertEqual(page.items.map(\.databaseId), ["db1", "db2"])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextCursor, "cur-2")
    }

    /// A server older than #1958 answers `GET /databases` with a top-level
    /// array. Normalize it to a single page rather than throwing, matching the
    /// JS client, the CLI, and web-admin.
    func test_listPage_decodesLegacyBareArray() async throws {
        let transport = RecordingTransport(json: """
        [\(Self.databaseJSON("db1")),\(Self.databaseJSON("db2"))]
        """)
        let api = DatabasesAPI(transport: transport)

        let page = try await api.listPage()

        XCTAssertEqual(page.items.map(\.databaseId), ["db1", "db2"])
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }

    func test_list_worksAgainstLegacyBareArrayServer() async throws {
        let transport = RecordingTransport(json: "[\(Self.databaseJSON("db1"))]")
        let api = DatabasesAPI(transport: transport)

        let items = try await api.list()

        XCTAssertEqual(items.map(\.databaseId), ["db1"])
    }

    func test_listPage_decodesEmptyLegacyArray() async throws {
        let transport = RecordingTransport(json: "[]")
        let api = DatabasesAPI(transport: transport)

        let page = try await api.listPage()

        XCTAssertTrue(page.items.isEmpty)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }

    func test_listPage_decodesEnvelopeWithoutItemsKey() async throws {
        let transport = RecordingTransport(json: #"{"hasMore":false}"#)
        let api = DatabasesAPI(transport: transport)

        let page = try await api.listPage()

        XCTAssertTrue(page.items.isEmpty)
        XCTAssertFalse(page.hasMore)
    }

    /// The probe between the two shapes is shape tolerance, not
    /// malformed-body tolerance.
    func test_listPage_throwsOnBodyThatIsNeitherShape() async throws {
        let transport = RecordingTransport(json: #""not a page""#)
        let api = DatabasesAPI(transport: transport)

        do {
            _ = try await api.listPage()
            XCTFail("expected a decoding failure")
        } catch {
            // expected
        }
    }

    func test_listPage_throwsOnMalformedItems() async throws {
        let transport = RecordingTransport(json: #"{"items":5,"hasMore":false}"#)
        let api = DatabasesAPI(transport: transport)

        do {
            _ = try await api.listPage()
            XCTFail("expected a decoding failure")
        } catch {
            // expected
        }
    }

    // MARK: - `owner` on the legacy response path

    /// A server old enough to answer with a bare array also predates the
    /// `owner` filter (#1965), so it ignores `?owner=` and returns its whole
    /// list. The client applies the filter itself rather than handing back
    /// databases another user created.
    func test_listPage_filtersLegacyArrayByOwner() async throws {
        let transport = RecordingTransport(json: """
        [\(Self.databaseJSON("mine", createdBy: "user-123")),
         \(Self.databaseJSON("theirs", createdBy: "other-user"))]
        """)
        let api = DatabasesAPI(transport: transport)

        let page = try await api.listPage(owner: "user-123")

        XCTAssertEqual(page.items.map(\.databaseId), ["mine"])
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }

    func test_list_filtersLegacyArrayByOwner() async throws {
        let transport = RecordingTransport(json: """
        [\(Self.databaseJSON("mine", createdBy: "user-123")),
         \(Self.databaseJSON("theirs", createdBy: "other-user"))]
        """)
        let api = DatabasesAPI(transport: transport)

        let items = try await api.list(owner: "user-123")

        XCTAssertEqual(items.map(\.databaseId), ["mine"])
    }

    /// An owner that created nothing on a legacy server is an empty list, not
    /// an error — the same shape the current server returns.
    func test_listPage_legacyArrayOwnerWithNoDatabasesIsEmpty() async throws {
        let transport = RecordingTransport(json: """
        [\(Self.databaseJSON("theirs", createdBy: "other-user"))]
        """)
        let api = DatabasesAPI(transport: transport)

        let page = try await api.listPage(owner: "user-123")

        XCTAssertTrue(page.items.isEmpty)
        XCTAssertFalse(page.hasMore)
    }

    /// Without `owner` the legacy array is passed through untouched.
    func test_listPage_doesNotFilterLegacyArrayWhenOwnerOmitted() async throws {
        let transport = RecordingTransport(json: """
        [\(Self.databaseJSON("mine", createdBy: "user-123")),
         \(Self.databaseJSON("theirs", createdBy: "other-user"))]
        """)
        let api = DatabasesAPI(transport: transport)

        let page = try await api.listPage()

        XCTAssertEqual(page.items.map(\.databaseId), ["mine", "theirs"])
    }

    /// An empty `owner` means "no filter" — the same as the JS client's
    /// `if (options?.owner)` guard, the CLI's, and the server's own handling of
    /// `?owner=`. Filtering on `createdBy == ""` would instead come back empty.
    func test_listPage_doesNotFilterLegacyArrayWhenOwnerIsEmpty() async throws {
        let transport = RecordingTransport(json: """
        [\(Self.databaseJSON("mine", createdBy: "user-123")),
         \(Self.databaseJSON("theirs", createdBy: "other-user"))]
        """)
        let api = DatabasesAPI(transport: transport)

        let page = try await api.listPage(owner: "")

        XCTAssertEqual(page.items.map(\.databaseId), ["mine", "theirs"])
    }

    /// A server that answers with the keyed envelope has already applied the
    /// filter server-side, so the client must not re-filter — doing so would
    /// drop rows the server deliberately included and would break `hasMore` /
    /// `nextCursor` paging.
    func test_listPage_doesNotFilterKeyedEnvelope() async throws {
        let transport = RecordingTransport(json: """
        {"items":[\(Self.databaseJSON("a", createdBy: "user-123")),
                  \(Self.databaseJSON("b", createdBy: "other-user"))],
         "hasMore":true,"nextCursor":"cur-2"}
        """)
        let api = DatabasesAPI(transport: transport)

        let page = try await api.listPage(owner: "user-123")

        XCTAssertEqual(page.items.map(\.databaseId), ["a", "b"])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextCursor, "cur-2")
    }
}
