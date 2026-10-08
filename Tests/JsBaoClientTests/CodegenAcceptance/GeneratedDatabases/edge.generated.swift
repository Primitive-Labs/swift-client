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
}
