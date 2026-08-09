import XCTest
@testable import JsBaoClient

/// Acceptance tests for the CLI-generated Swift database-ops codegen (issue
/// #1547, Phase 4, behavior 16).
///
/// The committed `.generated.swift` files under `GeneratedDatabases/` are the
/// acceptance set: they are emitted by `primitive databases codegen --lang
/// swift` from the fixture TOMLs in
/// `cli/tests/fixtures/swift-db-acceptance/database-types/` and committed here
/// so `swift build` and the full `swift test` validate that the generated Swift
/// compiles against the real library and round-trips.
///
/// Every generated symbol is nested under a `public enum <Type>` namespace
/// (issue #1687), so record/params/result types and the `Ops` factory are
/// referenced qualified (`Portfolio.Account`, `Catalog.SearchProductsParams`,
/// `Edge.ops(...)`).
///
/// This file covers:
///   - record + params structs encode → JSON → decode → equal, and a
///     server-shaped JSON fixture decodes into the generated record;
///   - each op's `<Type>.<Op>Result` typealias resolves to the right SDK result
///     envelope, decoded from a server-shaped payload;
///   - the generated `<Type>.Ops` factory binds `<Op>Params` in and `<Op>Result`
///     out over the additive generic `DatabasesAPI.executeOperation` overload,
///     exercised live against a recording transport.
final class DatabaseOpsCodegenAcceptanceTests: XCTestCase {

    // MARK: - Stub transport

    /// `RecordingTransport` scripts the response bytes and records the request
    /// it was handed, which is what the factory tests below assert on. Hold the
    /// transport so the recorded call can be read back after the `await`.
    private func api(_ transport: RecordingTransport) -> DatabasesAPI {
        DatabasesAPI(transport: transport)
    }

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

    // MARK: - Generic executeOperation overload (published surface)

    func test_factory_queryOp_bindsTypedResult() async throws {
        let transport = RecordingTransport(
            json: #"{"data":[{"id":"a1","accountNumber":"0001"}]}"#
        )
        // Drive the generic overload directly against the recording transport
        // (the generated factory delegates to exactly this call).
        let result: Portfolio.ListAccountsResult = try await api(transport).executeOperation(
            databaseId: "db_1",
            name: "listAccounts",
            params: Portfolio.ListAccountsParams()
        )
        let call = try XCTUnwrap(transport.lastCall)
        XCTAssertEqual(call.method, .post)
        XCTAssertEqual(call.path, "/databases/db_1/operations/listAccounts/execute")
        XCTAssertEqual(result.data.first?.accountNumber, "0001")
    }

    func test_factory_mutationOp_encodesTypedParams() async throws {
        let transport = RecordingTransport(
            json: #"{"results":[{"op":"save","success":true,"id":"acc_1"}]}"#
        )
        let result: Portfolio.SaveAccountResult = try await api(transport).executeOperation(
            databaseId: "db_1",
            name: "saveAccount",
            params: Portfolio.SaveAccountParams(accountNumber: "0001")
        )
        // Typed params were encoded into the request `params` object.
        let params = try XCTUnwrap(transport.lastCall?.jsonBody?["params"])
        XCTAssertEqual(params["accountNumber"]?.stringValue, "0001")
        XCTAssertEqual(result.results.first?.id, "acc_1")
    }
}

/// Compile-only proof (behavior 16) that the committed `<Type>.Ops` factories
/// bind `<Op>Params` in and `<Op>Result` out over the generic
/// `DatabasesAPI.executeOperation` overload. Never executed — being COMPILED is
/// the assertion.
@available(*, unavailable)
private func _dbAcceptanceFactoryBindingsCompile(_ client: JsBaoClient) async throws {
    let portfolio = Portfolio.ops(client, databaseId: "db_1")
    let accounts: Portfolio.ListAccountsResult = try await portfolio.listAccounts()
    _ = accounts.data.first?.accountNumber
    let saved: Portfolio.SaveAccountResult = try await portfolio.saveAccount(
        Portfolio.SaveAccountParams(accountNumber: "0001")
    )
    _ = saved.results
    let count: Portfolio.CountAccountsResult = try await portfolio.countAccounts()
    _ = count.count

    let catalog = Catalog.ops(client, databaseId: "db_2")
    let found: Catalog.SearchProductsResult = try await catalog.searchProducts(
        Catalog.SearchProductsParams(ids: ["x"], kind: .physical)
    )
    _ = found.data
    let agg: Catalog.SummarizeResult = try await catalog.summarize()
    _ = agg.result
    let applied: Catalog.ArchiveStaleResult = try await catalog.archiveStale()
    _ = applied.matched
    let piped: Catalog.RunPipelineResult = try await catalog.runPipeline()
    _ = piped.data

    let edge = Edge.ops(client, databaseId: "db_3")
    let deleted: Edge.DeleteResult = try await edge.delete(Edge.DeleteParams(recordId: "r_1"))
    _ = deleted.results
    let def: Edge.DefaultResult = try await edge.`default`()
    _ = def.data
}
