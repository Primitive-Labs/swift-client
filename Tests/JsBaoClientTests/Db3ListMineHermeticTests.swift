import XCTest
@testable import JsBaoClient

/// #5021 behaviors 9, 10 and 24 and edge cases E3 and E4 — Swift's
/// `client.db3.listMine` is the JS one.
///
/// `listMine(_:)` reads the db3s the user holds, those shared with them and
/// those granted to the app, in that order, one request per page, and names
/// each row's listing as `via`. Its cursor is its own; one it did not issue is
/// refused before any request. The pinned `listMine(options:)` keeps its
/// held-only answer for a server cursor and continues a cursor the full form
/// issued, so the published loop pages through all three listings.
final class Db3ListMineHermeticTests: XCTestCase {

    private static func row(_ id: String, permission: String?, extra: String = "") -> String {
        let level = permission.map { "\"\($0)\"" } ?? "null"
        return """
        {"id": "\(id)", "title": "\(id)", "createdBy": "u-1", "createdAt": "c", "modifiedAt": "m", "custodian": "user:u-1",
         "sync": true, "type": null, "permission": \(level)\(extra)}
        """
    }

    /// The three listings, `/me/db3` in two pages, answered by path (with or without `limit`).
    private static let pages: [String: String] = [
        "/me/db3": #"{"items": [\#(row("h1", permission: "owner"))], "hasMore": true, "nextCursor": "held-2"}"#,
        "/me/db3?cursor=held-2": #"{"items": [\#(row("h2", permission: nil))], "hasMore": false}"#,
        "/me/shared-db3": #"{"items": [\#(row("s1", permission: "reader", extra: #", "grantedAt": "g", "grantedBy": "u-2""#))], "hasMore": false}"#,
        "/me/app-db3": #"{"items": [\#(row("p1", permission: "read-write", extra: #", "grantedAt": "g2""#))], "hasMore": false}"#,
    ]

    /// A `Db3API` over a transport that answers each listing page by path, ignoring `limit`.
    private func api() -> (Db3API, RecordingTransport) {
        let transport = RecordingTransport(responder: { call in
            let key = call.path
                .replacingOccurrences(of: "?limit=2&", with: "?")
                .replacingOccurrences(of: "?limit=2", with: "")
            let json = Self.pages[key] ?? #"{"error": "unexpected \#(call.path)"}"#
            return TransportResponse(status: Self.pages[key] == nil ? 500 : 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
        })
        return (Db3API(lifecycle: Db3Lifecycle(deps: Db3LifecycleDeps()), transport: transport), transport)
    }

    private func refusal(_ body: () async throws -> Void) async -> JsBaoErrorCode? {
        do {
            try await body()
            return nil
        } catch {
            return (error as? JsBaoError)?.code
        }
    }

    // MARK: - Behavior 9 and E4

    func testTheFullFormReadsTheThreeListingsInOrderAndNamesEachRowsListing() async throws {
        let (db3, transport) = api()
        var page = try await db3.listMine(Db3ListMineOptions(limit: 2))
        var rows: [Db3Info] = page.items
        while page.hasMore {
            page = try await db3.listMine(Db3ListMineOptions(limit: 2, cursor: page.nextCursor))
            rows += page.items
        }
        XCTAssertEqual(transport.calls.map(\.path), [
            "/me/db3?limit=2", "/me/db3?limit=2&cursor=held-2", "/me/shared-db3?limit=2", "/me/app-db3?limit=2",
        ])
        XCTAssertEqual(rows.map(\.id), ["h1", "h2", "s1", "p1"])
        XCTAssertEqual(rows.map(\.via), [.held, .held, .shared, .app])
        XCTAssertEqual(rows.map(\.permission), [.owner, nil, .reader, .readWrite])
        XCTAssertEqual(rows.map(\.grantedBy), [nil, nil, "u-2", nil])
        XCTAssertEqual(rows.map(\.grantedAt), [nil, nil, "g", "g2"])
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }

    func testTheBareCallIsTheFullForm() async throws {
        let (db3, transport) = api()
        let page = try await db3.listMine()
        XCTAssertEqual(transport.calls.map(\.path), ["/me/db3"])
        XCTAssertEqual(page.items.map(\.via), [.held])
        XCTAssertTrue(page.hasMore)
        let next = try await db3.listMine(Db3ListMineOptions(cursor: page.nextCursor))
        XCTAssertEqual(transport.lastCall?.path, "/me/db3?cursor=held-2")
        XCTAssertEqual(next.items.map(\.id), ["h2"])
        XCTAssertTrue(next.hasMore, "the shared listing is next")
    }

    /// E4: a db3 any other route answers names no listing and no granter.
    func testADb3FromAnotherRouteHasNoViaAndNoGrantedBy() throws {
        let info = try JSONCoding.decodeData(Db3Info.self, from: Data(Self.row("x", permission: "owner").utf8))
        XCTAssertNil(info.via)
        XCTAssertNil(info.grantedBy)
        XCTAssertEqual(info, Db3Info(
            id: "x", title: "x", createdBy: "u-1", createdAt: "c", modifiedAt: "m", custodian: "user:u-1", sync: true, type: nil,
            tags: [], metadata: nil, permission: .owner, accessSource: nil, grantedAt: nil
        ))
    }

    // MARK: - Behavior 10 and E3

    func testViaReadsOnlyTheNamedListingsInTheListingOrder() async throws {
        let (shared, sharedTransport) = api()
        let only = try await shared.listMine(Db3ListMineOptions(via: [.shared]))
        XCTAssertEqual(sharedTransport.calls.map(\.path), ["/me/shared-db3"])
        XCTAssertEqual(only.items.map(\.via), [.shared])
        XCTAssertFalse(only.hasMore)

        // E3: the listing order, not the argument order.
        let (both, bothTransport) = api()
        var page = try await both.listMine(Db3ListMineOptions(via: [.app, .held]))
        while page.hasMore {
            page = try await both.listMine(Db3ListMineOptions(via: [.app, .held], cursor: page.nextCursor))
        }
        XCTAssertEqual(bothTransport.calls.map(\.path), ["/me/db3", "/me/db3?cursor=held-2", "/me/app-db3"])

        let (none, noneTransport) = api()
        let empty = try await none.listMine(Db3ListMineOptions(via: []))
        XCTAssertEqual(empty.items, [])
        XCTAssertFalse(empty.hasMore)
        XCTAssertNil(empty.nextCursor)
        XCTAssertTrue(noneTransport.calls.isEmpty)
    }

    func testACursorTheCallDidNotIssueIsRefusedBeforeAnyRequest() async throws {
        let (db3, transport) = api()
        for cursor in ["nonsense", #"{"via":"held","other":1}"#, #"{"via":"elsewhere"}"#, #"{"via":"held","cursor":2}"#] {
            let code = await refusal { _ = try await db3.listMine(Db3ListMineOptions(cursor: cursor)) }
            XCTAssertEqual(code, .invalidArgument, cursor)
        }
        let notInVia = await refusal { _ = try await db3.listMine(Db3ListMineOptions(via: [.held], cursor: #"{"via":"app"}"#)) }
        XCTAssertEqual(notInVia, .invalidArgument)
        XCTAssertTrue(transport.calls.isEmpty)
    }

    // MARK: - Behavior 24

    func testThePublishedLoopPagesThroughAllThreeListings() async throws {
        let (db3, transport) = api()
        var page = try await db3.listMine()
        var rows = page.items
        while page.hasMore {
            page = try await db3.listMine(options: PaginationOptions(cursor: page.nextCursor))
            rows += page.items
        }
        XCTAssertEqual(transport.calls.map(\.path), ["/me/db3", "/me/db3?cursor=held-2", "/me/shared-db3", "/me/app-db3"])
        XCTAssertEqual(rows.map(\.via), [.held, .held, .shared, .app])
        XCTAssertFalse(page.hasMore)
    }

    func testTheOldFormKeepsAServerCursorAndCarriesItsOwnLimit() async throws {
        let (db3, transport) = api()
        let raw = try await db3.listMine(options: PaginationOptions(cursor: "held-2"))
        XCTAssertEqual(transport.lastCall?.path, "/me/db3?cursor=held-2")
        XCTAssertEqual(raw.items.map(\.via), [nil], "the old form answers the server's rows as they are")
        XCTAssertFalse(raw.hasMore)

        let (looped, loopedTransport) = api()
        let first = try await looped.listMine(Db3ListMineOptions(limit: 2))
        let second = try await looped.listMine(options: PaginationOptions(limit: 2, cursor: first.nextCursor))
        _ = try await looped.listMine(options: PaginationOptions(cursor: second.nextCursor))
        XCTAssertEqual(loopedTransport.calls.map(\.path), ["/me/db3?limit=2", "/me/db3?limit=2&cursor=held-2", "/me/shared-db3"])
    }
}
