import CryptoKit
import Foundation

/// Rows to upload-ready bulk-load chunks: the Swift twin of the JS client's
/// `buildDocumentIngestChunks`.
///
/// The artifact is each model's rows as gzipped ndjson, `⟨id⟩\t⟨patch JSON⟩\n`
/// per line, ids ascending, cut into chunks whose descriptors match their
/// bytes. The rules are the JS builder's, so for the same rows both write the
/// same chunk text with the same cuts: models in UTF-8 byte order, ids in
/// UTF-8 byte order, keys in UTF-8 byte order at every depth, strings escaped
/// as `JSON.stringify` escapes them, numbers as ECMAScript's
/// `Number::toString` prints them. Only the gzip stream differs, because the
/// compressor is the platform's.
enum DocumentIngestChunkBuilder {
    /// What one bulk-load session may carry: the server's `INGEST_CHUNK_LIMITS`.
    enum Limits {
        /// Stored (compressed) bytes of one chunk.
        static let maxChunkBytes = 8 * 1024 * 1024
        /// Decompressed bytes of one chunk.
        static let maxChunkRawBytes = 16 * 1024 * 1024
        /// Lines in one chunk.
        static let maxChunkRows = 50_000
        /// Chunks in one session.
        static let maxChunks = 4096
        /// Stored bytes across the whole session.
        static let maxTotalBytes = 2 * 1024 * 1024 * 1024
    }

    private struct Line {
        let id: String
        let text: String
        let rawBytes: Int
    }

    private static func invalid(_ message: String) -> JsBaoError {
        JsBaoError(code: .invalidArgument, message: message)
    }

    /// Build the chunks; see `DocumentIngestsAPI.buildChunks`.
    static func build(_ rows: [DocumentIngestRow], options: DocumentIngestBuildOptions) throws -> [DocumentIngestChunk] {
        let cutRows = options.cutRows
        let cutRawBytes = options.cutRawBytes
        guard (1...Limits.maxChunkRows).contains(cutRows) else {
            throw invalid("cutRows must be an integer from 1 to \(Limits.maxChunkRows); received \(cutRows)")
        }
        guard (1...Limits.maxChunkRawBytes).contains(cutRawBytes) else {
            throw invalid("cutRawBytes must be an integer from 1 to \(Limits.maxChunkRawBytes); received \(cutRawBytes)")
        }

        var models: [String: [Line]] = [:]
        for row in rows {
            // The upload refuses any other name as INGEST_CHUNK_UNADDRESSABLE.
            guard isAddressableModel(row.model) else {
                throw invalid(
                    "a row's model is ASCII letters, digits and _, starting with a letter; " +
                        "received \(quoted(row.model))"
                )
            }
            guard !row.id.isEmpty else { throw invalid("\(row.model): a row's id is a non-empty string") }
            // By scalar, so a CRLF grapheme is caught. A carriage return is
            // refused as the JS builder refuses it, where a multipart upload
            // rewrites it as CRLF in the firstId/lastId fields.
            guard !row.id.unicodeScalars.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }) else {
                throw invalid(
                    "\(row.model) \(quoted(row.id)): a record id carries no tab, no newline and no carriage return"
                )
            }
            // The reader's UTF-8 decoding drops a leading U+FEFF, so the id
            // the room read would not be the id given.
            guard row.id.unicodeScalars.first != "\u{FEFF}" else {
                throw invalid("\(row.model) \(quoted(row.id)): a record id does not start with U+FEFF")
            }
            var text = row.id + "\t"
            try writeObject(row.patch, into: &text, where: "\(row.model) \(row.id)")
            text += "\n"
            let rawBytes = text.utf8.count
            guard rawBytes <= Limits.maxChunkRawBytes else {
                throw invalid(
                    "\(row.model) \(row.id): this row is \(rawBytes) bytes and a chunk may carry " +
                        "\(Limits.maxChunkRawBytes) decompressed"
                )
            }
            models[row.model, default: []].append(Line(id: row.id, text: text, rawBytes: rawBytes))
        }

        // Cut first: the count before any stored-size split is a floor, and an
        // artifact already past the chunk limit is refused before anything is
        // compressed.
        var planned: [(model: String, groups: [[Line]])] = []
        var floor = 0
        for model in models.keys.sorted(by: { compareUTF8($0, $1) < 0 }) {
            let lines = models[model]!.sorted { compareUTF8($0.id, $1.id) < 0 }
            var groups: [[Line]] = []
            var current: [Line] = []
            var currentBytes = 0
            for (at, line) in lines.enumerated() {
                // Byte equality, not `==`: Swift's string equality is canonical
                // equivalence, and two ids that differ in bytes are two records.
                if at > 0, compareUTF8(lines[at - 1].id, line.id) == 0 {
                    throw invalid("\(model) \(line.id): the rows name this record twice; a load may name a record once")
                }
                if !current.isEmpty,
                   currentBytes + line.rawBytes > cutRawBytes
                    || current.count >= cutRows
                    || current.count >= Limits.maxChunkRows {
                    groups.append(current)
                    current = []
                    currentBytes = 0
                }
                current.append(line)
                currentBytes += line.rawBytes
            }
            if !current.isEmpty { groups.append(current) }
            planned.append((model, groups))
            floor += groups.count
        }
        func tooMany(_ count: Int) -> JsBaoError {
            invalid(
                "these rows cut into \(count) chunks and a load may hold \(Limits.maxChunks); " +
                    "split them into several loads"
            )
        }
        if floor > Limits.maxChunks { throw tooMany(floor) }

        var chunks: [DocumentIngestChunk] = []
        for (model, groups) in planned {
            var index = 0
            for group in groups { try encode(model, group[...], into: &chunks, index: &index) }
        }
        if chunks.count > Limits.maxChunks { throw tooMany(chunks.count) }
        let stored = chunks.reduce(0) { $0 + $1.bytes }
        if stored > Limits.maxTotalBytes {
            throw invalid(
                "these rows store as \(stored) bytes and a load may hold \(Limits.maxTotalBytes); " +
                    "split them into several loads"
            )
        }
        return chunks
    }

    /// Encode one model's lines as chunks, halving any whose stored size
    /// passes the limit, as the CLI and the JS client split them.
    private static func encode(
        _ model: String, _ lines: ArraySlice<Line>, into out: inout [DocumentIngestChunk], index: inout Int
    ) throws {
        var raw = Data()
        raw.reserveCapacity(lines.reduce(0) { $0 + $1.rawBytes })
        for line in lines { raw.append(contentsOf: line.text.utf8) }
        let body = Gzip.gzip(raw)
        if body.count > Limits.maxChunkBytes {
            guard lines.count > 1 else {
                throw invalid(
                    "\(model) \(lines.first!.id): this row stores as \(body.count) bytes and a chunk may carry " +
                        "\(Limits.maxChunkBytes)"
                )
            }
            let half = lines.startIndex + (lines.count + 1) / 2
            try encode(model, lines[lines.startIndex..<half], into: &out, index: &index)
            try encode(model, lines[half...], into: &out, index: &index)
            return
        }
        out.append(DocumentIngestChunk(
            model: model,
            index: index,
            rows: lines.count,
            bytes: body.count,
            rawBytes: raw.count,
            sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
            firstId: lines.first!.id,
            lastId: lines.last!.id,
            body: body
        ))
        index += 1
    }

    // MARK: - Canonical JSON

    /// Order two strings by their UTF-8 bytes, as the server's table does.
    static func compareUTF8(_ left: String, _ right: String) -> Int {
        if left.utf8.elementsEqual(right.utf8) { return 0 }
        return left.utf8.lexicographicallyPrecedes(right.utf8) ? -1 : 1
    }

    /// A patch as the artifact carries it: keys in UTF-8 byte order at every
    /// depth, strings and numbers written as the JS builder writes them.
    static func canonical(_ value: JSONValue, where place: String = "") throws -> String {
        var out = ""
        try write(value, into: &out, where: place)
        return out
    }

    private static func writeObject(_ object: [String: JSONValue], into out: inout String, where place: String) throws {
        out += "{"
        var first = true
        for key in object.keys.sorted(by: { compareUTF8($0, $1) < 0 }) {
            if !first { out += "," }
            first = false
            writeString(key, into: &out)
            out += ":"
            try write(object[key]!, into: &out, where: place)
        }
        out += "}"
    }

    private static func write(_ value: JSONValue, into out: inout String, where place: String) throws {
        switch value {
        case .null:
            out += "null"
        case .bool(let flag):
            out += flag ? "true" : "false"
        case .string(let text):
            writeString(text, into: &out)
        case .number(let number):
            guard number.isFinite else { throw invalid("\(place): \(number) is not a JSON number") }
            out += ecmaScriptNumber(number)
        case .array(let members):
            out += "["
            for (at, member) in members.enumerated() {
                if at > 0 { out += "," }
                try write(member, into: &out, where: place)
            }
            out += "]"
        case .object(let object):
            try writeObject(object, into: &out, where: place)
        }
    }

    /// A string as `JSON.stringify` writes it: `"` and `\` escaped, the
    /// short escapes for backspace, form feed, newline, return and tab, every
    /// other control character as `\u00xx`, and nothing else escaped.
    private static func writeString(_ text: String, into out: inout String) {
        out += "\""
        // Most strings need no escape at all: take them whole.
        if !text.utf8.contains(where: { $0 < 0x20 || $0 == 0x22 || $0 == 0x5C }) {
            out += text
            out += "\""
            return
        }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// A finite number as ECMAScript's `Number::toString` prints it.
    ///
    /// The digits are Swift's own: `Double.description` gives the shortest
    /// digits that round-trip, the same digits ECMAScript chooses. Only the
    /// layout differs (`3.0`, `1e+16`, `1.5e-07`), so the digits and the
    /// decimal exponent are read back out of it and laid out again under the
    /// ECMAScript rules: no `.0`, fixed notation from 1e-7 up to 1e21, and
    /// otherwise `d.ddde±N` with no leading zero in the exponent.
    static func ecmaScriptNumber(_ value: Double) -> String {
        if value == 0 { return "0" }
        var text = value.description
        var sign = ""
        if text.hasPrefix("-") {
            sign = "-"
            text.removeFirst()
        }
        var mantissa = Substring(text)
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...]) ?? 0
        }
        let integer: Substring
        let fraction: Substring
        if let dot = mantissa.firstIndex(of: ".") {
            integer = mantissa[..<dot]
            fraction = mantissa[mantissa.index(after: dot)...]
        } else {
            integer = mantissa
            fraction = ""
        }
        // The value is 0.⟨digits⟩ × 10^point.
        var digits = Array(integer + fraction)
        var point = integer.count + exponent
        while digits.first == "0" {
            digits.removeFirst()
            point -= 1
        }
        while digits.last == "0" { digits.removeLast() }
        let k = digits.count
        let n = point
        let all = String(digits)
        if k <= n && n <= 21 {
            return sign + all + String(repeating: "0", count: n - k)
        }
        if 0 < n && n <= 21 {
            return sign + String(digits[0..<n]) + "." + String(digits[n...])
        }
        if -6 < n && n <= 0 {
            return sign + "0." + String(repeating: "0", count: -n) + all
        }
        let e = n - 1
        let shown = e < 0 ? "-\(-e)" : "+\(e)"
        if k == 1 { return sign + all + "e" + shown }
        return sign + String(digits[0]) + "." + String(digits[1...]) + "e" + shown
    }

    /// The upload endpoint's model-name syntax: `[A-Za-z][A-Za-z0-9_]*`.
    private static func isAddressableModel(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, isLetter(first) else { return false }
        return bytes.allSatisfy { isLetter($0) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F }
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    private static func quoted(_ text: String) -> String {
        var out = ""
        writeString(text, into: &out)
        return out
    }
}
