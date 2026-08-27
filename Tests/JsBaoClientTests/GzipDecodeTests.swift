import Foundation
import XCTest
@testable import JsBaoClient

/// #2661 — `Gzip.gunzip` against gzip bytes this repo did **not** produce.
///
/// `CompressedUpdateDownloadTests` builds its fixture with the same
/// `Compression` framework the decoder uses, so on its own it cannot tell a
/// working decoder from two halves of one private convention. The blob below
/// comes from Node's `zlib.gzipSync` — the same library the server would
/// compress an R2 object with — so it pins interoperability with a standard
/// gzip member.
final class GzipDecodeTests: XCTestCase {

    /// Produced with:
    ///   node -e "const z=require('zlib');console.log(
    ///     z.gzipSync(Buffer.from('the quick brown fox jumps over the lazy dog, 2661')
    ///   ).toString('base64'))"
    private let nodeGzipBase64 = """
    H4sIAAAAAAAAEyvJSFUoLM1MzlZIKsovz1NIy69QyCrNLShWyC9LLVIoAUrnJFZVKqTkp+soGJmZGQIAqdG47jEAAAA=
    """
    private let plaintext = "the quick brown fox jumps over the lazy dog, 2661"

    func testDecodesAGzipMemberProducedByNodeZlib() throws {
        let compressed = try XCTUnwrap(Data(base64Encoded: nodeGzipBase64))
        let inflated = try XCTUnwrap(
            Gzip.gunzip(compressed),
            "a standard gzip body must decode — the deflate stream inside a gzip member is raw"
        )
        XCTAssertEqual(String(data: inflated, encoding: .utf8), plaintext)
    }

    /// The decoder is handed a `Data` slice whenever a caller has already
    /// sliced the response body, and slices do not start at index 0.
    func testDecodesASliceWhoseStartIndexIsNotZero() throws {
        let compressed = try XCTUnwrap(Data(base64Encoded: nodeGzipBase64))
        var padded = Data([0xaa, 0xbb, 0xcc])
        padded.append(compressed)
        let slice = padded[3...]

        let inflated = try XCTUnwrap(Gzip.gunzip(slice))
        XCTAssertEqual(String(data: inflated, encoding: .utf8), plaintext)
    }

    func testRejectsBytesThatAreNotGzip() {
        XCTAssertNil(Gzip.gunzip(Data(repeating: 0x41, count: 64)))
        XCTAssertNil(Gzip.gunzip(Data()))
    }

    func testRejectsATruncatedMember() throws {
        var compressed = try XCTUnwrap(Data(base64Encoded: nodeGzipBase64))
        compressed.removeLast(12)
        XCTAssertNil(Gzip.gunzip(compressed))
    }

    /// A member whose trailer claims a different length than the stream
    /// produces is corrupt; applying the bytes anyway is how a truncated
    /// update reaches a ydoc.
    func testRejectsAMemberWithAMismatchedIsize() throws {
        var compressed = try XCTUnwrap(Data(base64Encoded: nodeGzipBase64))
        compressed[compressed.count - 4] = compressed[compressed.count - 4] &+ 1
        XCTAssertNil(Gzip.gunzip(compressed))
    }
}
