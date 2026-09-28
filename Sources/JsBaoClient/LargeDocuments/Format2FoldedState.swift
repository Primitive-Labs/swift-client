import Foundation

/// What a large document's record store last folded (#3782).
///
/// A bind used to catch up by folding every registered model's whole overlay
/// on every open — for a document that never rotated, the document. The store
/// now keeps the overlay's state vector at the last fold and the models that
/// fold covered, beside the epoch mark: a bind whose overlay has the stored
/// vector, with every model to bind covered, folds nothing.
///
/// The stored form is the JS client's, byte for byte
/// (`format2FoldedState.ts`): canonical JSON with client ids as decimal
/// strings in ascending NUMERIC order and the models sorted, so one database
/// reads the same on both clients and two equal states are the same text.
public struct FoldedState: Equatable, Sendable {
    /// `clientId → clock`, client ids as decimal strings.
    public let vector: [String: Int]
    /// The models whose overlay maps the vector vouches for, sorted.
    public let models: [String]

    public init(vector: [String: Int], models: [String]) {
        self.vector = vector.filter { $0.value >= 0 }
        self.models = Array(Set(models)).sorted()
    }

    /// The column's text.
    public func encoded() -> String {
        let clients = Self.orderedClients(vector).map { client in
            "\(Self.jsonString(client)):\(vector[client] ?? 0)"
        }
        let models = self.models.map(Self.jsonString).joined(separator: ",")
        return "{\"vector\":{\(clients.joined(separator: ","))},\"models\":[\(models)]}"
    }

    /// The column's shape, decoded typed rather than through an untyped
    /// dictionary.
    private struct Stored: Decodable {
        let vector: [String: Int]
        let models: [String]
    }

    /// Read the column back; anything unreadable is "nothing known".
    public static func decode(_ text: String?) -> FoldedState? {
        guard let text, let data = text.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        return FoldedState(vector: stored.vector, models: stored.models)
    }

    /// Per-client MAX of the two vectors, and the union of the models.
    public func merged(with offered: FoldedState) -> FoldedState {
        var vector = self.vector
        for (client, clock) in offered.vector {
            vector[client] = max(vector[client] ?? 0, clock)
        }
        return FoldedState(vector: vector, models: models + offered.models)
    }

    /// Whether ``merged(with:)`` keeps every model's claim true (finding
    /// 3782-C04).
    ///
    /// A model's claim is "every item of its map below the vector is folded".
    /// Coverage is per item, so a model both states name is covered below the
    /// per-client max of the two. A model only ONE side names is covered below
    /// that side's vector alone, which is the merged one only when the other
    /// side is at or below it.
    public func mergeKeepsEveryModel(_ offered: FoldedState) -> Bool {
        let mine = Set(models), theirs = Set(offered.models)
        if !mine.subtracting(theirs).isEmpty,
           !Self.isAtOrAhead(vector, of: offered.vector) {
            return false
        }
        if !theirs.subtracting(mine).isEmpty,
           !Self.isAtOrAhead(offered.vector, of: vector) {
            return false
        }
        return true
    }

    /// Whether a document at `docState` is at or ahead of `stored` on EVERY
    /// client the stored vector names — the guard both clients share
    /// (finding 3782-R02): only then can a fold from it not regress a key the
    /// store already vouches for.
    public static func isAtOrAhead(_ docState: [String: Int], of stored: [String: Int]) -> Bool {
        stored.allSatisfy { client, clock in (docState[client] ?? 0) >= clock }
    }

    private static func orderedClients(_ vector: [String: Int]) -> [String] {
        vector.keys.sorted { left, right in
            switch (UInt64(left), UInt64(right)) {
            case let (l?, r?) where l != r: return l < r
            default: return left < right
            }
        }
    }

    /// A JSON string literal, escaped as `JSON.stringify` escapes it.
    private static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// What a bind did about the overlay it found (#3782).
public enum Format2BindCatchUp: Equatable, Sendable {
    /// The overlay is the one the store last folded: nothing was folded.
    case skipped
    /// The overlay is folded up, but these models were never covered: each
    /// was caught up on its own.
    case partial([String])
    /// Nothing is known, the vectors differ, or the fold was broken: every
    /// registered model's whole overlay was folded, as every bind did before.
    case whole([String])
}
