// AUTO-GENERATED FROM database-types/portfolio.toml — DO NOT EDIT.
// Run `primitive databases codegen --lang swift` to regenerate.
// fingerprint: bdbbc05abe79fda8

import Foundation
import JsBaoClient

public enum Portfolio {
    public struct Account: Codable, Equatable, Sendable {
        public enum StatusValue: String, Codable, CaseIterable, Sendable {
            case active = "active"
            case closed = "closed"
            case pending_review = "pending-review"
        }

        public var id: String
        public var accountNumber: String
        public var institution: String?
        public var balance: Double?
        public var status: StatusValue?
        public var tags: [String]?
        public var createdAt: String?
        public var modifiedAt: String?
        public var ownerId: String?

        public init(
            id: String,
            accountNumber: String,
            institution: String? = nil,
            balance: Double? = nil,
            status: StatusValue? = nil,
            tags: [String]? = nil,
            createdAt: String? = nil,
            modifiedAt: String? = nil,
            ownerId: String? = nil
        ) {
            self.id = id
            self.accountNumber = accountNumber
            self.institution = institution
            self.balance = balance
            self.status = status
            self.tags = tags
            self.createdAt = createdAt
            self.modifiedAt = modifiedAt
            self.ownerId = ownerId
        }
    }

    public struct CountAccountsParams: Codable, Equatable, Sendable {
        public init() {}
    }

    public typealias CountAccountsResult = DBCountResult

    public struct ListAccountsParams: Codable, Equatable, Sendable {
        public init() {}
    }

    public typealias ListAccountsResult = DBQueryResult<Account>

    public struct SaveAccountParams: Codable, Equatable, Sendable {
        public var accountNumber: String
        public var metadata: [String: JSONValue]?

        public init(
            accountNumber: String,
            metadata: [String: JSONValue]? = nil
        ) {
            self.accountNumber = accountNumber
            self.metadata = metadata
        }
    }

    public typealias SaveAccountResult = DBMutationResult

    /// Typed accessor for `portfolio` operations. Obtain one with
    /// `Portfolio.ops(client, databaseId:)`.
    public struct Ops: Sendable {
        public let client: JsBaoClient
        public let databaseId: String

        public init(client: JsBaoClient, databaseId: String) {
            self.client = client
            self.databaseId = databaseId
        }

        /// Execute the `countAccounts` operation.
        public func countAccounts(
            limit: Int? = nil,
            cursor: String? = nil,
            direction: SortDirection? = nil,
            timing: Bool? = nil
        ) async throws -> CountAccountsResult {
            try await client.databases.executeOperation(
                databaseId: databaseId,
                name: "countAccounts",
                params: CountAccountsParams(),
                limit: limit,
                cursor: cursor,
                direction: direction,
                timing: timing
            )
        }

        /// Execute the `listAccounts` operation.
        public func listAccounts(
            limit: Int? = nil,
            cursor: String? = nil,
            direction: SortDirection? = nil,
            timing: Bool? = nil
        ) async throws -> ListAccountsResult {
            try await client.databases.executeOperation(
                databaseId: databaseId,
                name: "listAccounts",
                params: ListAccountsParams(),
                limit: limit,
                cursor: cursor,
                direction: direction,
                timing: timing
            )
        }

        /// Execute the `saveAccount` operation.
        public func saveAccount(
            _ params: SaveAccountParams,
            limit: Int? = nil,
            cursor: String? = nil,
            direction: SortDirection? = nil,
            timing: Bool? = nil
        ) async throws -> SaveAccountResult {
            try await client.databases.executeOperation(
                databaseId: databaseId,
                name: "saveAccount",
                params: params,
                limit: limit,
                cursor: cursor,
                direction: direction,
                timing: timing
            )
        }
    }

    /// Typed operations factory for the `portfolio` database type.
    public static func ops(_ client: JsBaoClient, databaseId: String) -> Ops {
        Ops(client: client, databaseId: databaseId)
    }
}
