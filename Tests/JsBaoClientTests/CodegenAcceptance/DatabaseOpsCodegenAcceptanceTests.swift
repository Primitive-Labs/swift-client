import XCTest
@testable import JsBaoClient

/// Acceptance tests for the CLI-generated Swift database-ops codegen (issue
/// #1547, Phase 4, behavior 16).
///
/// The committed `.generated.swift` files under `GeneratedDatabases/` are the
/// acceptance set: they are emitted by `primitive databases codegen --lang
/// swift` from the fixture TOMLs in
/// `cli/tests/fixtures/swift-db-acceptance/database-type-configs/` and committed here
/// so `swift build` and the full `swift test` validate that the generated Swift
/// compiles against the real library and round-trips.
///
/// Every generated symbol is nested under a `public enum <Type>` namespace
/// (issue #1687), so record/params/result types are referenced qualified
/// (`Portfolio.Account`, `Catalog.SearchProductsParams`).
///
/// This file covers:
///   - record + params structs encode → JSON → decode → equal, and a
///     server-shaped JSON fixture decodes into the generated record;
///   - each op's `<Type>.<Op>Result` typealias resolves to the right SDK result
///     envelope, decoded from a server-shaped payload.
///
/// The generated `<Type>.Ops` factory and the generic `executeOperation`
/// overload it called retired with the client's operation execute door
/// (#3188); the files carry the record, params and result types only.
final class DatabaseOpsCodegenAcceptanceTests: XCTestCase {

    // MARK: - Record + params round-trip

    func test_record_encodeDecodeRoundTrips() throws {
        let account = Portfolio.Account(
            id: "acc_1",
            accountNumber: "0001",
            institution: "Bank",
            balance: 12.5,
            status: .active,
            tags: ["a", "b"]
        )
        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(Portfolio.Account.self, from: data)
        XCTAssertEqual(decoded, account)
    }

    func test_record_serverShapedJSON_decodes() throws {
        // A server row: enum raw value + stamped fields present, some fields absent.
        let json = #"""
        {"id":"acc_9","accountNumber":"0009","status":"pending-review","createdAt":"2026-01-01","ownerId":"u_1"}
        """#.data(using: .utf8)!
        let acc = try JSONDecoder().decode(Portfolio.Account.self, from: json)
        XCTAssertEqual(acc.id, "acc_9")
        // The `pending-review` raw value sanitizes to the case `pending_review`.
        XCTAssertEqual(acc.status, .pending_review)
        XCTAssertEqual(acc.createdAt, "2026-01-01")
        XCTAssertNil(acc.institution)
    }

    func test_params_codingKeys_preserveWireKeys() throws {
        // `record-id` → `recordId` with a CodingKeys wire mapping.
        let params = Edge.DeleteParams(recordId: "r_1")
        let obj = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(params)
        ) as? [String: Any]
        XCTAssertEqual(obj?["record-id"] as? String, "r_1")
        XCTAssertNil(obj?["recordId"], "must encode under the wire key only")
    }

    func test_params_arrayAndEnum() throws {
        let params = Catalog.SearchProductsParams(ids: ["x", "y"], kind: .digital)
        let decoded = try JSONDecoder().decode(
            Catalog.SearchProductsParams.self,
            from: try JSONEncoder().encode(params)
        )
        XCTAssertEqual(decoded, params)
    }

    // MARK: - Result envelopes decode

    func test_queryResult_decodesRows() throws {
        let json = #"""
        {"data":[{"id":"a1","accountNumber":"1"},{"id":"a2","accountNumber":"2"}],"hasMore":true,"nextCursor":"c"}
        """#.data(using: .utf8)!
        let result = try JSONDecoder().decode(Portfolio.ListAccountsResult.self, from: json)
        XCTAssertEqual(result.data.count, 2)
        XCTAssertEqual(result.data[0].accountNumber, "1")
        XCTAssertEqual(result.hasMore, true)
        XCTAssertEqual(result.nextCursor, "c")
    }

    func test_mutationResult_decodes() throws {
        let json = #"{"results":[{"op":"save","success":true,"id":"acc_1"}]}"#.data(using: .utf8)!
        let result = try JSONDecoder().decode(Portfolio.SaveAccountResult.self, from: json)
        XCTAssertEqual(result.results.count, 1)
        XCTAssertEqual(result.results[0].op, "save")
        XCTAssertEqual(result.results[0].id, "acc_1")
    }

    func test_countResult_decodes() throws {
        let json = #"{"count":42}"#.data(using: .utf8)!
        let result = try JSONDecoder().decode(Portfolio.CountAccountsResult.self, from: json)
        XCTAssertEqual(result.count, 42)
    }

    func test_narrowedQuery_isOpenRows() throws {
        // searchProducts has a `pick` projection → open JSONValue rows (Swift has
        // no Pick/Partial analog).
        let json = #"{"data":[{"title":"T"}]}"#.data(using: .utf8)!
        let result = try JSONDecoder().decode(Catalog.SearchProductsResult.self, from: json)
        XCTAssertEqual(result.data.count, 1)
        XCTAssertEqual(result.data[0], .object(["title": .string("T")]))
    }
}
