import Foundation

/// Registry of named default-value generators referenced by `$<name>` in
/// `_meta_*`. Mirrors js-bao's `registerFunctionDefault` / `encodeDefault`
/// pair: on the wire, a function default is stored as the sentinel string
/// `"$<name>"`, and on read the Swift side can look up the generator here.
///
/// Currently one name is reserved: `generate_ulid` (ULID generator).
/// Unknown names resolve to `nil` — the CRDT-level contract is that a
/// non-resolvable function default simply means "no default applied,"
/// not an error.
public final class PrimitiveSchemaRegistry: @unchecked Sendable {
    public static let shared = PrimitiveSchemaRegistry()

    private var generators: [String: () -> PrimitiveValue] = [:]
    private let lock = NSLock()

    public init() {
        register(name: "generate_ulid") {
            .id(Self.generateULID())
        }
    }

    /// Register a named generator. Replaces any existing registration for
    /// the same name.
    public func register(name: String, generator: @escaping () -> PrimitiveValue) {
        lock.lock()
        defer { lock.unlock() }
        generators[stripDollar(name)] = generator
    }

    /// Look up a generator. Accepts both `"generate_ulid"` and the
    /// `"$generate_ulid"` wire form. Returns `nil` when not registered.
    public func resolve(_ name: String) -> (() -> PrimitiveValue)? {
        lock.lock()
        defer { lock.unlock() }
        return generators[stripDollar(name)]
    }

    private func stripDollar(_ name: String) -> String {
        name.hasPrefix("$") ? String(name.dropFirst()) : name
    }

    // MARK: - ULID generation

    /// Crockford base-32 ULID. 48-bit ms timestamp + 80 bits randomness.
    /// Mirrors the internal generator in `BlobManager.swift` so we don't
    /// pull in a dependency. If that one ever becomes public, swap this
    /// to delegate.
    private static let ulidAlphabet: [Character] =
        Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generateULID() -> String {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var chars = [Character](repeating: "0", count: 26)
        var t = now
        for i in stride(from: 9, through: 0, by: -1) {
            chars[i] = ulidAlphabet[Int(t & 0x1F)]
            t >>= 5
        }
        for i in 10..<26 {
            chars[i] = ulidAlphabet[Int.random(in: 0..<32)]
        }
        return String(chars)
    }
}
