import Foundation
import TOMLKit

/// A db3 field's `ref` to a shared enum (#5545): a plain string enum under
/// `[defs.<Name>]` in a `schemas/` file, expanded into `type = "string"`,
/// `enum = [...]` before the field is read. Mirrored by hand from js-bao's
/// `models/sharedEnums.ts`, sentence for sentence.
struct SharedEnums {
    /// The directory, as a refusal names it.
    let dir: String
    /// The other families' keys, for the `<key>.<Name>` pair rule.
    let db3: [String], function: [String], prompt: [String]
    /// Each readable `schemas/` file's defs, and each unreadable one's first error line, by stem.
    private var defs: [String: TOMLTable] = [:], unreadable: [String: String] = [:]
    private let missing: Bool

    /// The keys a shared enum def may carry beside `type` and `enum`.
    static let annotationKeys = ["description", "title", "examples", "deprecated", "$comment"]

    private struct Refusal: Error { let message: String }

    /// `files` as `(stem, text)`, or `nil` when `dir` does not exist.
    init(files: [(String, String)]?, dir: String, db3: [String] = [], function: [String] = [], prompt: [String] = []) {
        (self.dir, self.db3, self.function, self.prompt, missing) = (dir, db3, function, prompt, files == nil)
        for (stem, text) in files ?? [] {
            do {
                defs[stem] = try TOMLTable(string: text)["defs"]?.table ?? TOMLTable()
            } catch {
                unreadable[stem] = String(describing: error).split(separator: "\n").first.map(String.init) ?? ""
            }
        }
    }

    /// The stems read, in name order.
    var stems: [String] { (Array(defs.keys) + Array(unreadable.keys)).sorted() }

    /// The enum's values in the def's order; throws the refusal's sentence.
    private func resolve(_ ref: TOMLValue) throws -> [String] {
        let fail = { (message: String) in Refusal(message: message) }
        if let text = ref.string, let hash = text.firstIndex(of: "#") {
            throw fail("a projection (\(text[hash...])) applies to a db3 model ref and a shared enum has none; drop the suffix.")
        }
        let parts = ref.string.map { $0.split(separator: ".", omittingEmptySubsequences: false).map(String.init) } ?? []
        if parts.first == "platform" { throw fail(#"the platform prefix is reserved; name a shared enum in schemas/ as "schemas.<file>.<Name>"."#) }
        let word = { (part: String) in !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") } }
        guard parts.count == 1 || parts.count == 2 || (parts.count == 3 && parts[0] == "schemas"), parts.allSatisfy(word) else {
            throw fail(#"a db3 field refs only a shared enum in schemas/; write "<Name>", "<file>.<Name>" or "schemas.<file>.<Name>"."#)
        }
        let name = parts[parts.count - 1]
        if missing { throw fail("no \(dir) directory was found; add one beside db3-types/ declaring [defs.\(name)].") }
        if parts.count > 1 {
            let key = parts[parts.count - 2]
            let families = parts.count == 2 ? [("db3", db3), ("fn", function), ("prompt", prompt)].filter { $0.1.contains(key) }.map(\.0) : []
            guard !families.isEmpty, stems.contains(key) else { return try inFile(key, name) }
            let longs = (families.map { "\($0).\(key).\(name)" } + ["schemas.\(key).\(name)"]).sorted()
            throw fail("\(key) is a key in more than one family; use a long form: \(longs.joined(separator: ", ")).")
        }
        let found = defs.keys.sorted().filter { defs[$0]![name] != nil }
        if found.count > 1 {
            throw fail("more than one schemas/ file declares \(name); use a long form: \(found.map { "schemas.\($0).\(name)" }.joined(separator: ", ")).")
        }
        if let file = found.first { return try inFile(file, name) }
        let note = unreadable.isEmpty ? "" : " (\(unreadable.keys.sorted().map { "schemas/\($0).toml" }.joined(separator: ", ")) could not be read)"
        throw fail("no schemas/ file declares \(name); fix the name, or add [defs.\(name)] to a schemas/ file\(note).")
    }

    private func inFile(_ file: String, _ name: String) throws -> [String] {
        let source = "schemas/\(file).toml"
        if let line = unreadable[file] { throw Refusal(message: "\(source) could not be read (\(line)); fix the file.") }
        guard let table = defs[file] else {
            throw Refusal(message: #"there is no \#(source); a db3 field refs only a shared enum in schemas/, so fix the file name or write "schemas.<file>.\#(name)"."#)
        }
        guard let def = table[name] else {
            let names = table.keys.isEmpty ? "" : " (it declares \(table.keys.sorted().joined(separator: ", ")))"
            throw Refusal(message: "\(source) declares no \(name)\(names); fix the name, or add [defs.\(name)] there.")
        }
        do {
            return try Self.sharedEnumValues(def.table ?? TOMLTable())
        } catch let what as Refusal {
            throw Refusal(message: "\(source)#\(name) is not a shared enum: it declares \(what.message); a db3 field refs only a def with type = \"string\" and a non-empty enum of distinct strings.")
        }
    }

    /// The def's values; throws what keeps it from being a shared enum.
    private static func sharedEnumValues(_ def: TOMLTable) throws -> [String] {
        guard def["type"]?.string == "string" else { throw Refusal(message: def["type"].map { "type = \(json($0.tomlValue))" } ?? "no type") }
        if let extra = def.keys.sorted().first(where: { !["type", "enum"].contains($0) && !annotationKeys.contains($0) }) {
            throw Refusal(message: extra)
        }
        guard let list = def["enum"] else { throw Refusal(message: "no enum") }
        guard let array = list.array else { throw Refusal(message: "an enum that is not a list") }
        guard array.count > 0 else { throw Refusal(message: "an empty enum") }
        let values = (0..<array.count).compactMap { array[$0].string }
        guard values.count == array.count else { throw Refusal(message: "a non-string enum member") }
        if let repeated = values.enumerated().first(where: { values.firstIndex(of: $0.element) != $0.offset }) {
            throw Refusal(message: "an enum that repeats a value (\(json(repeated.element.tomlValue)))")
        }
        return values
    }

    /// A TOML value as JSON prints it, for a refusal naming it.
    private static func json(_ value: TOMLValue) -> String {
        if let text = value.string { return "\"\(text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }
        if let bool = value.bool { return bool ? "true" : "false" }
        return value.int.map(String.init) ?? value.debugDescription
    }

    /// Expand every field `ref` of a parsed type document in place.
    func expand(_ document: TOMLTable) throws {
        guard let models = document["models"]?.table else { return }
        for model in models.keys {
            guard let fields = models[model]?.table?["fields"]?.table else { continue }
            for field in fields.keys {
                guard let table = fields[field]?.table, let ref = table["ref"]?.tomlValue else { continue }
                let prefix = "[models.\(model).fields.\(field)]: ref \(Self.json(ref)): "
                let beside = ["type", "enum"].filter { table[$0] != nil }
                let (it, them) = beside.count > 1 ? ("both", "them") : ("it", "it")
                if !beside.isEmpty {
                    throw CodegenError.sharedEnumRef(message: "\(prefix)\(beside.joined(separator: " and ")) cannot sit beside ref; the shared enum supplies \(it), so remove \(them).")
                }
                do {
                    let values = try resolve(ref)
                    table.remove(at: "ref")
                    table["type"] = "string"
                    table["enum"] = TOMLArray(values)
                } catch let refusal as Refusal {
                    throw CodegenError.sharedEnumRef(message: prefix + refusal.message)
                }
            }
        }
    }
}
