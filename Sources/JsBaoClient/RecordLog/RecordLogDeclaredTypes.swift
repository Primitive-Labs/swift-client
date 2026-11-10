import Foundation

/// A typed db3's declarations judged on the device (#5020): the rules the
/// room applies to a socket entry on a typed db3, run before a model write
/// commits, with the room's codes and words. js-bao's `declared-types.ts`.
///
/// The declarations are the ones the room sent this device with
/// `record.opened` (the store holds them by revision hash), never the
/// client's own schema: a field the type does not declare is not judged, and
/// a type that declares no model takes every model. The room stays the
/// authority; this only spares a write it would refuse.
struct RecordLogDeclaredType: Equatable, Sendable {
    /// The type's name, which a refusal of an undeclared model names.
    var name: String
    /// Per declared model, each declared field's kind.
    var models: [String: [String: String]]
    /// Per model declaring one, each vector field's encoding (#5225).
    var vectors: RecordLogVectorDeclarations = [:]
}

/// What a written value is, for a vector refusal's message (#5225): js-bao's
/// `vectorWrittenLabel`.
private func recordLogVectorWrittenLabel(_ value: JSONValue) -> String {
    switch value {
    case .string(let text): return "a string of \(text.utf16.count) characters that is not that encoding's canonical base64"
    case .array: return "an array"
    case .object: return "a string-set change"
    case .number: return "a number"
    case .bool: return "a boolean"
    case .null: return "an object"
    }
}

/// Whether `value` is what a field of `encoding` holds: `null` or its canonical base64.
func recordLogFitsVector(_ value: JSONValue, _ encoding: VectorEncoding) -> Bool {
    switch value {
    case .null: return true
    case .string(let text): return VectorCodec.isCanonical(text, bytes: VectorCodec.byteLength(encoding))
    default: return false
    }
}

/// The message of a vector refusal: the record, the field, the declared encoding and what was written.
func recordLogVectorWriteProblem(model: String, id: String, field: String, encoding: VectorEncoding, written: String) -> String {
    "\(model) id=\(id): field \"\(field)\" is declared \(VectorCodec.describeField(encoding)); the write is \(written)"
}

/// Why an entry's mutations break a vector field, or `nil` (#5225): a value
/// that is neither `null` nor the field's canonical base64, a string-set
/// change of the field, or an increment of it. `m` is the first mutation,
/// `also[i]` the others. js-bao's `vectorMutationsProblem`, the rule the room
/// and the devices judge an entry with.
func recordLogVectorMutationsProblem(
    _ mutations: [RecordLogMutation], _ encodingOf: (String, String) -> VectorEncoding?
) -> String? {
    for (at, m) in mutations.enumerated() where m.kind != .delete {
        let place = at == 0 ? "m" : "also[\(at - 1)]"
        for (field, value) in (m.fields ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let encoding = encodingOf(m.model, field) else { continue }
            if m.kind == .increment {
                return "\(place): " + recordLogVectorWriteProblem(model: m.model, id: m.id, field: field, encoding: encoding, written: "an increment")
            }
            if !recordLogFitsVector(value, encoding) {
                return "\(place): " + recordLogVectorWriteProblem(
                    model: m.model, id: m.id, field: field, encoding: encoding, written: recordLogVectorWrittenLabel(value)
                )
            }
        }
        for field in (m.stringSetDeltas ?? [:]).keys.sorted() {
            guard let encoding = encodingOf(m.model, field) else { continue }
            return "\(place): " + recordLogVectorWriteProblem(model: m.model, id: m.id, field: field, encoding: encoding, written: "a string-set change")
        }
    }
    return nil
}

/// The scalar kinds a value is judged against.
private let recordLogScalarKinds: Set<String> = ["string", "number", "boolean", "date", "id"]

/// The date-string syntax a `date` field accepts: an ISO-8601 calendar date,
/// optionally followed by a `T`- or space-separated time and a `Z` or
/// `±HH:MM` offset.
private let recordLogIsoDate = try! NSRegularExpression(
    pattern: #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?(?:Z|[+-](\d{2}):?(\d{2}))?)?$"#
)

/// Whether a `date` field takes `value`, as the room judges it: an ISO-8601
/// date string that denotes a real instant on a real calendar day, or an
/// epoch number of milliseconds a JavaScript `Date` can represent. Days are
/// those of the proleptic Gregorian calendar a JavaScript `Date` keeps (no
/// 1582 cutover, a year zero), and hour 24 is midnight only: zero minutes,
/// seconds and fraction.
func recordLogIsRepresentableDate(_ value: JSONValue) -> Bool {
    switch value {
    case .number(let number):
        return number.isFinite && abs(number) <= 8.64e15
    case .string(let text):
        let range = NSRange(text.startIndex..., in: text)
        guard let match = recordLogIsoDate.firstMatch(in: text, range: range) else { return false }
        func part(_ i: Int) -> Int? {
            guard let r = Range(match.range(at: i), in: text) else { return nil }
            return Int(text[r])
        }
        guard let year = part(1), let month = part(2), let day = part(3), (1...12).contains(month), (1...31).contains(day) else {
            return false
        }
        if let hour = part(4), let minute = part(5) {
            let second = part(6) ?? 0
            let fractionIsZero = Range(match.range(at: 7), in: text).map { text[$0].allSatisfy { $0 == "0" } } ?? true
            guard minute <= 59, second <= 59, hour <= 23 || (hour == 24 && minute == 0 && second == 0 && fractionIsZero) else {
                return false
            }
        }
        if let offsetHours = part(8), let offsetMinutes = part(9), offsetHours > 23 || offsetMinutes > 59 { return false }
        // A day past the end of its month ("2026-02-30") is no day.
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        return day <= days
    default:
        return false
    }
}

/// What a value is, for a refusal's message: JavaScript's `typeof`, and
/// `an array` for an array.
private func recordLogReceivedKind(_ value: JSONValue) -> String {
    switch value {
    case .string: return "string"
    case .number: return "number"
    case .bool: return "boolean"
    case .array: return "an array"
    case .object: return "object"
    case .null: return "object"
    }
}

/// Why an entry's mutations break `type`, or `nil`: a mutation of a model the
/// type does not declare when it declares any (`.db3ModelNotDeclared`), or, on
/// a declared model, a non-null value of a declared field its kind does not
/// take, a scalar in a string set or a string-set change of a scalar
/// (`.documentEntryInvalid`). An increment writes numbers; a delete, an `id`
/// and a field the type does not declare are not judged. `m` is the first
/// mutation, `also[i]` the others. A vector field (#5225) is judged first, by
/// the room's vector rule (``recordLogVectorMutationsProblem``),
/// `.db3VectorInvalid`.
func recordLogDeclaredTypeProblem(
    _ mutations: [RecordLogMutation], _ type: RecordLogDeclaredType
) -> (code: JsBaoErrorCode, message: String)? {
    if !type.vectors.isEmpty, let vector = recordLogVectorMutationsProblem(mutations, { type.vectors[$0]?[$1] }) {
        return (.db3VectorInvalid, vector)
    }
    let declaredModels = type.models.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
    for (at, m) in mutations.enumerated() {
        let place = at == 0 ? "m" : "also[\(at - 1)]"
        if !declaredModels.isEmpty && type.models[m.model] == nil {
            return (
                .db3ModelNotDeclared,
                "\(place): \(m.model) is not a model of the db3's type \(type.name); it declares \(declaredModels.joined(separator: ", "))"
            )
        }
        if m.kind == .delete { continue }
        guard let kinds = type.models[m.model], !kinds.isEmpty else { continue }
        func refuse(_ field: String, _ declared: String, _ received: String) -> (code: JsBaoErrorCode, message: String) {
            (.documentEntryInvalid, "\(place): \(m.model) id=\(m.id): field \"\(field)\" is declared \(declared); the entry wrote \(received)")
        }
        // The room walks the fields in the order the entry carries them.
        for (field, value) in (m.fields ?? [:]).sorted(by: { $0.key < $1.key }) {
            if field == "id" || value == .null { continue }
            guard let declared = kinds[field] else { continue }
            let kind = m.kind == .increment ? "number" : recordLogReceivedKind(value)
            if declared == "stringset" { return refuse(field, declared, "a scalar (\(kind))") }
            guard recordLogScalarKinds.contains(declared) else { continue }
            let matches: Bool
            switch declared {
            case "date": matches = (kind == "string" || kind == "number") && (m.kind == .increment || recordLogIsRepresentableDate(value))
            case "id": matches = kind == "string"
            default: matches = kind == declared
            }
            if !matches { return refuse(field, declared, kind == "string" && declared == "date" ? "a string that is not an ISO date" : kind) }
        }
        for field in (m.stringSetDeltas ?? [:]).keys.sorted() {
            if let declared = kinds[field], declared != "stringset", declared != "vector" {
                return refuse(field, declared, "a string-set change")
            }
        }
    }
    return nil
}

/// Refuse an entry that breaks `type` before it commits: the room's code and
/// message on a `JsBaoError` (`details.scope: "local"`), reported once through
/// `report`. Nothing is judged without a type.
func assertRecordLogDeclaredTypes(
    documentId: String, mutations: [RecordLogMutation], type: RecordLogDeclaredType?,
    report: (DocumentWriteRefusedEvent) -> Void
) throws {
    guard let type, !mutations.isEmpty, let problem = recordLogDeclaredTypeProblem(mutations, type) else { return }
    let error = JsBaoError(
        code: problem.code, message: problem.message, details: ["documentId": .string(documentId), "scope": "local"]
    )
    report(recordLogLocalRefusal(error, documentId: documentId, mutations: mutations))
    throw error
}
