// AUTO-GENERATED FROM database-type-configs/edge.toml — DO NOT EDIT.
// Run `primitive databases codegen --lang swift` to regenerate.
// fingerprint: aa77e65e0ce86595

import Foundation
import JsBaoClient

public enum Edge {
    public struct RawItem: Codable, Equatable, Sendable {
        public var id: String
        public var displayName: String?

        public init(
            id: String,
            displayName: String? = nil
        ) {
            self.id = id
            self.displayName = displayName
        }

        public enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display-name"
        }
    }

    public struct DefaultParams: Codable, Equatable, Sendable {
        public init() {}
    }

    public typealias DefaultResult = DBQueryResult<RawItem>

    public struct DeleteParams: Codable, Equatable, Sendable {
        public var recordId: String

        public init(
            recordId: String
        ) {
            self.recordId = recordId
        }

        public enum CodingKeys: String, CodingKey {
            case recordId = "record-id"
        }
    }

    public typealias DeleteResult = DBMutationResult

    /// Typed accessor for `edge` operations. Obtain one with
    /// `Edge.ops(client, databaseId:)`.
    public struct Ops: Sendable {
        public let client: JsBaoClient
        public let databaseId: String

        public init(client: JsBaoClient, databaseId: String) {
            self.client = client
            self.databaseId = databaseId
        }

        /// Execute the `default` operation.
        public func `default`(
            limit: Int? = nil,
            cursor: String? = nil,
            direction: SortDirection? = nil,
            timing: Bool? = nil
        ) async throws -> DefaultResult {
            try await client.databases.executeOperation(
                databaseId: databaseId,
                name: "default",
                params: DefaultParams(),
                limit: limit,
                cursor: cursor,
                direction: direction,
                timing: timing
            )
        }

        /// Execute the `delete` operation.
        public func delete(
            _ params: DeleteParams,
            limit: Int? = nil,
            cursor: String? = nil,
            direction: SortDirection? = nil,
            timing: Bool? = nil
        ) async throws -> DeleteResult {
            try await client.databases.executeOperation(
                databaseId: databaseId,
                name: "delete",
                params: params,
                limit: limit,
                cursor: cursor,
                direction: direction,
                timing: timing
            )
        }
    }

    /// Typed operations factory for the `edge` database type.
    public static func ops(_ client: JsBaoClient, databaseId: String) -> Ops {
        Ops(client: client, databaseId: databaseId)
    }
}
