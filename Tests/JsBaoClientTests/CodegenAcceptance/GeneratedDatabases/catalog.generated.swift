// AUTO-GENERATED FROM database-type-configs/catalog.toml — DO NOT EDIT.
// Run `primitive databases codegen --lang swift` to regenerate.
// fingerprint: 20ef8fc2fcd755ac

import Foundation
import JsBaoClient

public enum Catalog {
    public struct Product: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var price: Double?

        public init(
            id: String,
            title: String,
            price: Double? = nil
        ) {
            self.id = id
            self.title = title
            self.price = price
        }
    }

    public struct ArchiveStaleParams: Codable, Equatable, Sendable {
        public init() {}
    }

    public typealias ArchiveStaleResult = DBApplyToQueryResult

    public struct RunPipelineParams: Codable, Equatable, Sendable {
        public init() {}
    }

    public typealias RunPipelineResult = DBQueryResult<Product>

    public struct SearchProductsParams: Codable, Equatable, Sendable {
        public enum KindValue: String, Codable, CaseIterable, Sendable {
            case digital = "digital"
            case physical = "physical"
        }

        public var ids: [String]?
        public var kind: KindValue?

        public init(
            ids: [String]? = nil,
            kind: KindValue? = nil
        ) {
            self.ids = ids
            self.kind = kind
        }
    }

    public typealias SearchProductsResult = DBQueryResult<JSONValue>

    public struct SummarizeParams: Codable, Equatable, Sendable {
        public init() {}
    }

    public typealias SummarizeResult = DBAggregateResult

    /// Typed accessor for `catalog` operations. Obtain one with
    /// `Catalog.ops(client, databaseId:)`.
    public struct Ops: Sendable {
        public let client: JsBaoClient
        public let databaseId: String

        public init(client: JsBaoClient, databaseId: String) {
            self.client = client
            self.databaseId = databaseId
        }

        /// Execute the `archiveStale` operation.
        public func archiveStale(
            limit: Int? = nil,
            cursor: String? = nil,
            direction: SortDirection? = nil,
            timing: Bool? = nil
        ) async throws -> ArchiveStaleResult {
            try await client.databases.executeOperation(
                databaseId: databaseId,
                name: "archiveStale",
                params: ArchiveStaleParams(),
                limit: limit,
                cursor: cursor,
                direction: direction,
                timing: timing
            )
        }

        /// Execute the `runPipeline` operation.
        public func runPipeline(
            limit: Int? = nil,
            cursor: String? = nil,
            direction: SortDirection? = nil,
            timing: Bool? = nil
        ) async throws -> RunPipelineResult {
            try await client.databases.executeOperation(
                databaseId: databaseId,
                name: "runPipeline",
                params: RunPipelineParams(),
                limit: limit,
                cursor: cursor,
                direction: direction,
                timing: timing
            )
        }

        /// Execute the `searchProducts` operation.
        public func searchProducts(
            _ params: SearchProductsParams,
            limit: Int? = nil,
            cursor: String? = nil,
            direction: SortDirection? = nil,
            timing: Bool? = nil
        ) async throws -> SearchProductsResult {
            try await client.databases.executeOperation(
                databaseId: databaseId,
                name: "searchProducts",
                params: params,
                limit: limit,
                cursor: cursor,
                direction: direction,
                timing: timing
            )
        }

        /// Execute the `summarize` operation.
        public func summarize(
            limit: Int? = nil,
            cursor: String? = nil,
            direction: SortDirection? = nil,
            timing: Bool? = nil
        ) async throws -> SummarizeResult {
            try await client.databases.executeOperation(
                databaseId: databaseId,
                name: "summarize",
                params: SummarizeParams(),
                limit: limit,
                cursor: cursor,
                direction: direction,
                timing: timing
            )
        }
    }

    /// Typed operations factory for the `catalog` database type.
    public static func ops(_ client: JsBaoClient, databaseId: String) -> Ops {
        Ops(client: client, databaseId: databaseId)
    }
}
