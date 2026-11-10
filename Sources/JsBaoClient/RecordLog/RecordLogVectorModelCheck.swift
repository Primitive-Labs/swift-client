import Foundation

/// What a shared model's envelope says of it (#5230): vec1's version that
/// trained it, the field and index it serves, how it was trained, over how
/// many rows and when. js-bao's `VectorModelParams`.
struct RecordLogVectorModelParams: Equatable, Sendable {
    /// vec1's version that trained it (`0.8`).
    var vec1: String
    var dims: Int
    /// `cos` or `l2`.
    var distance: String
    var nbucket: Int
    /// The codebook count; 0 with no quantizer, ⌈dims/8⌉ or ⌈dims/16⌉ for `bq`.
    var codesize: Int
    /// `none`, `pq`, `opq` or `bq`.
    var quantizer: String
    /// How many rows it was trained over.
    var rows: Int
    /// When it was trained (ISO 8601).
    var trainedAt: String

    /// The params as the envelope carries them, in js-bao's key order.
    var envelopeJSON: String {
        let text = { (value: String) in RecordLogJSON.text(.string(value)) }
        return #"{"vec1":\#(text(vec1)),"dims":\#(dims),"distance":\#(text(distance)),"nbucket":\#(nbucket),"#
            + #""codesize":\#(codesize),"quantizer":\#(text(quantizer)),"rows":\#(rows),"trainedAt":\#(text(trainedAt))}"#
    }
}

/// The `pvm1` envelope a shared model travels in, and the check every model
/// passes before vec1 reads a byte of it (#5230): js-bao's
/// `encodeVectorModelEnvelope`, `checkVectorModelEnvelope`, `vec1Codebooks`
/// and `vec1BqCodesize`, reasons text for text (a shared fixture pins them).
///
/// The envelope: `"PVM1"`, the u16 LE envelope version (1), the u16 LE length
/// of the params, the params as UTF-8 JSON, the u32 LE length of the model,
/// then vec1's bytes.
enum RecordLogVectorModelCheck {

    /// The one envelope format a shared model travels in.
    static let format = "pvm1"
    /// The envelope's version this build writes and reads.
    static let envelopeVersion = 1

    private static let magic: [UInt8] = [0x50, 0x56, 0x4d, 0x31]

    /// vec1's header flags (`vec1.c`): an index, a rotation (OPQ), residual vectors, a bit quantizer, a Walsh–Hadamard transform.
    private static let flagIndex: UInt32 = 0x01
    private static let flagRotate: UInt32 = 0x02
    private static let flagResidual: UInt32 = 0x04
    private static let flagBitquant: UInt32 = 0x08
    private static let flagWHT: UInt32 = 0x10
    private static let headerVersion: UInt32 = 4
    private static let headerVersionBin: UInt32 = 7
    private static let headerSize = 24
    private static let pqCodebookSize = 256
    private static let quantizers = ["none", "pq", "opq", "bq"]

    /// What a device holds a model to: its engine's vec1, the field's dims, the index's distance and registered options.
    struct Expectation: Equatable, Sendable {
        var vec1: String
        var dims: Int
        var distance: String
        var index: RecordLogVectorOptions.Index
    }

    /// What a check answers: the model's params and its vec1 bytes, or why it is refused.
    enum Outcome: Equatable, Sendable {
        case ok(params: RecordLogVectorModelParams, model: Data)
        case refused(String)
    }

    /// The envelope around `model` with `params`.
    static func encode(_ params: RecordLogVectorModelParams, model: Data) -> Data {
        let json = Data(params.envelopeJSON.utf8)
        var out = Data(magic)
        out.append(contentsOf: [UInt8(envelopeVersion & 0xff), UInt8(envelopeVersion >> 8)])
        out.append(contentsOf: [UInt8(json.count & 0xff), UInt8((json.count >> 8) & 0xff)])
        out.append(json)
        let length = UInt32(model.count)
        out.append(contentsOf: (0..<4).map { UInt8((length >> (8 * UInt32($0))) & 0xff) })
        out.append(model)
        return out
    }

    /// The codesize vec1 trains a `bq` model with for `codesize` over `dims`:
    /// one bit per dimension (⌈dims/8⌉ bytes) when none is given or the one
    /// given is at least that, else one bit per two dimensions (⌈dims/16⌉).
    static func bqCodesize(dims: Int, codesize: Int? = nil) -> Int {
        let perDimension = (dims + 7) / 8
        guard let codesize, codesize > 0, codesize < perDimension else { return perDimension }
        return (dims + 15) / 16
    }

    /// How many codebooks vec1 trains for `codesize` over `dims`: it splits
    /// each vector into sub-vectors `⌈dims / codesize⌉` wide, so
    /// `⌈dims / ⌈dims / codesize⌉⌉` of them (25 for codesize 32 over 100 dims).
    static func codebooks(dims: Int, codesize: Int) -> Int {
        let width = (dims + codesize - 1) / codesize
        return (dims + width - 1) / width
    }

    /// A value as JavaScript's `String()` writes it, as js-bao's reasons quote it.
    static func jsString(_ value: JSONValue?) -> String {
        guard let value else { return "undefined" }
        switch value {
        case .null: return "null"
        case .string(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number): return jsNumber(number)
        case .array(let items): return items.map { $0 == .null ? "" : jsString($0) }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    /// A number as JavaScript's `String()` writes it, whatever its size: a
    /// body's params are anyone's, so `1e20` is written `100000000000000000000`
    /// rather than trapping on its way to an `Int64`.
    private static func jsNumber(_ number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
        return PrimitiveValue.jsNumberString(number)
    }

    private static func u16(_ bytes: [UInt8], _ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
    private static func u32le(_ bytes: [UInt8], _ at: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) } }
    private static func u32be(_ bytes: [UInt8], _ at: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[at + $1]) } }

    /// Whether `text` is a date-time, as `Date.parse` reads one: ISO 8601, with or without fractional seconds, or a date alone.
    static func isDateTime(_ text: String) -> Bool { date(text) != nil }

    /// `text` as a date, read as ``isDateTime(_:)`` reads it.
    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        if let date = whole.date(from: text) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: text)
    }

    /// Whether `bytes` is a model this device may hand vec1 for
    /// `expectation`, checked in order before vec1 reads any of it:
    ///
    /// 1. at most ``RecordLogVectorIndex/modelMaxBytes``, its lengths consistent;
    /// 2. the `PVM1` magic and envelope version 1;
    /// 3. `vec1` this engine's version, `dims` the field's, `distance` the index's;
    /// 4. each option the registration states equal to the params' (a `bq`
    ///    codesize as vec1 resolves it), and each it omits within bounds;
    /// 5. vec1's own header agreeing with the params and its layout's length the model's;
    /// 6. every binary32 coefficient of its codebooks, centroids and rotation finite.
    static func check(_ data: Data, _ expectation: Expectation) -> Outcome {
        if data.count > RecordLogVectorIndex.modelMaxBytes { return .refused("the model is more than \(RecordLogVectorIndex.modelMaxBytes) bytes") }
        if data.count < 12 { return .refused("the model ends before its envelope's header") }
        let bytes = [UInt8](data)
        if Array(bytes[0..<4]) != magic { return .refused("the body is not a pvm1 model (no PVM1 magic)") }
        let version = u16(bytes, 4)
        if version != envelopeVersion { return .refused("the model's envelope version \(version) is not \(envelopeVersion)") }
        let paramsLength = u16(bytes, 6)
        if 8 + paramsLength + 4 > bytes.count { return .refused("the model's params run past the body") }
        guard let text = String(bytes: bytes[8..<(8 + paramsLength)], encoding: .utf8), let raw = RecordLogJSON.parse(text)?.objectValue else {
            return .refused("the model's params are not JSON")
        }
        let modelLength = Int(u32le(bytes, 8 + paramsLength))
        if 12 + paramsLength + modelLength != bytes.count {
            return .refused("the model length \(modelLength) is not what follows its params (\(bytes.count - 12 - paramsLength) bytes)")
        }
        let model = Array(bytes[(12 + paramsLength)...])
        if raw["vec1"] != .string(expectation.vec1) {
            return .refused("the model was trained by vec1 \(jsString(raw["vec1"])), this device runs \(expectation.vec1)")
        }
        if raw["dims"] != .number(Double(expectation.dims)) {
            return .refused("the model is for dims \(jsString(raw["dims"])), the field holds \(expectation.dims)")
        }
        if raw["distance"] != .string(expectation.distance) {
            return .refused("the model measures distance \(jsString(raw["distance"])), the index measures \(expectation.distance)")
        }
        let registered: (nbucket: Int?, codesize: Int?, quantizer: String?)
        if case .ann(let nbucket, let codesize, let quantizer) = expectation.index { registered = (nbucket, codesize, quantizer) } else { registered = (nil, nil, nil) }
        guard let nbucket = RecordLogVectorIndex.integer(raw["nbucket"]), (1...65_536).contains(nbucket) else {
            return .refused("the model's nbucket \(jsString(raw["nbucket"])) is outside 1 to 65536")
        }
        guard let quantizer = raw["quantizer"]?.stringValue, quantizers.contains(quantizer) else {
            return .refused("the model's quantizer \(jsString(raw["quantizer"])) is not none, pq, opq or bq")
        }
        let codesize = RecordLogVectorIndex.integer(raw["codesize"])
        if quantizer == "bq" {
            let (wide, narrow) = (bqCodesize(dims: expectation.dims), (expectation.dims + 15) / 16)
            if raw["codesize"] != .number(Double(wide)) && raw["codesize"] != .number(Double(narrow)) {
                return .refused(
                    "the model's codesize \(jsString(raw["codesize"])) is not \(wide) or \(narrow), the codesizes vec1 trains bq with over dims \(expectation.dims)"
                )
            }
        } else {
            let fits = quantizer == "none" ? raw["codesize"] == .number(0) : codesize.map { (1...expectation.dims).contains($0) } ?? false
            if !fits {
                return .refused(
                    "the model's codesize \(jsString(raw["codesize"])) is outside \(quantizer == "none" ? "0 (no quantizer)" : "1 to \(expectation.dims)")"
                )
            }
        }
        if let wanted = registered.nbucket, raw["nbucket"] != .number(Double(wanted)) {
            return .refused("the registration's nbucket is \(wanted), the model's \(jsString(raw["nbucket"]))")
        }
        // With no quantizer vec1 trains no codebooks: a registration's codesize resolves to the 0 the params carry.
        if let wanted = registered.codesize, quantizer != "none" {
            if quantizer == "bq" {
                let resolved = bqCodesize(dims: expectation.dims, codesize: wanted)
                if raw["codesize"] != .number(Double(resolved)) {
                    return .refused(
                        "the registration's codesize is \(wanted) (\(resolved) for bq over dims \(expectation.dims)), the model's \(jsString(raw["codesize"]))"
                    )
                }
            } else if raw["codesize"] != .number(Double(wanted)) {
                return .refused("the registration's codesize is \(wanted), the model's \(jsString(raw["codesize"]))")
            }
        }
        if let wanted = registered.quantizer, raw["quantizer"] != .string(wanted) {
            return .refused("the registration's quantizer is \(wanted), the model's \(jsString(raw["quantizer"]))")
        }
        guard let rows = RecordLogVectorIndex.integer(raw["rows"]), rows >= 1 else {
            return .refused("the model's rows \(jsString(raw["rows"])) is not a positive integer")
        }
        guard let trainedAt = raw["trainedAt"]?.stringValue, isDateTime(trainedAt) else { return .refused("the model's trainedAt is not a date-time") }
        let params = RecordLogVectorModelParams(
            vec1: expectation.vec1, dims: expectation.dims, distance: expectation.distance, nbucket: nbucket, codesize: codesize ?? 0,
            quantizer: quantizer, rows: rows, trainedAt: trainedAt
        )
        if let reason = header(model, params) { return .refused(reason) }
        return .ok(params: params, model: Data(model))
    }

    /// Why vec1's header or coefficients do not agree with `params`, or `nil` when they do.
    private static func header(_ model: [UInt8], _ params: RecordLogVectorModelParams) -> String? {
        if model.count < headerSize { return "the vec1 model is \(model.count) bytes, less than its header" }
        let field = { (index: Int) in u32be(model, index * 4) }
        let (version, flags, nElem, nCodebook, nBucket, eDistance) = (field(0), field(1), field(2), field(3), field(4), field(5))
        let bitquant = params.quantizer == "bq"
        let wantedVersion = bitquant ? headerVersionBin : headerVersion
        if version != wantedVersion { return "the vec1 header version \(version) is not \(wantedVersion)" }
        if nElem != params.dims { return "the vec1 header says nElem \(nElem), the params say dims \(params.dims)" }
        if nBucket != params.nbucket { return "the vec1 header says nBucket \(nBucket), the params say nbucket \(params.nbucket)" }
        let books = params.quantizer == "none" ? 0 : bitquant ? params.codesize : codebooks(dims: params.dims, codesize: params.codesize)
        if nCodebook != books {
            return "the vec1 header says nCodebook \(nCodebook), codesize \(params.codesize) over dims \(params.dims) makes \(books)"
        }
        let distance: UInt32 = params.distance == "cos" ? 2 : 1
        if eDistance != distance { return "the vec1 header says eDistance \(eDistance), the params say \(params.distance)" }
        let rotate = params.quantizer == "opq"
        // vec1 trains bq with the Walsh–Hadamard transform unless told otherwise; nothing else here takes it.
        let allowed = flagIndex | flagRotate | flagResidual | flagBitquant | (bitquant ? flagWHT : 0)
        if flags & ~allowed != 0 || flags & flagIndex == 0 || (flags & flagRotate != 0) != rotate || (flags & flagBitquant != 0) != bitquant {
            return "the vec1 header flags \(flags) do not match quantizer \(params.quantizer)"
        }
        var floats = 0
        // A bq model's codes are bit sketches: it carries no codebook floats.
        if nCodebook > 0 && !bitquant { floats += Int(nCodebook) * ((Int(nElem) + Int(nCodebook) - 1) / Int(nCodebook)) * pqCodebookSize }
        if nBucket > 0 { floats += Int(nElem) * Int(nBucket) }
        if rotate { floats += Int(nElem) * Int(nElem) }
        let expected = headerSize + floats * 4
        if expected != model.count { return "the vec1 model is \(model.count) bytes, its header's layout \(expected)" }
        var at = headerSize
        while at + 4 <= model.count {
            if !Float(bitPattern: u32le(model, at)).isFinite { return "the vec1 model has a coefficient that is not finite (byte \(at))" }
            at += 4
        }
        return nil
    }
}
