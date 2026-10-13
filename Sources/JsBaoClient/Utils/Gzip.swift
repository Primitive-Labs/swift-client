import Compression
import Foundation

/// Gzip (RFC 1952) decoding for update payloads the server parks in R2 and
/// stamps `X-Compressed: true`. The JS client gunzips these
/// (`decompressGzip` in `src/client/utils/binary.ts`); Swift used to drop the
/// frame, which is silently lossy the moment compression is turned on (#2661).
///
/// Only decoding is implemented — the client never compresses an upload.
enum Gzip {

    /// Decode one gzip member, or `nil` if the bytes are not a well-formed
    /// gzip stream. Callers treat `nil` like a dropped frame rather than
    /// applying partial output, so a truncated body can't reach a ydoc.
    ///
    /// - Parameter limit: The most bytes the member may decode to; decoding
    ///   stops, answering `nil`, the moment the output passes it.
    static func gunzip(_ data: Data, limit: Int? = nil) -> Data? {
        if case .inflated(let inflated) = gunzipBounded(data, limit: limit) { return inflated }
        return nil
    }

    /// What a bounded decode found.
    enum Bounded: Equatable {
        case inflated(Data)
        /// The output passed the limit; decoding stopped there.
        case pastLimit
        /// The bytes are not one well-formed gzip member.
        case unreadable
    }

    /// Decode one gzip member, stopping the moment the output passes `limit`
    /// so bytes from a caller that declare less than they inflate to are never
    /// held whole.
    static func gunzipBounded(_ data: Data, limit: Int? = nil) -> Bounded {
        // Offsets below are relative to `base`, not absolute: `data` may be a
        // slice, whose `startIndex` is not 0.
        let base = data.startIndex
        guard let headerLength = headerLength(data) else { return .unreadable }
        // 8-byte trailer: CRC-32 then ISIZE (uncompressed length mod 2^32).
        let deflateEnd = data.count - 8
        guard deflateEnd > headerLength else { return .unreadable }

        let inflated = inflateRaw(data[(base + headerLength)..<(base + deflateEnd)], limit: limit)
        guard case .inflated(let output) = inflated else { return inflated }

        let isize = readUInt32LE(data, at: data.count - 4)
        guard UInt32(truncatingIfNeeded: output.count) == isize else { return .unreadable }
        return inflated
    }

    /// Length of the header — the fixed 10 bytes plus whatever optional fields
    /// the FLG byte announces — or nil if these are not gzip bytes at all.
    private static func headerLength(_ data: Data) -> Int? {
        // 10-byte header + 8-byte trailer is the shortest possible member.
        guard data.count >= 18 else { return nil }
        let base = data.startIndex
        guard data[base] == 0x1f, data[base + 1] == 0x8b, data[base + 2] == 0x08 else { return nil }

        let flags = data[base + 3]
        var index = 10

        if flags & 0x04 != 0 {  // FEXTRA: 2-byte length then that many bytes
            guard index + 2 <= data.count else { return nil }
            let extraLength = Int(data[base + index]) | (Int(data[base + index + 1]) << 8)
            index += 2 + extraLength
        }
        if flags & 0x08 != 0 {  // FNAME: NUL-terminated
            guard let end = nulTerminator(data, from: index) else { return nil }
            index = end + 1
        }
        if flags & 0x10 != 0 {  // FCOMMENT: NUL-terminated
            guard let end = nulTerminator(data, from: index) else { return nil }
            index = end + 1
        }
        if flags & 0x02 != 0 {  // FHCRC: 2-byte header checksum
            index += 2
        }

        guard index < data.count else { return nil }
        return index
    }

    /// Offset of the next NUL byte at or after `start`, both relative to the
    /// data's own start index.
    private static func nulTerminator(_ data: Data, from start: Int) -> Int? {
        let base = data.startIndex
        var index = start
        while index < data.count {
            if data[base + index] == 0 { return index }
            index += 1
        }
        return nil
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    /// Streaming raw-DEFLATE decode. `COMPRESSION_ZLIB` is Apple's name for
    /// raw DEFLATE (no zlib wrapper), which is exactly what sits between a
    /// gzip header and its trailer.
    private static func inflateRaw(_ deflated: Data, limit: Int?) -> Bounded {
        let bufferSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(
            streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB
        ) == COMPRESSION_STATUS_OK else { return .unreadable }
        defer { compression_stream_destroy(streamPointer) }

        var output = Data()
        return deflated.withUnsafeBytes { raw -> Bounded in
            guard let input = raw.bindMemory(to: UInt8.self).baseAddress else { return .unreadable }
            streamPointer.pointee.src_ptr = input
            streamPointer.pointee.src_size = raw.count

            while true {
                streamPointer.pointee.dst_ptr = destination
                streamPointer.pointee.dst_size = bufferSize

                let status = compression_stream_process(
                    streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
                let produced = bufferSize - streamPointer.pointee.dst_size
                if produced > 0 {
                    output.append(destination, count: produced)
                }
                if let limit, output.count > limit { return .pastLimit }

                switch status {
                case COMPRESSION_STATUS_OK:
                    continue  // output buffer filled; drain and keep going
                case COMPRESSION_STATUS_END:
                    return .inflated(output)
                default:
                    return .unreadable  // truncated or corrupt input
                }
            }
        }
    }
}
