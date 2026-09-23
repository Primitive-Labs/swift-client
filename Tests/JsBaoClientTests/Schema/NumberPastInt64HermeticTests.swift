import XCTest
@testable import JsBaoClient
import YSwift
import Yniffi

/// A `number` field holding a finite `Double` whose JS decimal form is a
/// bare integer literal past `Number.MAX_SAFE_INTEGER` (#3456).
///
/// `YrsMap.insert` hands its `value` to `Any::from_json(...).unwrap()` in
/// yniffi (`lib/src/map.rs:107`), and a bare integer literal — no `.`, no
/// exponent — takes that parser's INTEGER branch. Two things go wrong
/// there, and the encoder's `.0` fixes both:
///
/// 1. Past `i64::MAX` the parse fails outright and the `unwrap` aborts
///    the process — `EXC_CRASH (SIGABRT)` from inside the CRDT write,
///    with no Swift error for the app to catch. `13000000000000000000`,
///    which `PrimitiveValue.encodeNumber` emits per the ECMA-262 layout
///    rules, does it, as does any `UInt64` in the top half of its range.
///
/// 2. Between `2^53` and `i64::MAX` the parse SUCCEEDS but lands the
///    wrong type. `Any::try_from(u64)` / `Any::from(i64)` yield
///    `Any::Number(f64)` only up to `F64_MAX_SAFE_INTEGER` (`2^53 - 1`);
///    above it they yield `Any::BigInt(i64)`, which yrs encodes as lib0
///    type 122 and yjs's `readAny` decodes as a JS `bigint`. Nothing on
///    the JS side expects one — `JSON.stringify` throws on a BigInt and
///    every `typeof value === "number"` check misses it — while a JS
///    client writing the same number sends a float64 (type 123).
///
/// So the encoder emits a float-parseable literal for every bare integer
/// literal above `2^53 - 1`, and the value lands as the `Any::Number(f64)`
/// a JS client produces. `encodeNumber` itself is untouched: it is the
/// js-bao `String(value)` twin that keys the unique indexes, and those
/// keys are Y.Map KEYS, never parsed as JSON.
///
/// WHICH float literal matters, because that parser's float branch is not
/// correctly rounded either: it reads the digits into a `u64` and computes
/// `significand as f64 * 10^exponent`, so a significand past `2^53` is
/// rounded before the scaling. The js-bao digits with a `.0` stuck on the
/// end hit exactly that — `70338045433163640.0` lands as
/// `70338045433163632`, a value the caller never wrote and one the
/// unique-index key (built from the caller's value) no longer describes.
/// `PrimitiveValue.exactFloatLiteral` therefore picks a literal the
/// parser's own arithmetic reproduces exactly, and the encoder refuses
/// the rare double above `2^64` where no literal does.
///
/// In-process `YDocument`s throughout — no dev server.
final class NumberPastInt64HermeticTests: XCTestCase {

    /// The issue's own seed: a `UInt64` in the top half of its range.
    private let seed = 13_000_000_000_000_000_000.0

    /// `2^63` exactly — `Double(Int64.max)` rounds up to this, so it is
    /// the first double that no longer fits an `i64`.
    private let twoTo63 = 9_223_372_036_854_775_808.0

    /// The largest double strictly below `2^63` (`2^63 - 1024`).
    private let belowTwoTo63 = 9_223_372_036_854_774_784.0

    /// `Number.MAX_SAFE_INTEGER`, `2^53 - 1`: the largest integer yrs
    /// still turns into an `Any::Number`. This is the boundary, not
    /// `Double(Int64.max)`.
    private let maxSafeInteger = 9_007_199_254_740_991.0

    /// `2^53` — the first integer yrs would store as an `Any::BigInt`.
    private let twoTo53 = 9_007_199_254_740_992.0

    /// An integer between `2^53` and `i64::MAX`: parses fine as an `i64`,
    /// and that is the problem.
    private let inBigIntBand = 1_234_567_890_123_456_800.0

    /// The pair from the review: two DISTINCT doubles one ulp apart, the
    /// first of which the `.0` form silently stored as the second.
    private let driftPair = (70_338_045_433_163_640.0, 70_338_045_433_163_632.0)

    /// A double above `2^64` that the FFI's parser cannot reach: no `u64`
    /// significand scaled by an exact power of ten lands on it.
    private let unreachable = 3.6157909375721525e19

    // MARK: - Wire inspection

    /// The lib0 type tag yrs wrote for `key`, read out of the document's
    /// own update bytes.
    ///
    /// The suite has no yjs to decode the update with, so it reads the tag
    /// yjs's `readAny` would switch on: 122 is BigInt64 (a JS `bigint`),
    /// 123 is Float64 and 124 Float32 (both a JS `number`), 125 a varint
    /// integer (also a `number`). In a v1 update a map entry's value
    /// follows its key as `[keyLen, key…, 1, tag, payload…]`.
    private func wireTag(forKey key: String, in doc: YDocument) throws -> UInt8 {
        let emptySv: [UInt8] = YDocument().transactSync { txn in
            txn.transactionStateVector()
        }
        let bytes: [UInt8] = doc.transactSync { txn in doc.diff(txn: txn, from: emptySv) }
        let needle = Array(key.utf8)
        let start = try XCTUnwrap(
            bytes.indices.first { i in
                i + needle.count <= bytes.count
                    && Array(bytes[i ..< i + needle.count]) == needle
            },
            "the key '\(key)' is not in the update bytes"
        )
        let tagIndex = start + needle.count + 1
        return try XCTUnwrap(tagIndex < bytes.count ? bytes[tagIndex] : nil)
    }

    /// Insert one already-encoded literal under `key` and hand back the
    /// document, so the tag and the read-back can both be inspected.
    private func inserting(_ literal: String, key: String) -> (YDocument, String?) {
        let doc = YDocument()
        let readBack: String? = doc.transactSync { txn in
            let map = txn.transactionGetOrInsertMap(name: "probe")
            map.insert(tx: txn, key: key, value: literal)
            return try? map.get(tx: txn, key: key)
        }
        return (doc, readBack)
    }

    // MARK: - The repro

    /// The crash, end to end, on the path the report's stack trace names:
    /// `DynamicModel.save` → `writeValue` → `YrsMap.insert`. Before the
    /// fix this did not fail — it aborted the whole test process.
    func testSavingANumberPastInt64MaxSucceedsAndReadsBack() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "game",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "seed": FieldDescriptor(type: .number),
            ]
        ))

        _ = try model.create(id: "game", values: ["seed": .number(seed)])

        XCTAssertEqual(model.find(id: "game")?["seed"]?.asNumber, seed,
                       "a finite Double past i64::MAX must round-trip through the CRDT")
    }

    /// The same value written as an UPDATE rather than a create — the
    /// second write goes down `applyWriteInternal`'s update branch.
    func testUpdatingAFieldToANumberPastInt64MaxSucceeds() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "game",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "seed": FieldDescriptor(type: .number),
            ]
        ))

        _ = try model.create(id: "game", values: ["seed": .number(1)])
        _ = try model.update(id: "game", values: ["seed": .number(seed)])

        XCTAssertEqual(model.find(id: "game")?["seed"]?.asNumber, seed)
    }

    /// The negative half of the band, below `i64::MIN`.
    func testSavingANumberBelowInt64MinSucceedsAndReadsBack() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "game",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "seed": FieldDescriptor(type: .number),
            ]
        ))

        _ = try model.create(id: "game", values: ["seed": .number(-seed)])

        XCTAssertEqual(model.find(id: "game")?["seed"]?.asNumber, -seed)
    }

    // MARK: - The wire form

    /// The encoding rule itself: past the `i64` band the literal carries a
    /// decimal point or an exponent, so the yniffi parser takes its float
    /// branch. The numeric value is unchanged either way.
    func testTheWireFormPastInt64MaxIsFloatParseable() throws {
        for value in [seed, -seed, 1e20, -1e20, twoTo63] {
            let encoded = try XCTUnwrap(PrimitiveValue.number(value).encodedForYrs())
            XCTAssertTrue(
                encoded.contains(".") || encoded.lowercased().contains("e"),
                "\(value) encoded as the bare integer literal '\(encoded)', which "
                + "Any::from_json parses as an i64 and panics on"
            )
            XCTAssertEqual(Double(encoded), value,
                           "the float-parseable form must denote the same number")
            XCTAssertNil(Int64(encoded),
                         "a literal an i64 accepts is not what this band needs")
        }
    }

    /// And the same literal survives a real `YrsMap.insert` / `get`
    /// round-trip — the FFI call that used to abort.
    func testTheWireFormPastInt64MaxSurvivesTheFfiRoundTrip() throws {
        let doc = YDocument()
        let encoded = try XCTUnwrap(PrimitiveValue.number(seed).encodedForYrs())
        let readBack: String? = doc.transactSync { txn in
            let map = txn.transactionGetOrInsertMap(name: "probe")
            map.insert(tx: txn, key: "seed", value: encoded)
            return try? map.get(tx: txn, key: "seed")
        }
        XCTAssertEqual(
            PrimitiveValue.decode(yrsString: try XCTUnwrap(readBack), as: .number),
            .number(seed),
            "yrs re-serializes the f64 in exponential form; decode reads it back"
        )
        XCTAssertEqual(readBack, "1.3e+19",
                       "the exact read-back form `docs/codegen.md` quotes")
    }

    // MARK: - Edges

    /// Everything yrs already stores as an `Any::Number` keeps its exact
    /// js-bao byte form — the fix must not drift ordinary numbers. The
    /// boundary is `Number.MAX_SAFE_INTEGER`, and it is inclusive.
    func testNumbersUpToMaxSafeIntegerKeepTheirBareIntegerForm() throws {
        let cases: [(Double, String)] = [
            (0, "0"),
            (3, "3"),
            (-7, "-7"),
            (1e15, "1000000000000000"),
            (4503599627370496, "4503599627370496"),
            (maxSafeInteger, "9007199254740991"),
            (-maxSafeInteger, "-9007199254740991"),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(PrimitiveValue.number(value).encodedForYrs(), expected,
                           "\(value) must keep its js-bao integer form")
        }
    }

    /// And past it every bare integer literal carries the float form —
    /// including the whole `(2^53, i64::MAX)` band, which parsed fine as
    /// an `i64` and landed as an `Any::BigInt`.
    ///
    /// The form is `<significand>e<exponent>`, with the shortest
    /// significand that the parser's `Double(significand) * 10^exponent`
    /// turns back into this exact double.
    func testIntegersPastMaxSafeIntegerCarryTheFloatForm() throws {
        let cases: [(Double, String)] = [
            (twoTo53, "9007199254740992e0"),
            (-twoTo53, "-9007199254740992e0"),
            (1e16, "1e16"),
            (inBigIntBand, "12345678901234568e2"),
            (belowTwoTo63, "92233720368547744e2"),
            (-belowTwoTo63, "-92233720368547744e2"),
            (twoTo63, "9223372036854776e3"),
            (seed, "13e18"),
            (driftPair.0, "7033804543316364e1"),
            (driftPair.1, "7033804543316363e1"),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(PrimitiveValue.number(value).encodedForYrs(), expected,
                           "\(value) must reach the FFI as a float literal")
        }
    }

    /// The reason the boundary is `>` and not `>=`: `2^53 - 1` is the last
    /// integer yrs stores as an `Any::Number` from the bare literal, AND
    /// the last one its float parser mishandles. Appending `.0` there
    /// reads back one less, so the safe band must keep its bare form.
    func testMaxSafeIntegerKeepsItsBareFormBecauseTheFloatFormLosesIt() throws {
        let bare = try XCTUnwrap(PrimitiveValue.number(maxSafeInteger).encodedForYrs())
        XCTAssertEqual(bare, "9007199254740991")

        let (bareDoc, bareBack) = inserting(bare, key: "safe")
        XCTAssertEqual(Double(try XCTUnwrap(bareBack)), maxSafeInteger,
                       "the bare literal at MAX_SAFE_INTEGER round-trips exactly")
        XCTAssertEqual(try wireTag(forKey: "safe", in: bareDoc), 125,
                       "and lands as a lib0 varint integer, a JS number")

        let (_, dottedBack) = inserting("9007199254740991.0", key: "safe")
        XCTAssertEqual(Double(try XCTUnwrap(dottedBack)), 9_007_199_254_740_990.0,
                       "yrs' float parser loses the low digit here — which is why "
                       + "the encoder must leave this value alone")
    }

    /// The `(2^53, i64::MAX)` band, end to end through a real
    /// `YrsMap.insert` / `get`: no bare integer literal reaches the FFI,
    /// and the value yrs stores is one yjs decodes as a `number`.
    ///
    /// The suite cannot run yjs over the update, so it asserts on the lib0
    /// type tag yjs's `readAny` switches on: 122 (BigInt64) is the `bigint`
    /// this fix removes, and 123 / 124 (Float64 / Float32) are what a JS
    /// client writing the same number produces.
    func testAnIntegerInTheBigIntBandLandsAsAFloatOnTheWire() throws {
        let encoded = try XCTUnwrap(PrimitiveValue.number(inBigIntBand).encodedForYrs())
        XCTAssertTrue(
            encoded.contains(".") || encoded.lowercased().contains("e"),
            "\(inBigIntBand) reached the FFI as the bare literal '\(encoded)', which "
            + "yrs stores as an Any::BigInt and yjs reads as a bigint"
        )

        let (doc, readBack) = inserting(encoded, key: "seed")
        XCTAssertEqual(Double(try XCTUnwrap(readBack)), inBigIntBand,
                       "the value must survive the round trip unchanged")

        let tag = try wireTag(forKey: "seed", in: doc)
        XCTAssertNotEqual(tag, 122,
                          "lib0 type 122 is BigInt64 — yjs decodes it as a bigint, "
                          + "JSON.stringify throws on it, and no `typeof === \"number\"` "
                          + "check sees it")
        XCTAssertTrue([123, 124].contains(tag),
                      "expected a float tag (123 Float64 / 124 Float32), got \(tag)")
    }

    // MARK: - The value the caller handed us

    /// The pair from the review. `70338045433163640` and
    /// `70338045433163632` are two DIFFERENT doubles, and the js-bao digits
    /// with a `.0` appended collapsed the first onto the second: the
    /// parser's `u64` significand (`703380454331636400`) no longer fits in
    /// an f64, so it was rounded before the divide. Each must now save and
    /// read back as itself.
    func testTheTwoDoublesOneUlpApartEachKeepTheirOwnValue() throws {
        XCTAssertNotEqual(driftPair.0, driftPair.1, "the premise: two distinct doubles")

        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "game",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "seed": FieldDescriptor(type: .number),
            ]
        ))

        _ = try model.create(id: "high", values: ["seed": .number(driftPair.0)])
        _ = try model.create(id: "low",  values: ["seed": .number(driftPair.1)])

        XCTAssertEqual(model.find(id: "high")?["seed"]?.asNumber, driftPair.0,
                       "the saved Double must come back bit for bit, not one ulp down")
        XCTAssertEqual(model.find(id: "low")?["seed"]?.asNumber, driftPair.1)
    }

    /// And the unique index stays in step with what was stored. The key is
    /// built from the CALLER's value (`encodeNumber`), so a write that
    /// stored a neighbor instead gave a unique field two records with the
    /// same stored value under two different keys, and a lookup by the
    /// read-back value found nothing.
    func testAUniqueNumberFieldKeepsItsKeyAndItsStoredValueInStep() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "game",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "seed": FieldDescriptor(type: .number, unique: true),
            ]
        ))

        _ = try model.create(id: "high", values: ["seed": .number(driftPair.0)])
        _ = try model.create(id: "low",  values: ["seed": .number(driftPair.1)])

        // Every record still holds a distinct value under a unique field.
        let stored = ["high", "low"].compactMap { model.find(id: $0)?["seed"]?.asNumber }
        XCTAssertEqual(Set(stored).count, 2,
                       "a unique number field must not end up holding one value twice")

        // A lookup by what was READ BACK reaches the record that was written.
        for id in ["high", "low"] {
            let readBack = try XCTUnwrap(model.find(id: id)?["seed"]?.asNumber)
            XCTAssertEqual(
                try model.findByUnique(
                    constraint: "game_seed_unique", value: .number(readBack)
                )?["id"]?.asString,
                id,
                "the stored value must still index the record that stored it"
            )
        }

        // And the constraint still bites on a real duplicate.
        XCTAssertThrowsError(
            try model.create(id: "dup", values: ["seed": .number(driftPair.0)])
        )
    }

    /// The whole band, swept: every double the encoder accepts between
    /// `2^53` and `1e21` comes back out of a real `YrsMap.insert` / `get`
    /// as itself. Seeded, so a failure is reproducible.
    func testEveryAcceptedDoubleInTheBandSurvivesTheFfiUnchanged() throws {
        var state: UInt64 = 0x2545F4914F6CDD1D
        func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }

        var checked = 0
        for _ in 0 ..< 600 {
            let value = Double(next() >> 11) * pow(2.0, Double(1 + Int(next() % 17)))
            guard value.isFinite, value > maxSafeInteger, value < 1e21 else { continue }
            // Refusals are the other test's subject; this one is about the
            // values that DO get written.
            guard let encoded = PrimitiveValue.number(value).encodedForYrs() else { continue }
            checked += 1
            let (_, readBack) = inserting(encoded, key: "seed")
            XCTAssertEqual(Double(try XCTUnwrap(readBack)), value,
                           "'\(encoded)' came back as \(readBack ?? "nil")")
        }
        XCTAssertGreaterThan(checked, 400, "the sweep must actually cover the band")
    }

    /// Above `2^64` the parser cannot be made to reach every double: no
    /// `u64` significand scaled by an exact power of ten lands on them.
    /// Those writes are REFUSED — a Swift error naming the field, which is
    /// what the report asks for as the alternative to succeeding — rather
    /// than silently stored as a neighbor.
    func testADoubleTheParserCannotReachIsRefusedByFieldName() throws {
        XCTAssertNil(PrimitiveValue.number(unreachable).encodedForYrs(),
                     "the premise: no literal reaches this double")

        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "game",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "seed": FieldDescriptor(type: .number),
            ]
        ))

        XCTAssertThrowsError(
            try model.create(id: "game", values: ["seed": .number(unreachable)])
        ) { error in
            let message = (error as? JsBaoError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("seed"),
                          "the error must name the field; got '\(message)'")
            XCTAssertEqual((error as? JsBaoError)?.code, .invalidArgument)
        }

        XCTAssertNil(model.find(id: "game"),
                     "a refused write must leave no record behind")
    }

    /// The same refusal on an update leaves the stored value alone.
    func testARefusedUpdateLeavesThePreviousValueInPlace() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "game",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "seed": FieldDescriptor(type: .number),
            ]
        ))

        _ = try model.create(id: "game", values: ["seed": .number(seed)])
        XCTAssertThrowsError(
            try model.update(id: "game", values: ["seed": .number(unreachable)])
        )
        XCTAssertEqual(model.find(id: "game")?["seed"]?.asNumber, seed)
    }

    /// Fractional values already carry a point; they must not grow a
    /// second one.
    func testFractionalAndExponentialFormsAreUntouched() throws {
        let cases: [(Double, String)] = [
            (0.1, "0.1"),
            (42.5, "42.5"),
            (-1.25, "-1.25"),
            (0.000001, "0.000001"),
            (1e-7, "1e-7"),
            (5e-324, "5e-324"),
            (1e21, "1e+21"),
            (-1e21, "-1e+21"),
            (1.7976931348623157e308, "1.7976931348623157e+308"),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(PrimitiveValue.number(value).encodedForYrs(), expected,
                           "\(value) was already parseable as a float")
        }
    }

    /// `1e21` is the first magnitude JS itself prints in exponential form,
    /// so the band the fix covers stops just below it.
    func testTheBandStopsWhereTheJsLayoutTurnsExponential() throws {
        XCTAssertEqual(PrimitiveValue.number(1e21).encodedForYrs(), "1e+21")
        XCTAssertEqual(PrimitiveValue.number(1e20).encodedForYrs(), "1e20")
    }

    /// Non-finite values keep their documented behavior: the encoder
    /// refuses them and the write path skips the field (#1117, and
    /// `docs/codegen.md`'s "Non-finite numbers" gotcha).
    func testNonFiniteNumbersAreStillRefused() throws {
        XCTAssertNil(PrimitiveValue.number(.nan).encodedForYrs())
        XCTAssertNil(PrimitiveValue.number(.infinity).encodedForYrs())
        XCTAssertNil(PrimitiveValue.number(-.infinity).encodedForYrs())
    }

    // MARK: - The other two writers

    /// `SchemaSync` writes a field's `default` into `_meta_*` through its
    /// own scalar encoder, and that is a `YrsMap.insert` too.
    func testASchemaDefaultPastInt64MaxSyncsWithoutAborting() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: PrimitiveSchema(
            name: "game",
            fields: [
                "seed": FieldDescriptor(type: .number, default: .scalar(.number(seed))),
            ]
        ))

        let raw: String? = doc.transactSync { txn in
            guard let meta = txn.transactionGetMap(name: "_meta_game"),
                  let field = meta.getMap(tx: txn, key: "seed") else { return nil }
            return try? field.get(tx: txn, key: "default")
        }
        XCTAssertEqual(Double(try XCTUnwrap(raw)), seed,
                       "the default must land on the meta map as the same number")
    }

    /// `SchemaSync` has no caller to throw to — it publishes metadata, it
    /// does not validate a save — so a `default` the parser cannot reach is
    /// skipped, the same way a non-finite one is. Not written wrong, and
    /// not an abort.
    func testASchemaDefaultTheParserCannotReachIsSkippedNotAborted() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        SchemaSync.syncModelMeta(doc: doc, schema: PrimitiveSchema(
            name: "game",
            fields: [
                "seed": FieldDescriptor(type: .number, default: .scalar(.number(unreachable))),
            ]
        ))

        let raw: String? = doc.transactSync { txn in
            guard let meta = txn.transactionGetMap(name: "_meta_game"),
                  let field = meta.getMap(tx: txn, key: "seed") else { return nil }
            return try? field.get(tx: txn, key: "default")
        }
        XCTAssertNil(raw, "an unreachable default must be left out, not approximated")
    }

    /// The unique-index key is a Y.Map KEY, not a JSON value — nothing
    /// parses it, and js-bao's `String(value)` has no `.0`. It keeps the
    /// full-digit form so a Swift-written index entry still collides with
    /// the one a JS client writes for the same number.
    func testTheUniqueIndexKeyKeepsItsFullDigitJsForm() throws {
        XCTAssertEqual(PrimitiveValue.encodeNumber(seed), "13000000000000000000")
        XCTAssertEqual(PrimitiveValue.encodeNumber(1e20), "100000000000000000000")
        XCTAssertEqual(PrimitiveValue.encodeNumber(-1e20), "-100000000000000000000")

        let key = UniqueIndex.buildKey(
            fields: ["seed"], values: ["seed": .number(seed)]
        )
        XCTAssertEqual(key, "13000000000000000000")
    }

    /// A `unique: true` number field past the band writes its record AND
    /// its index entry, and the constraint still catches a duplicate.
    func testAUniqueNumberFieldPastInt64MaxStillEnforcesTheConstraint() throws {
        let doc = YDocument()
        SchemaSync.clearCache()
        let model = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "game",
            fields: [
                "id":   FieldDescriptor(type: .id),
                "seed": FieldDescriptor(type: .number, unique: true),
            ]
        ))

        _ = try model.create(id: "one", values: ["seed": .number(seed)])
        XCTAssertThrowsError(
            try model.create(id: "two", values: ["seed": .number(seed)]),
            "the second record holds the same unique key"
        )
        XCTAssertEqual(model.find(id: "one")?["seed"]?.asNumber, seed)
    }
}
