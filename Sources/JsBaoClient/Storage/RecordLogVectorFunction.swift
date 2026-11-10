import Foundation
import JsBaoSQLite

/// `record_log_vec_f32(value, element, dims)` (#5230), the SQL function a
/// device vector index's triggers and fill convert a stored vector value
/// with: js-bao's `recordLogVecF32`, rule for rule, over ``VectorCodec`` (the
/// codec the #5225 fixture pins).
///
/// It answers the value's `dims` numbers as vec1 holds them (binary32,
/// little-endian; `f16` and `i8` converted) when `value` is text that is the
/// canonical base64 of a vector of `element` (`f32`, `f16`, `i8`) and `dims`
/// (an integer, at least 1) and every number it decodes to is finite; NULL
/// for anything else, so a value that is not a vector holds no vec1 row.
/// Deterministic, so SQLite may run it once per statement.
///
/// ``SQLiteStorageProvider`` registers it on every connection it opens. A
/// connection opened elsewhere (an inspector reading the file) has no such
/// function, and a write there that fires a vector index's trigger is
/// refused; reading works.
enum RecordLogVectorFunction {

    /// The function's name, js-bao's `RECORD_LOG_VECTOR_FUNCTION`.
    static let name = "record_log_vec_f32"

    /// Register the function on `db`.
    static func register(on db: OpaquePointer) -> Int32 {
        sqlite3_create_function_v2(db, name, 3, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, convert, nil, nil, nil)
    }

    /// The bytes vec1 holds for a stored vector value, or `nil` for one that is not one.
    ///
    /// ``VectorCodec/decode(_:encoding:)``'s rules, taken straight from the
    /// bytes, since a trigger runs this once per row written: the text is
    /// canonical when it is exactly the base64 its bytes encode to (the length,
    /// the alphabet, the padding and zero unused bits, as
    /// ``VectorCodec/isCanonical(_:bytes:)`` holds them); an `f32` value's bytes
    /// are vec1's as they are, and `f16` and `i8` convert as the codec does.
    static func binary32(_ value: String, element: String, dims: Int) -> Data? {
        guard let element = VectorElement(rawValue: element), dims >= 1 else { return nil }
        let bytes = VectorCodec.byteLength(VectorEncoding(dims: dims, element: element))
        guard value.utf8.count == 4 * ((bytes + 2) / 3), let data = Data(base64Encoded: value), data.count == bytes,
              data.base64EncodedString() == value
        else { return nil }
        // Binary32 little-endian: the platform's own order on every Apple target.
        let finite = { (bits: UInt32) in bits & 0x7f80_0000 != 0x7f80_0000 }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            switch element {
            case .f32:
                for i in 0..<dims where !finite(raw.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self)) { return nil }
                return data
            case .f16:
                var out = [UInt32](repeating: 0, count: dims)
                for i in 0..<dims {
                    let half = UInt32(raw.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self))
                    let sign = (half & 0x8000) << 16
                    let exponent = (half >> 10) & 0x1f
                    let mantissa = half & 0x3ff
                    if exponent == 0x1f { return nil }
                    if exponent == 0 {
                        // A subnormal or zero: the mantissa in units of 2^-24, exact in binary32.
                        out[i] = (Float(mantissa) * 0x1p-24).bitPattern | sign
                    } else {
                        out[i] = sign | (exponent + 112) << 23 | mantissa << 13
                    }
                }
                return out.withUnsafeBytes { Data($0) }
            case .i8:
                let scale = Double(Float(bitPattern: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)))
                var out = [Float](repeating: 0, count: dims)
                for i in 0..<dims {
                    let number = Float(Double(Int8(bitPattern: raw[4 + i])) * scale)
                    guard number.isFinite else { return nil }
                    out[i] = number
                }
                return out.withUnsafeBytes { Data($0) }
            }
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let convert: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = { context, count, arguments in
        guard count == 3, let arguments,
              sqlite3_value_type(arguments[0]) == SQLITE_TEXT, sqlite3_value_type(arguments[1]) == SQLITE_TEXT,
              let value = sqlite3_value_text(arguments[0]), let element = sqlite3_value_text(arguments[1])
        else { return sqlite3_result_null(context) }
        let dims: Int
        switch sqlite3_value_type(arguments[2]) {
        case SQLITE_INTEGER:
            dims = Int(sqlite3_value_int64(arguments[2]))
        case SQLITE_FLOAT:
            let number = sqlite3_value_double(arguments[2])
            guard number.rounded() == number, abs(number) < 1e9 else { return sqlite3_result_null(context) }
            dims = Int(number)
        default:
            return sqlite3_result_null(context)
        }
        guard let bytes = binary32(String(cString: value), element: String(cString: element), dims: dims) else {
            return sqlite3_result_null(context)
        }
        bytes.withUnsafeBytes { sqlite3_result_blob(context, $0.baseAddress, Int32($0.count), transient) }
    }
}
