import XCTest
@testable import JsBaoClient

/// Cross-platform parity test for the TOML schema loader.
///
/// Shape: both `TomlSchemaLoader` (Swift) and `loadSchemaFromTomlString`
/// (js-bao, via the Node subprocess) load the SAME fixture file and we
/// normalize each output into a canonical comparable structure. Any
/// divergence means the two loaders disagree on the schema — a client
/// authored by one language could produce `_meta_*` bytes or enforce
/// uniqueness differently from the other.
///
/// We normalize because the two outputs have different in-memory
/// shapes:
///   - Swift: `PrimitiveSchema { name, fields, constraints, relationships }`
///   - JS:    `{ name, fields, options: { uniqueConstraints, relationships } }`
///
/// The normalized form flattens this into a plain dictionary keyed by
/// model name, so we can compare them field-by-field without caring
/// about structural shape.
///
/// Skips (via XCTSkip) if Node or the js-bao subprocess isn't
/// available — the test is a superset gate, not a baseline requirement.
final class CrossPlatformTomlSchemaParityTests: XCTestCase {

    /// The canonical normalized schema. Both the Swift side and the
    /// JS side are converted into this shape before we compare.
    private struct NormalizedSchema: Equatable, CustomStringConvertible {
        var name: String
        var fields: [String: NormalizedField]
        /// Compound constraints only (single-field `unique: true` is
        /// encoded on the field, not here).
        var uniqueConstraints: [NormalizedConstraint]
        var relationships: [String: [String: String]]

        var description: String {
            return "NormalizedSchema(\(name))"
        }
    }

    private struct NormalizedField: Equatable {
        var type: String
        var indexed: Bool
        var unique: Bool
        var required: Bool
        var autoAssign: Bool
        var maxLength: Int?
        var maxCount: Int?
        /// Stringified default value — string/number/boolean all
        /// convert through `String(describing:)`. Sufficient for
        /// equality; avoids a bespoke union type just for the test.
        var defaultValue: String?
    }

    private struct NormalizedConstraint: Equatable, Comparable {
        var name: String
        var fields: [String]

        static func < (l: NormalizedConstraint, r: NormalizedConstraint) -> Bool {
            l.name < r.name
        }
    }

    func testSwiftAndJsLoadersProduceIdenticalSchema() throws {
        try assertParity(fixtureName: "sample-schema.toml")
    }

    /// Type-conversion edge cases: zero/one/negative/float/scientific
    /// number defaults, bool true/false, boolean- and number-looking
    /// strings, empty-string default, date-like string, id literal,
    /// self-referential hasMany, forward-declared relationship target,
    /// and unicode (emoji / non-Latin / accented) defaults. All must
    /// round-trip identically through both loaders.
    func testTypeConversionEdgeCasesParity() throws {
        try assertParity(fixtureName: "type-coercion.toml")
    }

    /// Shared parity body — load the fixture through both loaders,
    /// normalize, compare model-by-model so divergences point at a
    /// specific model.
    private func assertParity(fixtureName: String) throws {
        let fixture = CrossPlatformHarness.fixturesDir
            .appendingPathComponent(fixtureName)
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Fixture missing at \(fixture.path)")
        }

        // Swift side.
        let swiftSchemas = try TomlSchemaLoader.load(from: fixture)
        let swiftNorm = Dictionary(uniqueKeysWithValues:
            swiftSchemas.map { (key: $0.name, value: normalize(swift: $0)) }
        )

        // JS side. Skips if node / js-bao isn't available.
        let jsRaw = try CrossPlatformHarness.runSchemaLoader(tomlPath: fixture)
        let jsNorm = Dictionary(uniqueKeysWithValues:
            jsRaw.compactMap { raw -> (String, NormalizedSchema)? in
                guard let name = raw["name"] as? String else { return nil }
                return (name, normalize(js: raw))
            }
        )

        XCTAssertEqual(
            Set(swiftNorm.keys), Set(jsNorm.keys),
            "Swift and JS loaders disagree on model set"
        )
        for modelName in swiftNorm.keys.sorted() {
            let swift = swiftNorm[modelName]!
            let js = jsNorm[modelName]!
            if swift != js {
                XCTFail("""
                Parity divergence on model `\(modelName)` (fixture \(fixtureName))
                Swift fields: \(swift.fields)
                JS    fields: \(js.fields)
                Swift constraints: \(swift.uniqueConstraints)
                JS    constraints: \(js.uniqueConstraints)
                Swift relationships: \(swift.relationships)
                JS    relationships: \(js.relationships)
                """)
            }
        }
    }

    // MARK: - Normalization

    private func normalize(swift schema: PrimitiveSchema) -> NormalizedSchema {
        var fields: [String: NormalizedField] = [:]
        for (name, desc) in schema.fields {
            fields[name] = NormalizedField(
                type: desc.type.rawValue,
                indexed: desc.indexed,
                unique: desc.unique,
                required: desc.required,
                autoAssign: desc.autoAssign,
                maxLength: desc.maxLength,
                maxCount: desc.maxCount,
                defaultValue: stringifyDefault(desc.default)
            )
        }
        let constraints = schema.constraints.values
            .map { NormalizedConstraint(name: $0.name, fields: $0.fields) }
            .sorted()
        var rels: [String: [String: String]] = [:]
        for (relName, desc) in schema.relationships {
            rels[relName] = desc.properties
        }
        return NormalizedSchema(
            name: schema.name,
            fields: fields,
            uniqueConstraints: constraints,
            relationships: rels
        )
    }

    private func stringifyDefault(_ def: DefaultValue?) -> String? {
        guard let def else { return nil }
        switch def {
        case let .scalar(.string(s)):    return "s:\(s)"
        case let .scalar(.number(n)):
            // Strip a trailing `.0` so `3` and `3.0` compare equal.
            return n == n.rounded() ? "n:\(Int64(n))" : "n:\(n)"
        case let .scalar(.boolean(b)):   return "b:\(b)"
        case let .scalar(.id(s)):        return "i:\(s)"
        case let .scalar(.date(s)):      return "d:\(s)"
        case .scalar(.stringset), .scalar(.json):
            return nil
        case let .function(name):        return "fn:\(name)"
        }
    }

    /// Convert one js-bao schema object into the canonical form.
    /// Missing boolean flags normalize to `false` (js-bao omits
    /// falsy flags; Swift emits them explicitly).
    private func normalize(js raw: [String: Any]) -> NormalizedSchema {
        let name = (raw["name"] as? String) ?? ""
        let rawFields = (raw["fields"] as? [String: [String: Any]]) ?? [:]
        var fields: [String: NormalizedField] = [:]
        for (fname, f) in rawFields {
            fields[fname] = NormalizedField(
                type: (f["type"] as? String) ?? "",
                indexed: (f["indexed"] as? Bool) ?? false,
                unique: (f["unique"] as? Bool) ?? false,
                required: (f["required"] as? Bool) ?? false,
                autoAssign: (f["autoAssign"] as? Bool) ?? false,
                maxLength: f["maxLength"] as? Int,
                maxCount: f["maxCount"] as? Int,
                defaultValue: stringifyJsDefault(f["default"])
            )
        }
        let options = (raw["options"] as? [String: Any]) ?? [:]
        let constraintsRaw =
            (options["uniqueConstraints"] as? [[String: Any]]) ?? []
        let constraints = constraintsRaw.compactMap { c -> NormalizedConstraint? in
            guard let cname = c["name"] as? String,
                  let cfields = c["fields"] as? [String] else { return nil }
            return NormalizedConstraint(name: cname, fields: cfields)
        }.sorted()

        var rels: [String: [String: String]] = [:]
        if let rawRels = options["relationships"] as? [String: [String: Any]] {
            for (rname, rdict) in rawRels {
                var props: [String: String] = [:]
                for (k, v) in rdict {
                    // All relationship property values are strings in
                    // the runtime schema. Coerce defensively: if the
                    // loader ever emits a non-string here, we want the
                    // assertion to fail loudly via the normalized form.
                    if let s = v as? String { props[k] = s }
                    else { props[k] = String(describing: v) }
                }
                rels[rname] = props
            }
        }

        return NormalizedSchema(
            name: name,
            fields: fields,
            uniqueConstraints: constraints,
            relationships: rels
        )
    }

    /// Coerce a js-bao scalar default into the same stringified form
    /// used for the Swift side, so equality just works.
    ///
    /// `JSONSerialization` returns bools as `NSNumber` backed by
    /// `kCFBooleanTrue/False` and integers as `NSNumber` backed by an
    /// integer type. Both `as? Bool` and `as? Int` succeed against
    /// either, so we must distinguish via `CFGetTypeID` to avoid
    /// decoding `default = 0` as `false`.
    private func stringifyJsDefault(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let s = value as? String { return "s:\(s)" }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return "b:\(n.boolValue)"
            }
            let d = n.doubleValue
            return d == d.rounded() ? "n:\(n.int64Value)" : "n:\(d)"
        }
        return String(describing: value)
    }
}
