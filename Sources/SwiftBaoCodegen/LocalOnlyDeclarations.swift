import CryptoKit
import Foundation
import TOMLKit

/// A JSON value as JavaScript's `JSON.stringify` prints it, with object keys
/// in code-unit order: the canonical text a db3 type's content hash is taken
/// over. `number` holds the number's JavaScript text.
indirect enum CanonicalJSON: Equatable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([CanonicalJSON])
    case object([String: CanonicalJSON])

    /// The value's text: keys sorted by UTF-16 code unit, as js-bao's `stableJson` sorts them.
    var text: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let text): return text
        case .string(let value): return Self.quote(value)
        case .array(let items): return "[" + items.map(\.text).joined(separator: ",") + "]"
        case .object(let members):
            let keys = members.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            return "{" + keys.map { Self.quote($0) + ":" + members[$0]!.text }.joined(separator: ",") + "}"
        }
    }

    /// `text` quoted as `JSON.stringify` quotes it: `"` and `\` escaped,
    /// `\b \f \n \r \t` by name, other code units below U+0020 as `\u00xx`.
    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// `value` as JavaScript's `Number.prototype.toString` prints it: the
    /// shortest digits that read back as the same double, in decimal from
    /// 1e-7 up to 1e21 and in exponent form outside.
    static func jsNumber(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value < 0 { return "-" + jsNumber(-value) }
        // Swift's description holds the same shortest round-trip digits; only the layout differs.
        let described = value.description
        let parts = described.lowercased().split(separator: "e", maxSplits: 1).map(String.init)
        let mantissa = parts[0]
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let pieces = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let whole = pieces[0]
        let fraction = pieces.count > 1 ? pieces[1] : ""
        var digits = whole + fraction
        // The decimal point sits after `point` digits of `digits`.
        var point = whole.count + exponent
        while digits.hasPrefix("0") && digits.count > 1 {
            digits.removeFirst()
            point -= 1
        }
        while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
        let k = digits.count
        let n = point
        if k <= n && n <= 21 { return digits + String(repeating: "0", count: n - k) }
        if 0 < n && n <= 21 {
            let at = digits.index(digits.startIndex, offsetBy: n)
            return String(digits[..<at]) + "." + String(digits[at...])
        }
        if -6 < n && n <= 0 { return "0." + String(repeating: "0", count: -n) + digits }
        let e = n - 1
        let sign = e < 0 ? "-" : "+"
        let head = String(digits.prefix(1))
        let rest = String(digits.dropFirst())
        return head + (rest.isEmpty ? "" : "." + rest) + "e" + sign + String(abs(e))
    }
}

/// One opted-in type's declarations as a build embeds them: the models in
/// install shape, as canonical JSON text, and their content hash.
struct LocalOnlyTypeDeclarations: Equatable {
    var hash: String
    var modelsJSON: String
}

/// The declarations a build carries for each db3 type that allows local-only
/// db3s (`[type] allowLocalOnly = true`), computed as js-bao-codegen-v2
/// computes them (`cli/v2/localOnly.ts`): the type's models, with their
/// shared-enum refs expanded and the models `[type] models` names copied in,
/// read as js-bao's schema loader reads a model field, keyed by stored
/// names, in install shape, and the SHA-256 of `{ hooks: {}, models }` as
/// canonical JSON. The hash equals the revision hash the server answers for
/// the same pushed file.
enum LocalOnlyDeclarations {

    /// A refusal of an opted-in type file, naming it.
    static func refusal(_ message: String) -> CodegenError { .localOnlyType(message: message) }

    /// Per type name, the declarations of each input type file that says
    /// `[type] allowLocalOnly = true`. Throws naming the file when one
    /// declares a hook, names in `[type] models` a model no input declares,
    /// or holds a default whose JSON text Swift cannot print as js-bao
    /// does (a date-time at offset zero, a time finer than a millisecond, an
    /// integer beyond 2^53, a number that is not finite).
    static func of(
        documents: [(sourceName: String, source: String)], sharedEnums: [SharedEnums?]? = nil
    ) throws -> [String: LocalOnlyTypeDeclarations] {
        var parsed: [(sourceName: String, table: TOMLTable, typeName: String)] = []
        for (position, document) in documents.enumerated() {
            guard let table = try? TOMLTable(string: document.source), let type = table["type"]?.table else { continue }
            if position < (sharedEnums?.count ?? 0), let resolver = sharedEnums![position] {
                _ = try? resolver.expandAll(table)
            }
            let declared = type["name"]?.string ?? ""
            let stem = ((document.sourceName as NSString).lastPathComponent as NSString).deletingPathExtension
            parsed.append((document.sourceName, table, declared.isEmpty ? stem : declared))
        }
        let opted = parsed.filter { $0.table["type"]?.table?["allowLocalOnly"]?.bool == true }
        guard !opted.isEmpty else { return [:] }
        // Every type file's models, the first declaration kept, for `[type] models = [...]`.
        var shared: [String: TOMLTable] = [:]
        for file in parsed {
            guard let models = file.table["models"]?.table else { continue }
            for name in models.keys where shared[name] == nil {
                if let model = models[name]?.table { shared[name] = model }
            }
        }
        var out: [String: LocalOnlyTypeDeclarations] = [:]
        for file in opted {
            let hooks = hooksOf(file.table)
            if !hooks.isEmpty {
                throw refusal(
                    "\(file.sourceName): [type] allowLocalOnly = true cannot be set beside \(hooks.joined(separator: ", ")): a type that allows "
                        + "local-only db3s takes no hooks, because a device runs none. Remove \(hooks.count == 1 ? "it" : "them"), "
                        + "or declare the hooks on a second type."
                )
            }
            var models: [String: TOMLTable] = [:]
            if let own = file.table["models"]?.table {
                for name in own.keys { if let model = own[name]?.table { models[name] = model } }
            }
            if let listed = file.table["type"]?.table?["models"]?.array {
                for position in 0..<listed.count {
                    guard let name = listed[position].string, models[name] == nil else { continue }
                    guard let model = shared[name] else {
                        throw refusal(
                            "\(file.sourceName): [type] models names \"\(name)\", but no input type file declares it. A type that allows "
                                + "local-only db3s embeds every model it holds, so generate it together with the file that declares "
                                + "\"\(name)\" (pass both to --input, or their db3-types directory)."
                        )
                    }
                    models[name] = model
                }
            }
            var declared: [String: DeclaredModel] = [:]
            for (name, model) in models {
                declared[name] = try declaredModel(model, modelName: name, file: file.sourceName)
            }
            let installed = installModels(storedKeyed(declared))
            let modelsJSON = CanonicalJSON.object(installed).text
            let hashed = "{\"hooks\":{},\"models\":\(modelsJSON)}"
            let digest = SHA256.hash(data: Data(hashed.utf8))
            out[file.typeName] = LocalOnlyTypeDeclarations(
                hash: digest.map { String(format: "%02x", $0) }.joined(), modelsJSON: modelsJSON
            )
        }
        return out
    }

    /// The hooks a type document declares, as the server counts them: a
    /// non-empty `[triggers]` table, a non-empty `[type] autoPopulatedFields`,
    /// and `[type] timestamps` naming `create` or `update`.
    static func hooksOf(_ document: TOMLTable) -> [String] {
        var hooks: [String] = []
        if let triggers = document["triggers"]?.table, !triggers.keys.isEmpty { hooks.append("triggers") }
        let type = document["type"]?.table
        if let auto = type?["autoPopulatedFields"]?.table, !auto.keys.isEmpty { hooks.append("autoPopulatedFields") }
        if let stamps = type?["timestamps"]?.table, stamps["create"] != nil || stamps["update"] != nil { hooks.append("timestamps") }
        return hooks
    }

    /// A model as js-bao's loader reads it: each field's options, the
    /// compound unique constraints by name, and the tombstoned names.
    struct DeclaredModel {
        var fields: [String: [String: CanonicalJSON]]
        var constraints: [String: [String]]?
        var removedFields: [String]?
    }

    /// Model `table` read as js-bao's loader reads a model field in a type
    /// file: `type`; a vector's `dims` and `element`; `indexed`, `unique`,
    /// `required`, `autoAssign`, `enforceEnum`, `deprecated` and `cleared`
    /// only when `true`; `autoStamp`, `maxLength`, `maxCount`, `default` and
    /// `enum` as written; `storedAs` when it names another name.
    static func declaredModel(_ table: TOMLTable, modelName: String, file: String) throws -> DeclaredModel {
        var fields: [String: [String: CanonicalJSON]] = [:]
        if let declared = table["fields"]?.table {
            for name in declared.keys {
                guard let field = declared[name]?.table else { continue }
                let context = "\(file): [models.\(modelName).fields.\(name)]"
                var options: [String: CanonicalJSON] = [:]
                let type = field["type"]?.string ?? ""
                options["type"] = .string(type)
                if type == "vector" {
                    if let dims = field["dims"] { options["dims"] = try json(dims.tomlValue, context) }
                    if let element = field["element"] { options["element"] = try json(element.tomlValue, context) }
                }
                for (key, prop) in [("indexed", "indexed"), ("unique", "unique"), ("required", "required"), ("auto_assign", "autoAssign")]
                where field[key]?.bool == true {
                    options[prop] = .bool(true)
                }
                for (key, prop) in [("auto_stamp", "autoStamp"), ("max_length", "maxLength"), ("max_count", "maxCount"), ("default", "default")] {
                    if let value = field[key] { options[prop] = try json(value.tomlValue, context) }
                }
                if let values = field["enum"] { options["enum"] = try json(values.tomlValue, context) }
                for (key, prop) in [("enforce_enum", "enforceEnum"), ("deprecated", "deprecated"), ("cleared", "cleared")]
                where field[key]?.bool == true {
                    options[prop] = .bool(true)
                }
                if let stored = field["storedAs"]?.string, stored != name { options["storedAs"] = .string(stored) }
                fields[name] = options
            }
        }
        var constraints: [String: [String]] = [:]
        if let list = table["unique_constraints"]?.array {
            for position in 0..<list.count {
                guard let constraint = list[position].table, let name = constraint["name"]?.string,
                      let names = constraint["fields"]?.array else { continue }
                constraints[name] = (0..<names.count).compactMap { names[$0].string }
            }
        }
        let removed = table["removedFields"]?.array.map { list in (0..<list.count).compactMap { list[$0].string } }
        return DeclaredModel(
            fields: fields, constraints: constraints.isEmpty ? nil : constraints, removedFields: (removed?.isEmpty ?? true) ? nil : removed
        )
    }

    /// `models` keyed by stored names when any field is renamed, as the
    /// server keys a type's install: each field under its stored name
    /// without `storedAs`, constraint fields and `removedFields` by stored
    /// name. A build knows no former names, so only current and stored names map.
    static func storedKeyed(_ models: [String: DeclaredModel]) -> [String: DeclaredModel] {
        let stored = { (key: String, options: [String: CanonicalJSON]) -> String in
            if case .string(let name)? = options["storedAs"], !name.isEmpty { return name }
            return key
        }
        guard models.values.contains(where: { $0.fields.contains { stored($0.key, $0.value) != $0.key } }) else { return models }
        var out: [String: DeclaredModel] = [:]
        for (name, model) in models {
            var accepted: [String: String] = [:]
            var fields: [String: [String: CanonicalJSON]] = [:]
            for (key, options) in model.fields {
                let storedName = stored(key, options)
                accepted[storedName] = storedName
                accepted[key] = storedName
                var rest = options
                rest["storedAs"] = nil
                fields[storedName] = rest
            }
            let toStored = { (field: String) in accepted[field] ?? field }
            var removed: [String]?
            if let names = model.removedFields {
                var seen = Set<String>()
                removed = names.map(toStored).filter { seen.insert($0).inserted }
            }
            out[name] = DeclaredModel(
                fields: fields, constraints: model.constraints?.mapValues { $0.map(toStored) }, removedFields: removed
            )
        }
        return out
    }

    /// The declarations a room installs, as canonical JSON per model: a
    /// cleared field leaves `fields` and joins the sorted `cleared` list with
    /// every `removedFields` name, `deprecated` is dropped, and a constraint
    /// over a single hidden name goes with the field.
    static func installModels(_ models: [String: DeclaredModel]) -> [String: CanonicalJSON] {
        var installed: [String: CanonicalJSON] = [:]
        for (name, model) in models {
            var fields: [String: CanonicalJSON] = [:]
            var cleared = Set(model.removedFields ?? [])
            for (field, options) in model.fields {
                if options["cleared"] == .bool(true) {
                    cleared.insert(field)
                    continue
                }
                var kept = options
                kept["deprecated"] = nil
                fields[field] = .object(kept)
            }
            var object: [String: CanonicalJSON] = ["fields": .object(fields)]
            var constraints: [String: CanonicalJSON] = [:]
            for (cname, names) in model.constraints ?? [:] {
                if names.count == 1, cleared.contains(names[0]) { continue }
                constraints[cname] = .object(["type": .string("unique"), "fields": .array(names.map { .string($0) })])
            }
            if !constraints.isEmpty { object["constraints"] = .object(constraints) }
            if !cleared.isEmpty {
                object["cleared"] = .array(cleared.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }.map { .string($0) })
            }
            installed[name] = .object(object)
        }
        return installed
    }

    /// A TOML value as js-bao embeds it: what `JSON.stringify` prints for the
    /// value smol-toml reads, a date as its `toISOString`. Throws for a value
    /// Swift cannot print the same way.
    static func json(_ value: TOMLValue, _ context: String) throws -> CanonicalJSON {
        switch value.type {
        case .string: return .string(value.string ?? "")
        case .bool: return .bool(value.bool ?? false)
        case .int:
            let int = value.int ?? 0
            guard abs(int) <= 9_007_199_254_740_991 else {
                throw refusal("\(context): the integer \(int) is beyond 2^53, which JavaScript reads as another number; write it as a string")
            }
            return .number(String(int))
        case .double:
            let double = value.double ?? 0
            guard double.isFinite else {
                throw refusal("\(context): \(double) is not a finite number, which a type that allows local-only db3s cannot embed")
            }
            return .number(CanonicalJSON.jsNumber(double))
        case .array:
            let array = value.array!
            return .array(try (0..<array.count).map { try json(array[$0].tomlValue, context) })
        case .table:
            let table = value.table!
            var members: [String: CanonicalJSON] = [:]
            for key in table.keys { if let member = table[key] { members[key] = try json(member.tomlValue, context) } }
            return .object(members)
        case .date:
            return .string(dateText(value.date!))
        case .time:
            return .string(try timeText(value.time!, context))
        case .dateTime:
            let dateTime = value.dateTime!
            let local = dateText(dateTime.date) + "T" + (try timeText(dateTime.time, context))
            guard let offset = dateTime.offset else { return .string(local) }
            // TOML's `Z` and `+00:00` both read as offset 0 here, but js-bao prints them apart.
            guard offset.offset != 0 else {
                throw refusal(
                    "\(context): a date-time at offset zero (Z or +00:00) cannot be embedded the way js-bao embeds it; "
                        + "write the default as a string, such as \"\(local)Z\""
                )
            }
            let minutes = abs(offset.offset)
            return .string(local + (offset.offset < 0 ? "-" : "+") + pad(minutes / 60, 2) + ":" + pad(minutes % 60, 2))
        }
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    private static func dateText(_ date: TOMLDate) -> String {
        pad(date.year, 4) + "-" + pad(date.month, 2) + "-" + pad(date.day, 2)
    }

    /// `HH:MM:SS.mmm`, as a JavaScript date's ISO text holds a time.
    private static func timeText(_ time: TOMLTime, _ context: String) throws -> String {
        guard time.nanoSecond % 1_000_000 == 0 else {
            throw refusal("\(context): a time finer than a millisecond cannot be embedded the way js-bao embeds it; write the default as a string")
        }
        return pad(time.hour, 2) + ":" + pad(time.minute, 2) + ":" + pad(time.second, 2) + "." + pad(time.nanoSecond / 1_000_000, 3)
    }
}
