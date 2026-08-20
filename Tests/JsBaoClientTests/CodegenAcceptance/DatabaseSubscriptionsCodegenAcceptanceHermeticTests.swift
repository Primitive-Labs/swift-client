import Foundation
import XCTest
@testable import JsBaoClient

/// Acceptance tests for the CLI-generated Swift typed-subscriptions surface
/// (issue #2805).
///
/// `GeneratedDatabases/portfolio.generated.swift` is emitted by
/// `primitive databases codegen --lang swift` from
/// `cli/tests/fixtures/swift-db-acceptance/database-type-configs/portfolio.toml`,
/// which registers two subscriptions — one full-record (`allAccounts`) and one
/// projected (`open-accounts`). Committing the output here is what makes
/// `swift build` / `swift test` prove the emitted factory and row types compile
/// against the real SDK; these cases prove they also decode real frames.
///
/// Server-free (`*HermeticTests`): payloads are synthesized and converted, no
/// socket and no transport.
final class DatabaseSubscriptionsCodegenAcceptanceHermeticTests: XCTestCase {

    // MARK: - Row types

    func test_projectedRow_carriesOnlyTheSelectedFields() throws {
        // `open-accounts` selects `accountNumber` + `status`, so the row decodes
        // those and ignores the rest of the record's columns.
        let json = #"""
        {"accountNumber":"0009","status":"pending-review","institution":"Bank"}
        """#.data(using: .utf8)!
        let row = try JSONDecoder().decode(Portfolio.OpenAccountsRow.self, from: json)
        XCTAssertEqual(row.accountNumber, "0009")
        // The projection reuses the record's nested enum, so the raw value maps
        // to the same sanitized case.
        XCTAssertEqual(row.status, .pending_review)
    }

    func test_row_decodesADeltaFrameWithEveryOtherFieldNil() throws {
        // A `patch` frame carries only the changed field. The record types
        // `id`/`accountNumber` non-optional; the ROW must not.
        let json = #"{"balance":42.5}"#.data(using: .utf8)!
        let row = try JSONDecoder().decode(Portfolio.AllAccountsRow.self, from: json)
        XCTAssertEqual(row.balance, 42.5)
        XCTAssertNil(row.id)
        XCTAssertNil(row.accountNumber)
        XCTAssertNil(row.status)
        XCTAssertNil(row.createdAt)
    }

    // MARK: - Typed payload binding

    func test_typedPayload_bindsTheGeneratedRow() throws {
        let untyped = DatabaseChangePayload(
            databaseId: "db_1",
            subscriptionKey: "open-accounts",
            changes: [
                DatabaseChangeEvent(
                    changeType: "update",
                    op: "patch",
                    modelName: "accounts",
                    id: "acc_1",
                    data: ["accountNumber": "0002"],
                    previousData: ["accountNumber": "0001", "status": "active"]
                )
            ],
            timestamp: "2026-08-19T00:00:00.000Z",
            originUserId: "u_1"
        )

        let typed = TypedDatabaseChangePayload<Portfolio.OpenAccountsRow>(decoding: untyped)
        let change = try XCTUnwrap(typed.changes.first)
        XCTAssertEqual(change.data?.accountNumber, "0002")
        XCTAssertNil(change.data?.status, "the delta carried no status")
        XCTAssertEqual(change.previousData?.status, .active)
        XCTAssertEqual(typed.subscriptionKey, "open-accounts")
        XCTAssertEqual(typed.originUserId, "u_1")
    }
}

/// Compile-only proof (#2805) that the committed `<Type>.Subscriptions` factory
/// binds each subscription's row type over the SDK's typed
/// `DatabasesAPI.subscribe` overload, and that a change's `data` is the row —
/// not `Any`. Never executed; being COMPILED is the assertion.
@available(*, unavailable)
private func _dbAcceptanceSubscriptionBindingsCompile(_ client: JsBaoClient) throws {
    let subs = Portfolio.subscriptions(client, databaseId: "db_1")

    let projected = try subs.openAccounts(
        options: DatabaseSubscribeOptions(params: ["ownerId": .string("u_1")])
    ) { payload in
        for change in payload.changes {
            let number: String? = change.data?.accountNumber
            _ = number
            let status: Portfolio.Account.StatusValue? = change.previousData?.status
            _ = status
            // The untyped event stays reachable for whatever the row cannot say.
            _ = change.raw.op
        }
        _ = payload.isOriginUser
    }
    projected.cancel()

    let all = try subs.allAccounts { payload in
        let balance: Double? = payload.changes.first?.data?.balance
        _ = balance
        let tags: [String]? = payload.changes.first?.data?.tags
        _ = tags
    }
    all.cancel()
}
