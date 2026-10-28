import Foundation

// What a record-log record may hold: a field value is a string, a number, a
// boolean, null or an array of strings (a string set), and a field or model
// name is an identifier. A string set is changed in place by
// `{ $add, $remove, $clear }`. The room judges every write with these rules
// and the client checks them before an entry leaves it, so both say the same
// sentence. A port of js-bao's `record-log/values.ts`.

enum RecordLogValues {
    /// The kind of an accepted field value: a scalar, `null`, a string set (an
    /// array of strings, `[]` included) or a string-set change.
    enum Kind: String, Equatable, Sendable {
        case string, number, boolean, null, stringset, setOp
    }

    /// A value's kind, or what makes it no field value.
    enum Judgement: Equatable, Sendable {
        case kind(Kind)
        case invalid(String)
    }

    /// What a name names, for the message.
    enum NameKind: String, Sendable {
        case field, model
    }

    private static let setOpKeys: Set<String> = ["$add", "$remove", "$clear"]

    /// A short description of a value that is not one of its array's members.
    private static func describeMember(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .array: return "an array"
        case .object: return "an object"
        case .string: return "a string"
        case .number: return "a number"
        case .bool: return "a boolean"
        }
    }

    /// The kind of a field value, or `.invalid` describing why it is not one:
    /// an object (other than a string-set change), or an array holding
    /// anything but strings (naming its first such member).
    static func valueKind(_ value: JSONValue) -> Judgement {
        switch value {
        case .null: return .kind(.null)
        case .string: return .kind(.string)
        case .number: return .kind(.number)
        case .bool: return .kind(.boolean)
        case .array(let items):
            for (index, item) in items.enumerated() where item.stringValue == nil {
                return .invalid("an array whose member \(index) is \(describeMember(item))")
            }
            return .kind(.stringset)
        case .object(let object):
            if object.isEmpty || object.keys.contains(where: { !setOpKeys.contains($0) }) { return .invalid("an object") }
            for key in ["$add", "$remove"] {
                guard let members = object[key] else { continue }
                guard let items = members.arrayValue else {
                    return .invalid("a string-set change whose \(key) is not an array")
                }
                for (index, item) in items.enumerated() where item.stringValue == nil {
                    return .invalid("a string-set change whose \(key) member \(index) is \(describeMember(item))")
                }
            }
            if let clear = object["$clear"], clear.boolValue == nil {
                return .invalid("a string-set change whose $clear is not true or false")
            }
            return .kind(.setOp)
        }
    }

    /// What a value of an accepted kind is called in a refusal.
    static func describeValueKind(_ kind: Kind) -> String {
        switch kind {
        case .null: return "null"
        case .stringset: return "an array of strings"
        case .setOp: return "a string-set change"
        default: return "a \(kind.rawValue)"
        }
    }

    /// Whether `name` is an identifier: a letter, then letters, digits or `_`.
    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "_" || CharacterSet.alphanumerics.contains($0)) }
    }

    /// Why `name` is not an identifier, or `nil` when it is one.
    static func identifierProblem(_ kind: NameKind, _ name: String) -> String? {
        if isIdentifier(name) { return nil }
        return "\(kind.rawValue) \(RecordLogJSON.text(.string(name))) is not an identifier (a letter, then letters, digits or _)"
    }

    /// The refusal of a value that is no field value; `description` is what
    /// the value is, as ``valueKind(_:)`` describes it.
    static func valueProblem(model: String, id: String, field: String, description: String) -> String {
        "\(model) id=\(id): field \(RecordLogJSON.text(.string(field))) holds \(description); "
            + "a field value is a string, a number, a boolean, null or an array of strings"
    }

    /// Why a mutation breaks the write rules, in the room's words, or `nil`: a
    /// model or field name that is not an identifier, or a value in `fields`
    /// that is not a string, a number, a boolean or null. A string set travels
    /// in `stringSetDeltas`, so any array left in `fields` is refused.
    static func ruleProblem(_ m: RecordLogMutation) -> String? {
        if let model = identifierProblem(.model, m.model) { return model }
        if m.kind == .increment {
            // An increment adds a finite number to each field it names (#4797).
            let deltas = m.fields ?? [:]
            if deltas.isEmpty { return "an increment names no field" }
            if m.stringSetDeltas != nil { return "an increment carries no stringSetDeltas" }
            if deltas["id"] != nil { return "an increment cannot change id" }
            for (name, delta) in deltas.sorted(by: { $0.key < $1.key }) {
                if let problem = identifierProblem(.field, name) { return "\(problem). Rename the field" }
                guard case .number(let number) = delta, number.isFinite else {
                    return "the increment of \(RecordLogJSON.text(.string(name))) must be a finite number"
                }
            }
            return nil
        }
        let fields = m.fields ?? [:]
        for name in fields.keys.sorted() + (m.stringSetDeltas ?? [:]).keys.sorted() where name != "id" {
            if let problem = identifierProblem(.field, name) { return "\(problem). Rename the field" }
        }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) where name != "id" {
            switch valueKind(value) {
            case .invalid(let description):
                return valueProblem(model: m.model, id: m.id, field: name, description: description)
            case .kind(let kind) where kind == .stringset || kind == .setOp:
                return valueProblem(model: m.model, id: m.id, field: name, description: describeValueKind(kind))
            case .kind:
                continue
            }
        }
        return nil
    }
}
