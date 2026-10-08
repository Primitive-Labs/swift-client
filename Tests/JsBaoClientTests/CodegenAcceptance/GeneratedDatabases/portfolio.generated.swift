// AUTO-GENERATED FROM database-type-configs/portfolio.toml — DO NOT EDIT.
// Run `primitive databases codegen --lang swift` to regenerate.
// fingerprint: 4cf76331414bfdaf

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

    /// Change rows delivered by the `allAccounts` subscription (model `Account`).
    ///
    /// Every field is optional even where the record requires it: a change
    /// frame carries only the fields the write touched, narrowed further by
    /// the subscription's `select`. Typing one non-optional would claim a
    /// value the frame need not carry — the JS factory's #1772 soundness bug,
    /// which this emitter does not reproduce.
    public struct AllAccountsRow: Codable, Equatable, Sendable {
        public var id: String?
        public var accountNumber: String?
        public var institution: String?
        public var balance: Double?
        public var status: Account.StatusValue?
        public var tags: [String]?
        public var createdAt: String?
        public var modifiedAt: String?
        public var ownerId: String?

        public init(
            id: String? = nil,
            accountNumber: String? = nil,
            institution: String? = nil,
            balance: Double? = nil,
            status: Account.StatusValue? = nil,
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

    /// Change rows delivered by the `open-accounts` subscription (model `Account`, `select` projection).
    ///
    /// Every field is optional even where the record requires it: a change
    /// frame carries only the fields the write touched, narrowed further by
    /// the subscription's `select`. Typing one non-optional would claim a
    /// value the frame need not carry — the JS factory's #1772 soundness bug,
    /// which this emitter does not reproduce.
    public struct OpenAccountsRow: Codable, Equatable, Sendable {
        public var accountNumber: String?
        public var status: Account.StatusValue?

        public init(
            accountNumber: String? = nil,
            status: Account.StatusValue? = nil
        ) {
            self.accountNumber = accountNumber
            self.status = status
        }
    }

    /// Typed accessor for `portfolio` realtime subscriptions. Obtain one
    /// with `Portfolio.subscriptions(client, databaseId:)`.
    public struct Subscriptions: Sendable {
        public let client: JsBaoClient
        public let databaseId: String

        public init(client: JsBaoClient, databaseId: String) {
            self.client = client
            self.databaseId = databaseId
        }

        /// Subscribe to the `allAccounts` subscription.
        ///
        /// Hold the returned handle for as long as you want changes — it
        /// unsubscribes when released.
        public func allAccounts(
            options: DatabaseSubscribeOptions = DatabaseSubscribeOptions(),
            onChange: @escaping @Sendable (TypedDatabaseChangePayload<AllAccountsRow>) -> Void
        ) throws -> EventSubscription {
            try client.databases.subscribe(
                databaseId: databaseId,
                subscriptionKey: "allAccounts",
                rowType: AllAccountsRow.self,
                options: options,
                onChange: onChange
            )
        }

        /// Subscribe to the `open-accounts` subscription.
        ///
        /// Hold the returned handle for as long as you want changes — it
        /// unsubscribes when released.
        public func openAccounts(
            options: DatabaseSubscribeOptions = DatabaseSubscribeOptions(),
            onChange: @escaping @Sendable (TypedDatabaseChangePayload<OpenAccountsRow>) -> Void
        ) throws -> EventSubscription {
            try client.databases.subscribe(
                databaseId: databaseId,
                subscriptionKey: "open-accounts",
                rowType: OpenAccountsRow.self,
                options: options,
                onChange: onChange
            )
        }
    }

    /// Typed subscriptions factory for the `portfolio` database type.
    public static func subscriptions(_ client: JsBaoClient, databaseId: String) -> Subscriptions {
        Subscriptions(client: client, databaseId: databaseId)
    }
}
