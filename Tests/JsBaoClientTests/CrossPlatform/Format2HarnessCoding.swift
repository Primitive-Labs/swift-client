import Foundation
@testable import JsBaoClient

/// Translation between the Swift format-2 types and the JSON the parity
/// harness speaks. Test-side on purpose: the harness is a test vehicle, and
/// the library has no reason to know it exists.

extension JSONValue {
    /// Build a `JSONValue` from whatever `JSONSerialization` handed back.
    ///
    /// `NSNumber` is the awkward one: JSONSerialization represents both `true`
    /// and `1` as `NSNumber`, and only its CFNumber type tells them apart. A
    /// bool read as `.number(1)` would compare unequal to the `.bool(true)`
    /// Swift wrote and look like a fold divergence.
    init(harness value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let array as [Any]:
            self = .array(array.map { JSONValue(harness: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { JSONValue(harness: $0) })
        default:
            self = .null
        }
    }

    /// The `JSONSerialization`-compatible value for this one.
    var harnessJSON: Any {
        switch self {
        case .null: return NSNull()
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .array(let a): return a.map(\.harnessJSON)
        case .object(let o): return o.mapValues(\.harnessJSON)
        }
    }
}

extension OverlayMutation {
    /// Read the `OverlayMutation` shape `largeDocuments.ts` writes, so a
    /// scripted parity sequence is authored ONCE and run through both sides.
    init?(harness json: [String: Any]) {
        guard let id = json["id"] as? String,
              let kind = (json["kind"] as? String).flatMap(Kind.init(rawValue:))
        else { return nil }
        let fields = (json["fields"] as? [String: Any] ?? [:])
            .mapValues { JSONValue(harness: $0) }
        let deltas = (json["stringSetDeltas"] as? [String: Any] ?? [:])
            .compactMapValues { value -> [String: Bool]? in
                (value as? [String: Any])?.compactMapValues { $0 as? Bool }
            }
        self.init(id: id, kind: kind, fields: fields, stringSetDeltas: deltas)
    }

    /// The `OverlayMutation` shape `largeDocuments.ts` reads.
    var harnessJSON: [String: Any] {
        var out: [String: Any] = ["id": id, "kind": kind.rawValue]
        if !fields.isEmpty {
            out["fields"] = fields.mapValues(\.harnessJSON)
        }
        if !stringSetDeltas.isEmpty {
            out["stringSetDeltas"] = stringSetDeltas.mapValues { $0 as [String: Bool] }
        }
        return out
    }
}
