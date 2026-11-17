import Foundation
import TOMLKit

/// A db3 field's `ref` to a shared enum (#5545): a plain string enum under
/// `[defs.<Name>]` in a `schemas/` file, expanded into `type = "string"`,
/// `enum = [...]` before the field is read; or, when `objects` asks for it
/// (#5899), to an object def, expanded into a plain `type = "string"` field
/// stored as canonical JSON text, the def named beside it. Mirrored by hand
/// from js-bao's `models/sharedEnums.ts`, sentence for sentence.
struct SharedEnums {
    /// The directory, as a refusal names it.
    let dir: String
    /// The other families' keys, for the `<key>.<Name>` pair rule.
    let db3: [String], function: [String], prompt: [String]
    /// Whether a ref may name an object def too (#5899): the tool's own
    /// inputs ask; a reader that does not keeps today's results.
    let objects: Bool
    /// Each readable `schemas/` file's defs, and each unreadable one's first error line, by stem.
    private var defs: [String: TOMLTable] = [:], unreadable: [String: String] = [:]
    private let missing: Bool

    /// The keys a shared enum def may carry beside `type` and `enum`.
    static let annotationKeys = ["description", "title", "examples", "deprecated", "$comment"]

    private struct Refusal: Error { let message: String }

    /// What a ref resolved to: a shared enum and its values, or an object def.
    private enum Resolved {
        case enumeration(SharedEnumRef, [String])
        case object(Db3JSONRef)
    }

    /// `files` as `(stem, text)`, or `nil` when `dir` does not exist.
    init(files: [(String, String)]?, dir: String, db3: [String] = [], function: [String] = [], prompt: [String] = [], objects: Bool = false) {
        (self.dir, self.db3, self.function, self.prompt, self.objects, missing) = (dir, db3, function, prompt, objects, files == nil)
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

    /// What a db3 field may ref, as the refusals name it.
    private var kinds: String { objects ? "a shared enum or an object def" : "a shared enum" }

    /// The def a ref names, with its values when it is a shared enum; throws the refusal's sentence.
    private func resolve(_ ref: TOMLValue) throws -> Resolved {
        let fail = { (message: String) in Refusal(message: message) }
        if let text = ref.string, let hash = text.firstIndex(of: "#") {
            throw fail("a projection (\(text[hash...])) applies to a db3 model ref and \(kinds) has none; drop the suffix.")
        }
        let parts = ref.string.map { $0.split(separator: ".", omittingEmptySubsequences: false).map(String.init) } ?? []
        if parts.first == "platform" { throw fail(#"the platform prefix is reserved; name \#(kinds) in schemas/ as "schemas.<file>.<Name>"."#) }
        let word = { (part: String) in !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") } }
        guard parts.count == 1 || parts.count == 2 || (parts.count == 3 && parts[0] == "schemas"), parts.allSatisfy(word) else {
            throw fail(#"a db3 field refs only \#(kinds) in schemas/; write "<Name>", "<file>.<Name>" or "schemas.<file>.<Name>"."#)
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

    private func inFile(_ file: String, _ name: String) throws -> Resolved {
        let source = "schemas/\(file).toml"
        if let line = unreadable[file] { throw Refusal(message: "\(source) could not be read (\(line)); fix the file.") }
        guard let table = defs[file] else {
            throw Refusal(message: #"there is no \#(source); a db3 field refs only \#(kinds) in schemas/, so fix the file name or write "schemas.<file>.\#(name)"."#)
        }
        guard let def = table[name] else {
            let names = table.keys.isEmpty ? "" : " (it declares \(table.keys.sorted().joined(separator: ", ")))"
            throw Refusal(message: "\(source) declares no \(name)\(names); fix the name, or add [defs.\(name)] there.")
        }
        do {
            return .enumeration(SharedEnumRef(file: file, name: name), try Self.sharedEnumValues(def.table ?? TOMLTable()))
        } catch let what as Refusal {
            if objects, isObjectDef(file, def.table, seen: ["\(file).\(name)"]) { return .object(Db3JSONRef(file: file, name: name)) }
            if objects {
                throw Refusal(message: "\(source)#\(name) is neither a shared enum nor an object def: it declares \(what.message); a db3 field refs a def with "
                    + #"type = "string" and a non-empty enum of distinct strings, or a def with type = "object" (to store an array, wrap it in an object def)."#)
            }
            throw Refusal(message: "\(source)#\(name) is not a shared enum: it declares \(what.message); a db3 field refs only a def with type = \"string\" and a non-empty enum of distinct strings.")
        }
    }

    /// The keys the compiler keeps beside a root ref it inlines without changing the root's type: annotations only.
    private static let rootAliasSiblings: Set<String> = ["description", "title", "examples", "deprecated", "$comment"]

    /// The `schemas/` def a def's root ref names, as the compiler inlines it,
    /// or nil: `"$ref" = "#/$defs/<Name>"`, `"$ref" = "schemas:<file>#/$defs/<Name>"`,
    /// or `ref = "<Name>"`, `"<file>.<Name>"`, `"schemas.<file>.<Name>"`, with
    /// nothing beside it but annotations.
    private func rootRefTarget(_ file: String, _ def: TOMLTable) -> (file: String, name: String)? {
        let keys = def.keys.filter { !Self.rootAliasSiblings.contains($0) }
        guard keys.count == 1, let value = def[keys[0]]?.string else { return nil }
        let declares = { (stem: String, name: String) in defs[stem]?[name] != nil }
        let found = { (stem: String, name: String) -> (file: String, name: String)? in declares(stem, name) ? (stem, name) : nil }
        if keys[0] == "$ref" {
            let pattern = try! NSRegularExpression(pattern: #"^(?:schemas:([a-z0-9_-]{1,64}))?#/\$defs/([^/]+)$"#)
            let whole = NSRange(value.startIndex..., in: value)
            guard let match = pattern.firstMatch(in: value, range: whole), let nameRange = Range(match.range(at: 2), in: value) else { return nil }
            let name = String(value[nameRange]).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            let stem = Range(match.range(at: 1), in: value).map { String(value[$0]) } ?? file
            return found(stem, name)
        }
        guard keys[0] == "ref", !value.contains("#") else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, parts[0] == "schemas" { return found(parts[1], parts[2]) }
        if parts.count == 2 { return found(parts[0], parts[1]) }
        guard parts.count == 1 else { return nil }
        let files = defs.keys.filter { declares($0, parts[0]) }
        return files.count == 1 ? (files[0], parts[0]) : nil
    }

    /// Whether a def's root compiles to an object, as the compiler reads it:
    /// `type = "object"`, a field table with `fields` and no type, or a root
    /// ref (with only annotations beside it) to a def that does.
    private func isObjectDef(_ file: String, _ def: TOMLTable?, seen: Set<String>) -> Bool {
        guard let def else { return false }
        if def["type"]?.string == "object" || (def["type"] == nil && def["fields"] != nil) { return true }
        guard let target = rootRefTarget(file, def), !seen.contains("\(target.file).\(target.name)") else { return false }
        return isObjectDef(target.file, defs[target.file]?[target.name]?.table, seen: seen.union(["\(target.file).\(target.name)"]))
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

    /// Why each key a db3 field may carry cannot sit beside a ref to an object def.
    private static let besideObjectRef: [String: String] = [
        "type": "the field is stored as JSON text in a string field",
        "enum": "the def declares the value's shape",
        "indexed": "an index on JSON text neither orders nor matches the values inside it",
        "unique": "uniqueness of JSON text is not uniqueness of the values inside it",
        "default": "a JSON field has no default",
        "max_length": "bound the value in the def (maxLength, maxItems) instead",
        "max_count": "it bounds a stringset field",
        "auto_assign": "the client writes a JSON field's value",
        "auto_stamp": "the client writes a JSON field's value",
        "dims": "it shapes a vector field",
        "element": "it shapes a vector field",
    ]

    /// Expand every field `ref` of a parsed type document in place, and
    /// answer the def each one named, by model then field (#5896).
    @discardableResult
    func expand(_ document: TOMLTable) throws -> [String: [String: SharedEnumRef]] {
        try expandAll(document).enums
    }

    /// Expand every field `ref` of a parsed type document in place, and
    /// answer the shared enum each enum ref named and the object def each
    /// JSON field's ref named (#5899), by model then field.
    func expandAll(_ document: TOMLTable) throws -> (enums: [String: [String: SharedEnumRef]], json: [String: [String: Db3JSONRef]]) {
        var named: [String: [String: SharedEnumRef]] = [:]
        var json: [String: [String: Db3JSONRef]] = [:]
        /// Each JSON field's ref as written, for a unique constraint's refusal.
        var refs: [String: [String: String]] = [:]
        guard let models = document["models"]?.table else { return (named, json) }
        let typed = document["type"]?.table != nil
        for model in models.keys {
            guard let fields = models[model]?.table?["fields"]?.table else { continue }
            for field in fields.keys {
                guard let table = fields[field]?.table, let ref = table["ref"]?.tomlValue else { continue }
                let prefix = "[models.\(model).fields.\(field)]: ref \(Self.json(ref)): "
                let beside = ["type", "enum"].filter { table[$0] != nil }
                let (it, them) = beside.count > 1 ? ("both", "them") : ("it", "it")
                let enumBeside = CodegenError.sharedEnumRef(message: "\(prefix)\(beside.joined(separator: " and ")) cannot sit beside ref; the shared enum supplies \(it), so remove \(them).")
                // A resolver that never admits object defs refuses type or enum before resolving, as it always has.
                if !objects, !beside.isEmpty { throw enumBeside }
                let resolved: Resolved
                do {
                    resolved = try resolve(ref)
                } catch let refusal as Refusal {
                    if !beside.isEmpty { throw enumBeside }
                    throw CodegenError.sharedEnumRef(message: prefix + refusal.message)
                }
                switch resolved {
                case let .object(def):
                    // A JSON field (#5899): stored as a plain string field, its def named beside it for code generators only.
                    if let key = table.keys.first(where: { $0 != "ref" && $0 != "required" }) {
                        let why = Self.besideObjectRef[key] ?? "only required may"
                        throw CodegenError.sharedEnumRef(message: "\(prefix)\(key) cannot sit beside a ref to an object def: \(why), so remove it.")
                    }
                    guard typed else {
                        throw CodegenError.sharedEnumRef(message: prefix
                            + #"a ref to an object def belongs to a db3 type file, one with a [type] table; add [type] to the file, or declare the field type = "string"."#)
                    }
                    refs[model, default: [:]][field] = Self.json(ref)
                    table.remove(at: "ref")
                    table["type"] = "string"
                    json[model, default: [:]][field] = def
                case let .enumeration(def, values):
                    if !beside.isEmpty { throw enumBeside }
                    table.remove(at: "ref")
                    table["type"] = "string"
                    table["enum"] = TOMLArray(values)
                    named[model, default: [:]][field] = def
                }
            }
            // A unique constraint naming a JSON field (#5899), as the CLI refuses it.
            guard let jsonFields = json[model], let constraints = models[model]?.table?["unique_constraints"]?.array else { continue }
            for index in 0..<constraints.count {
                guard let constraint = constraints[index].table, let names = constraint["fields"]?.array else { continue }
                let listed = (0..<names.count).compactMap { names[$0].string }
                guard let field = listed.first(where: { jsonFields[$0] != nil }), let ref = refs[model]?[field] else { continue }
                let name = constraint["name"].map { Self.json($0.tomlValue) } ?? "undefined"
                throw CodegenError.sharedEnumRef(message: "[[models.\(model).unique_constraints]] \(name) names \(field), a JSON field (ref \(ref)): "
                    + "uniqueness of JSON text is not uniqueness of the values inside it, so remove the field from the constraint.")
            }
        }
        return (named, json)
    }
}
