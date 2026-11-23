import Foundation

// MARK: - Permission levels a REST answer reports
//
// Each enum lists the levels the app API declares for the answer, the same
// set as the JS client's union. A level this client does not know decodes as
// `.unknown` carrying the string the server sent, so a level added later never
// fails the rest of the decode. `allCases` lists the known levels only.
//
// ```swift
// for grant in try await client.documents.listGroupPermissions(documentId) {
//     switch grant.permission {
//     case .readWrite: print("\(grant.groupId) can edit")
//     case .reader: print("\(grant.groupId) can read")
//     case .unknown(let level): print("\(grant.groupId) holds \(level)")
//     }
// }
// ```

/// A document or db3 level an answer reports: the caller's access, a user's
/// grant, or a listed document's level. Mirrors JS
/// `"owner" | "read-write" | "reader"`.
public enum DocumentAccessLevel: RawRepresentable, CaseIterable, Codable, Sendable, Hashable {
    case owner
    case readWrite
    case reader
    /// A level this client does not know, as the server sent it.
    case unknown(String)

    /// The known levels, highest first.
    public static var allCases: [DocumentAccessLevel] { [.owner, .readWrite, .reader] }

    public init(rawValue: String) {
        switch rawValue {
        case "owner": self = .owner
        case "read-write": self = .readWrite
        case "reader": self = .reader
        default: self = .unknown(rawValue)
        }
    }

    /// The wire string: `"owner"`, `"read-write"`, `"reader"`, or the unknown level.
    public var rawValue: String {
        switch self {
        case .owner: return "owner"
        case .readWrite: return "read-write"
        case .reader: return "reader"
        case .unknown(let value): return value
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A level a document or db3 grant confers: a group grant, a pending
/// invitation, a permission update's result, an access request. `owner` is
/// never granted. Mirrors JS `"read-write" | "reader"`.
public enum DocumentGrantLevel: RawRepresentable, CaseIterable, Codable, Sendable, Hashable {
    case readWrite
    case reader
    /// A level this client does not know, as the server sent it.
    case unknown(String)

    /// The known levels, highest first.
    public static var allCases: [DocumentGrantLevel] { [.readWrite, .reader] }

    public init(rawValue: String) {
        switch rawValue {
        case "read-write": self = .readWrite
        case "reader": self = .reader
        default: self = .unknown(rawValue)
        }
    }

    /// The wire string: `"read-write"`, `"reader"`, or the unknown level.
    public var rawValue: String {
        switch self {
        case .readWrite: return "read-write"
        case .reader: return "reader"
        case .unknown(let value): return value
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A database level an answer reports. Mirrors JS `"owner" | "manager"`.
public enum DatabaseAccessLevel: RawRepresentable, CaseIterable, Codable, Sendable, Hashable {
    case owner
    case manager
    /// A level this client does not know, as the server sent it.
    case unknown(String)

    /// The known levels, highest first.
    public static var allCases: [DatabaseAccessLevel] { [.owner, .manager] }

    public init(rawValue: String) {
        switch rawValue {
        case "owner": self = .owner
        case "manager": self = .manager
        default: self = .unknown(rawValue)
        }
    }

    /// The wire string: `"owner"`, `"manager"`, or the unknown level.
    public var rawValue: String {
        switch self {
        case .owner: return "owner"
        case .manager: return "manager"
        case .unknown(let value): return value
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The deprecated level a collection answer reports beside `role`: `reader`
/// for viewer and contributor, `read-write` for editor, manager and owner.
/// Mirrors JS `"reader" | "read-write"`.
public enum CollectionAccessLevel: RawRepresentable, CaseIterable, Codable, Sendable, Hashable {
    case reader
    case readWrite
    /// A level this client does not know, as the server sent it.
    case unknown(String)

    /// The known levels.
    public static var allCases: [CollectionAccessLevel] { [.reader, .readWrite] }

    public init(rawValue: String) {
        switch rawValue {
        case "reader": self = .reader
        case "read-write": self = .readWrite
        default: self = .unknown(rawValue)
        }
    }

    /// The wire string: `"reader"`, `"read-write"`, or the unknown level.
    public var rawValue: String {
        switch self {
        case .reader: return "reader"
        case .readWrite: return "read-write"
        case .unknown(let value): return value
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension DocumentPermission {
    /// The client-held level an answered document level names; `nil` for a
    /// level this client does not know, which it does not hold.
    init?(_ level: DocumentAccessLevel) {
        switch level {
        case .owner: self = .owner
        case .readWrite: self = .readWrite
        case .reader: self = .reader
        case .unknown: return nil
        }
    }
}
