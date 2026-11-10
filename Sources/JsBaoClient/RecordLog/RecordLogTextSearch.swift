import Foundation

/// How a text index splits and folds words (#5223): js-bao's `TextIndexTokenizer`.
typealias RecordLogTextTokenizer = Db3TextTokenizer

extension Db3TextTokenizer {
    /// The FTS5 `tokenize` argument: diacritics folded either way.
    var tokenize: String {
        self == .porter ? "porter unicode61 remove_diacritics 2" : "unicode61 remove_diacritics 2"
    }
}

/// A db3 text index's options (#5223), js-bao's `record-log/textIndex.ts`:
/// the tokenizer, FTS5's prefix-index lengths and a weight per covered
/// field, checked once where a registration enters (a local-only db3's
/// registry, the store's cache of the room's list) and kept filled in, so
/// every reader takes them as given. As the store caches them they also carry
/// the entry's placement and, when its table is not built, why.
struct RecordLogTextIndexOptions: Equatable, Sendable {
    var tokenizer: RecordLogTextTokenizer
    /// FTS5's prefix-index lengths, each 1 to 32, in the order given.
    var prefix: [Int]
    /// A positive weight per covered field; 1 for each field the registration left out.
    var weights: [String: Double]
    /// Where the entry lives, as the store caches it.
    var on: Db3IndexPlacement?
    /// Why the store holds no table for it: its build failed.
    var unbuilt: String?

    init(
        tokenizer: RecordLogTextTokenizer, prefix: [Int], weights: [String: Double], on: Db3IndexPlacement? = nil,
        unbuilt: String? = nil
    ) {
        self.tokenizer = tokenizer
        self.prefix = prefix
        self.weights = weights
        self.on = on
        self.unbuilt = unbuilt
    }

    /// The most prefix-index lengths a text index takes.
    static let maxPrefixes = 8
    /// The longest prefix-index length a text index takes.
    static let maxPrefixLength = 32

    private static let optionKeys = ["tokenizer", "prefix", "weights"]

    private static func invalid(_ message: String) -> JsBaoError {
        JsBaoError(code: .db3IndexInvalid, message: message)
    }

    /// A registration's `text` options over `fields`, checked and filled in:
    /// `tokenizer` `unicode61` when absent, `prefix` at most 8 integers from 1
    /// to 32 (none when absent), `weights` a positive finite number per
    /// covered field (1 for each field it leaves out). `raw` may be absent.
    ///
    /// - Throws: `JsBaoError(.db3IndexInvalid)` with js-bao's message, naming
    ///   an unknown key, a tokenizer the index does not take, a prefix length
    ///   out of range, a weight on a field the index does not cover, or one
    ///   that is not a positive number.
    static func parse(fields: [String], raw: JSONValue?) throws -> RecordLogTextIndexOptions {
        guard let options = (raw ?? .object([:])).objectValue else {
            throw invalid("text options must be an object: { tokenizer?, prefix?, weights? }")
        }
        if let unknown = options.keys.sorted().first(where: { !optionKeys.contains($0) }) {
            throw invalid("text.\(unknown) is not a text index option: give tokenizer, prefix or weights")
        }
        let tokenizer: RecordLogTextTokenizer
        if let given = options["tokenizer"] {
            guard let known = given.stringValue.flatMap(RecordLogTextTokenizer.init(rawValue:)) else {
                throw invalid("text.tokenizer must be one of \(RecordLogTextTokenizer.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            tokenizer = known
        } else {
            tokenizer = .unicode61
        }
        var prefix: [Int] = []
        if let given = options["prefix"] {
            let lengths = given.arrayValue?.map { $0.wholeNumber }
            guard let lengths, lengths.count <= maxPrefixes,
                  lengths.allSatisfy({ ($0 ?? 0) >= 1 && ($0 ?? 0) <= maxPrefixLength })
            else {
                throw invalid("text.prefix must be at most \(maxPrefixes) integers from 1 to \(maxPrefixLength)")
            }
            prefix = lengths.compactMap { $0 }
        }
        let given = options["weights"] ?? .object([:])
        guard let byField = given.objectValue else { throw invalid("text.weights must be an object of field: weight") }
        for field in byField.keys.sorted() {
            guard fields.contains(field) else {
                throw invalid("text.weights.\(field) names a field the index does not cover: \(fields.joined(separator: ", "))")
            }
            guard case .number(let weight)? = byField[field], weight.isFinite, weight > 0 else {
                throw invalid("text.weights.\(field) must be a positive number")
            }
        }
        var weights: [String: Double] = [:]
        for field in fields { weights[field] = byField[field]?.numberValue ?? 1 }
        return RecordLogTextIndexOptions(tokenizer: tokenizer, prefix: prefix, weights: weights)
    }

    /// The options as the store caches them in `record_log_indexes.options`:
    /// `{tokenizer, prefix, weights, on, unbuilt?}`.
    var json: JSONValue {
        var object: [String: JSONValue] = [
            "tokenizer": .string(tokenizer.rawValue),
            "prefix": .array(prefix.map { .number(Double($0)) }),
            "weights": .object(weights.mapValues { .number($0) }),
        ]
        if let on { object["on"] = .string(on.rawValue) }
        if let unbuilt { object["unbuilt"] = .string(unbuilt) }
        return .object(object)
    }

    /// Options the store cached (``json``), or `nil` when they are not.
    init?(cached json: JSONValue?) {
        guard let object = json?.objectValue,
              let tokenizer = object["tokenizer"]?.stringValue.flatMap(RecordLogTextTokenizer.init(rawValue:))
        else { return nil }
        self.tokenizer = tokenizer
        prefix = object["prefix"]?.arrayValue?.compactMap(\.wholeNumber) ?? []
        weights = object["weights"]?.objectValue?.compactMapValues(\.numberValue) ?? [:]
        on = object["on"]?.stringValue.flatMap(Db3IndexPlacement.init(rawValue:))
        unbuilt = object["unbuilt"]?.stringValue
    }

    /// The canonical name of a model's text index on a local-only db3,
    /// `idx_text_<model>`, lowercased (`_<n>` is the caller's while it is taken).
    static func indexName(_ model: String) -> String {
        "idx_text_\(model)".lowercased()
    }
}

extension Db3TextIndexOptions {
    /// The options as a registration body carries them, each only when given:
    /// what ``RecordLogTextIndexOptions/parse(fields:raw:)`` checks.
    var json: JSONValue {
        var object: [String: JSONValue] = [:]
        if let tokenizer { object["tokenizer"] = .string(tokenizer.rawValue) }
        if let prefix { object["prefix"] = .array(prefix.map { .number(Double($0)) }) }
        if let weights { object["weights"] = .object(weights.mapValues { .number($0) }) }
        return .object(object)
    }
}

/// `$search`, the filter key a text index answers (#5223): its parser and
/// the MATCH text built from it over an index's FTS5 column aliases. The
/// Swift port of js-bao's `query/textSearch.ts`, so a `$search` builds the
/// same statement from the same input on either client.
///
/// - A `$search` is a string, read as `{ query }`, or `{ query, mode,
///   prefix, fields }`: `mode` `all` (the default) or `any`, `prefix`
///   matching every word as a prefix, `fields` a subset of the index's fields.
/// - The query is split into words on whitespace; a double-quoted run is one
///   phrase, and an unbalanced quote starts a phrase that runs to the end. A
///   `"` inside a word is part of the word.
/// - Each word or phrase is emitted as one FTS5 quoted string, every `"` in
///   it doubled, followed by `*` under `prefix`, and the strings are joined by
///   `AND` (`all`) or `OR` (`any`). Under `fields` the whole is restricted to
///   the named fields' columns with `{"f<i>" …} : (…)`. Nothing else of the
///   input reaches FTS5, and no application field name reaches it at all.
/// - A word or phrase with no letter, digit or private-use character (what
///   the tokenizers index) is dropped. A query left with none is refused.
enum RecordLogTextSearch {

    /// The filter key a text search is written under.
    static let key = "$search"

    /// How a search's words combine.
    enum Mode: String, Sendable {
        case all
        case any
    }

    /// One word or phrase of a search, as typed.
    struct Term: Equatable, Sendable {
        var text: String
        /// Whether it was a double-quoted phrase.
        var phrase: Bool
    }

    /// A `$search` parsed: its words and phrases, with every option filled in.
    struct Parsed: Equatable, Sendable {
        var terms: [Term]
        var mode: Mode
        var prefix: Bool
        /// The fields to search, or `nil` for every field of the index.
        var fields: [String]?
    }

    private static let searchKeys = ["query", "mode", "prefix", "fields"]

    private static func invalid(_ message: String) -> JsBaoError {
        JsBaoError(code: .invalidArgument, message: message)
    }

    /// Whether `filter` has `$search` among its top-level keys.
    static func has(_ filter: DocumentFilter?) -> Bool {
        filter?[key] != nil
    }

    /// JavaScript's `\s`: its white space and line terminators.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }

    /// A character the launch tokenizers index: a letter, a digit or a private-use character (FTS5's `L* N* Co`).
    private static func isTokenCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber, .privateUse:
            return true
        default:
            return false
        }
    }

    /// `scalars` without leading and trailing white space, each inner run of it one space.
    private static func collapsed(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var words: [String] = []
        var word = String.UnicodeScalarView()
        for scalar in scalars {
            if isSpace(scalar) {
                if !word.isEmpty { words.append(String(word)) }
                word = String.UnicodeScalarView()
            } else {
                word.append(scalar)
            }
        }
        if !word.isEmpty { words.append(String(word)) }
        return words.joined(separator: " ")
    }

    /// The words and phrases of `query`, in order.
    private static func terms(_ query: String) -> [Term] {
        // A NUL ends an FTS5 string early, and the tokenizers split words on
        // it, so it separates words here too.
        let scalars = Array(query.unicodeScalars.map { $0 == "\u{0}" ? " " : $0 })
        var terms: [Term] = []
        var i = 0
        while i < scalars.count {
            if isSpace(scalars[i]) {
                i += 1
                continue
            }
            if scalars[i] == "\"" {
                let end = scalars[(i + 1)...].firstIndex(of: "\"")
                terms.append(Term(text: collapsed(scalars[(i + 1)..<(end ?? scalars.count)]), phrase: true))
                i = end.map { $0 + 1 } ?? scalars.count
                continue
            }
            var end = i
            while end < scalars.count && !isSpace(scalars[end]) { end += 1 }
            var word = String.UnicodeScalarView()
            word.append(contentsOf: scalars[i..<end])
            terms.append(Term(text: String(word), phrase: false))
            i = end
        }
        return terms.filter { $0.text.unicodeScalars.contains(where: isTokenCharacter) }
    }

    /// A `$search` value, checked and parsed.
    ///
    /// - Throws: `JsBaoError(.invalidArgument)` with js-bao's message for a
    ///   value that is neither a string nor an object of the search's options,
    ///   an unknown option, an option of the wrong type, an empty `fields`, or
    ///   a query with no word to find.
    static func parse(_ value: JSONValue) throws -> Parsed {
        let search: [String: JSONValue]
        if let query = value.stringValue {
            search = ["query": .string(query)]
        } else if let object = value.objectValue {
            search = object
        } else {
            throw invalid("$search must be a string or { query, mode?, prefix?, fields? }")
        }
        if let unknown = search.keys.sorted().first(where: { !searchKeys.contains($0) }) {
            throw invalid("$search.\(unknown) is not a search option: give query, mode, prefix or fields")
        }
        guard let query = search["query"]?.stringValue else { throw invalid("$search.query must be a string") }
        let mode: Mode
        switch search["mode"] {
        case nil, .null?: mode = .all
        case .string(let given)?:
            guard let known = Mode(rawValue: given) else { throw invalid("$search.mode must be \"all\" or \"any\"") }
            mode = known
        default: throw invalid("$search.mode must be \"all\" or \"any\"")
        }
        if let prefix = search["prefix"], prefix.boolValue == nil { throw invalid("$search.prefix must be true or false") }
        var fields: [String]?
        if let given = search["fields"] {
            guard let list = given.arrayValue, !list.isEmpty, list.allSatisfy({ $0.stringValue != nil }) else {
                throw invalid("$search.fields must be a non-empty array of field names")
            }
            var seen = Set<String>()
            fields = list.compactMap(\.stringValue).filter { seen.insert($0).inserted }
        }
        let terms = terms(query)
        if terms.isEmpty { throw invalid("$search needs at least one word to find") }
        return Parsed(terms: terms, mode: mode, prefix: search["prefix"]?.boolValue == true, fields: fields)
    }

    /// A `$search` on `model`, which has no text index on this device:
    /// `JsBaoError(.queryIndexNotOnDevice)` with `details.model`.
    static func notOnDevice(model: String) -> JsBaoError {
        JsBaoError(
            code: .queryIndexNotOnDevice,
            message: "$search on \(model) needs a text index on this device: register one with kind: \"text\", on: \"device\"",
            details: ["model": .string(model)]
        )
    }

    /// A `$search` on `model` whose text index this device declined (#5322,
    /// js-bao's `DeviceIndexDeclinedError`): `JsBaoError(.db3IndexDeclinedOnDevice)`
    /// with `details` `{model, index, kind: "text"}`, naming `accept`.
    static func declined(model: String, index: String, reason: String) -> JsBaoError {
        JsBaoError(
            code: .db3IndexDeclinedOnDevice,
            message: "\(model)'s text index \(index) is not built on this device (\(reason)): accept it with "
                + "client.db3.indexes.accept(db3Id, name: \"\(index)\") to build it here, or query through the server",
            details: ["model": .string(model), "index": .string(index), "kind": "text"]
        )
    }

    /// The engine a refusal names: the Swift client's bundled SQLite.
    static let engine = "swift-sqlite"

    /// A `$search` on `model`, whose text index this device holds the entry of
    /// but no table for: `JsBaoError(.db3IndexPlacementUnsupported)` with
    /// `details` `{kind: "text", on, engine, reason}`.
    static func notBuilt(model: String, on: Db3IndexPlacement?, reason: String) -> JsBaoError {
        JsBaoError(
            code: .db3IndexPlacementUnsupported,
            message: "\(model)'s text index is not built on this device (\(engine)): \(reason)",
            details: [
                "kind": "text", "on": .string((on ?? .device).rawValue), "engine": .string(engine), "reason": .string(reason),
            ]
        )
    }

    /// `text` as one FTS5 string: quoted, every `"` doubled.
    private static func quoted(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// The MATCH text of `search` over an index of `indexFields`: quoted words
    /// and phrases only, with `*` under `prefix`, joined by `AND` or `OR`, and
    /// under `fields` restricted to their quoted column aliases.
    ///
    /// - Throws: `JsBaoError(.invalidArgument)` naming a `fields` entry the index does not cover.
    static func match(_ search: Parsed, indexFields: [String]) throws -> String {
        let joined = search.terms.map { quoted($0.text) + (search.prefix ? "*" : "") }
            .joined(separator: search.mode == .any ? " OR " : " AND ")
        guard let fields = search.fields else { return joined }
        let selected = try fields.map { field -> String in
            guard let index = indexFields.firstIndex(of: field) else {
                throw invalid(
                    "$search.fields names \(field), which the text index does not cover: \(indexFields.joined(separator: ", "))"
                )
            }
            return quoted(RecordLogIndexes.textColumn(index))
        }
        return "{\(selected.joined(separator: " "))} : (\(joined))"
    }
}
