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
}
