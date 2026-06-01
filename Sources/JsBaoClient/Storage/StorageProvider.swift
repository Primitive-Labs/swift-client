import Foundation

/// A record stored in a key-value store.
///
/// Wire-format-compatible with js-bao-wss-client's `StorageRecord` shape:
///   `{ key: string, value: T, metadata?: Record<string, unknown>,
///      updatedAt?: string, updatedAtMs?: number }`
///
/// Apple-side note on `metadata`:
/// JS callers may write arbitrary JSON values into `metadata` (numbers,
/// booleans, nested objects). The Swift surface keeps the *runtime*
/// type as `[String: String]?` so existing Swift callers stay
/// source-compatible, but the custom `init(from:)` below tolerates
/// any JSON value on the wire: scalars are stringified
/// (`42 → "42"`, `true → "true"`), and nested objects/arrays are
/// preserved as their JSON text. Previously, decode would *throw*
/// on the first non-string metadata value, silently dropping any
/// record written by JS.
///
/// `updatedAtMs` mirrors js-bao-wss-client: numeric epoch-ms, used by
/// `KvCache.refreshIfOlderThanMs` for cache freshness. Distinct from
/// the legacy `updatedAt: String?` ISO field (kept for backward
/// compatibility with stored Swift-side records).
public struct StorageRecord<T: Codable>: Codable, Sendable where T: Sendable {
    public let key: String
    public let value: T
    public let metadata: [String: String]?
    public let updatedAt: String?
    public let updatedAtMs: Double?

    public init(
        key: String,
        value: T,
        metadata: [String: String]? = nil,
        updatedAt: String? = nil,
        updatedAtMs: Double? = nil
    ) {
        self.key = key
        self.value = value
        self.metadata = metadata
        self.updatedAt = updatedAt
        self.updatedAtMs = updatedAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case key, value, metadata, updatedAt, updatedAtMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try c.decode(String.self, forKey: .key)
        self.value = try c.decode(T.self, forKey: .value)
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        self.updatedAtMs = try c.decodeIfPresent(Double.self, forKey: .updatedAtMs)

        // Tolerant metadata decode: each value can be any JSON type;
        // we stringify scalars and preserve compound values as their
        // JSON text. Matches js-bao-wss-client's
        // `Record<string, unknown>` wire shape (see parity doc gap K).
        if c.contains(.metadata),
           try c.decodeNil(forKey: .metadata) == false {
            var meta: [String: String] = [:]
            let mc = try c.nestedContainer(
                keyedBy: AnyKey.self, forKey: .metadata
            )
            for k in mc.allKeys {
                meta[k.stringValue] = try Self.decodeAsString(in: mc, key: k)
            }
            self.metadata = meta
        } else {
            self.metadata = nil
        }
    }

    /// Try each JSON scalar type in order; fall back to JSON-serializing
    /// nested objects/arrays. The result is always a `String`, which is
    /// what the existing `metadata: [String: String]?` API exposes.
    private static func decodeAsString(
        in c: KeyedDecodingContainer<AnyKey>,
        key: AnyKey
    ) throws -> String {
        if try c.decodeNil(forKey: key) { return "" }
        if let s = try? c.decode(String.self, forKey: key) { return s }
        if let b = try? c.decode(Bool.self, forKey: key) { return String(b) }
        if let i = try? c.decode(Int64.self, forKey: key) { return String(i) }
        if let d = try? c.decode(Double.self, forKey: key) { return String(d) }
        // Nested object or array: roundtrip through JSONSerialization so
        // callers see something parseable instead of losing the value.
        if let nested = try? c.decode(AnyJSON.self, forKey: key) {
            return nested.jsonString
        }
        return ""
    }
}

/// Minimal `CodingKey` that accepts any string. Used to walk arbitrary
/// JSON objects in `StorageRecord.metadata` decoding.
private struct AnyKey: CodingKey {
    let stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}

/// Thin Codable shim used only to round-trip nested JSON in metadata
/// values back out to a string. Not exposed publicly.
private struct AnyJSON: Codable {
    let raw: Any

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: AnyKey.self) {
            var dict: [String: Any] = [:]
            for k in c.allKeys {
                dict[k.stringValue] = try AnyJSON(from: c.superDecoder(forKey: k)).raw
            }
            self.raw = dict
            return
        }
        if var c = try? decoder.unkeyedContainer() {
            var arr: [Any] = []
            while !c.isAtEnd {
                arr.append(try AnyJSON(from: c.superDecoder()).raw)
            }
            self.raw = arr
            return
        }
        let s = try decoder.singleValueContainer()
        if s.decodeNil() {
            self.raw = NSNull()
        } else if let v = try? s.decode(Bool.self) {
            self.raw = v
        } else if let v = try? s.decode(Int64.self) {
            self.raw = v
        } else if let v = try? s.decode(Double.self) {
            self.raw = v
        } else if let v = try? s.decode(String.self) {
            self.raw = v
        } else {
            self.raw = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        // Encoding path isn't used (we only need decoding fidelity for
        // metadata), but the protocol requires it. Forward to
        // JSONSerialization for completeness.
        let data = try JSONSerialization.data(
            withJSONObject: raw, options: [.fragmentsAllowed]
        )
        var c = encoder.singleValueContainer()
        try c.encode(String(data: data, encoding: .utf8) ?? "")
    }

    var jsonString: String {
        guard JSONSerialization.isValidJSONObject(raw)
                || raw is NSNumber || raw is NSString || raw is NSNull
        else { return "" }
        let opts: JSONSerialization.WritingOptions = [.fragmentsAllowed]
        guard let data = try? JSONSerialization.data(
                withJSONObject: raw, options: opts),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }
}

/// Protocol matching the JS StorageProvider interface.
///
/// Provides a key-value store organized by named stores (analogous to
/// IndexedDB object stores). Each store contains records keyed by string,
/// with JSON-serializable values and optional metadata.
public protocol StorageProvider: AnyObject, Sendable {
    /// Initialize the storage provider with a namespace (used to isolate data per client instance).
    func initialize(namespace: String) async throws

    /// Close the storage provider and release resources.
    func close() async

    /// Whether the provider has been initialized and is ready for use.
    func isReady() -> Bool

    /// Get a single record by store and key. Returns nil if not found.
    func get<T: Codable>(store: String, key: String) async throws -> StorageRecord<T>?

    /// Put a single record into a store, upserting by key.
    func put<T: Codable>(store: String, key: String, value: T, metadata: [String: String]?) async throws

    /// Put multiple records into a store in a single transaction.
    func putBatch<T: Codable>(store: String, records: [(key: String, value: T, metadata: [String: String]?)]) async throws

    /// Delete a single record by store and key.
    func delete(store: String, key: String) async throws

    /// Clear all records in a store.
    func clear(store: String) async throws

    /// Iterate over all records in a store, invoking the callback for each.
    func iterate<T: Codable>(store: String, callback: @escaping (StorageRecord<T>) throws -> Void) async throws

    /// Return all keys in a store.
    func keys(store: String) async throws -> [String]

    /// Check whether a key exists in a store.
    func has(store: String, key: String) async throws -> Bool
}
