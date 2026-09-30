import XCTest
@testable import JsBaoClient

/// The server's `code` survives the Swift client's blob paths (#3403).
///
/// `HttpClient` parses every failure body through `HttpError.parseBody`, so a
/// refusal on the JSON spine reaches the app with `serverCode` set. The blob
/// transfers do not go through that spine — they read raw bytes — and each
/// built its `HttpError` by hand from a fixed message, keeping at most the raw
/// `body` string and never the parsed cause. An app branching on
/// `error.serverCode` therefore saw `nil` for every blob refusal the server
/// named, which is the CLI's four-blob-method gap in the other supported
/// client.
///
/// Server-free: every call runs over a `RecordingTransport`, so what is
/// asserted is exactly the bytes the route sends.
final class ErrorCodeBlobPathsHermeticTests: XCTestCase {

    private func envelope(
        _ error: String,
        _ status: Int,
        _ code: String
    ) -> String {
        """
        {"error":"\(error)","status":\(status),"code":"\(code)",\
        "timestamp":"2026-09-19T00:00:00.000Z"}
        """
    }

    private func transport(status: Int, json: String) -> RecordingTransport {
        RecordingTransport(status: status, json: json)
    }

    // MARK: - Bucket blobs

    func testBucketDownloadRefusalCarriesTheServerCode() async throws {
        let api = BlobBucketsAPI(
            transport: transport(
                status: 403,
                json: envelope("Access denied to this bucket", 403, "BLOB_ACCESS_DENIED")
            )
        )

        do {
            _ = try await api.download(bucketIdOrKey: "avatars", blobId: "b1")
            XCTFail("a refused download must throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(
                error.serverCode, "BLOB_ACCESS_DENIED",
                "the machine-readable cause must reach the app"
            )
            XCTAssertEqual(error.serverMessage, "Access denied to this bucket")
            XCTAssertNotNil(error.body, "the raw body stays attached")
        }
    }

    func testBucketUploadRefusalCarriesTheServerCode() async throws {
        let api = BlobBucketsAPI(
            transport: transport(
                status: 413,
                json: envelope("Blob exceeds the maximum size", 413, "PAYLOAD_TOO_LARGE")
            )
        )

        do {
            _ = try await api.upload(
                bucketIdOrKey: "avatars",
                data: Data([1, 2, 3]),
                filename: "a.png"
            )
            XCTFail("a refused upload must throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 413)
            XCTAssertEqual(error.serverCode, "PAYLOAD_TOO_LARGE")
            XCTAssertEqual(error.serverMessage, "Blob exceeds the maximum size")
        }
    }

    // MARK: - Document blobs

    func testDocumentBlobUploadRefusalCarriesTheServerCode() async throws {
        let manager = BlobManager(
            logger: Logger(level: .error, scope: "test"),
            transport: transport(
                status: 403,
                json: envelope("Access denied to this document", 403, "DOC_ACCESS_DENIED")
            )
        )

        do {
            _ = try await manager.uploadImmediate(
                documentId: "doc-1",
                blobId: "blob-1",
                data: Data([1, 2, 3])
            )
            XCTFail("a refused upload must throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.serverCode, "DOC_ACCESS_DENIED")
            XCTAssertEqual(error.serverMessage, "Access denied to this document")
        }
    }

    // MARK: - An uncoded body is still an uncoded error

    func testANonJsonBodyLeavesTheCodeNil() async throws {
        // An older server, or an intermediary that answered on its own.
        let api = BlobBucketsAPI(transport: transport(status: 502, json: "upstream is down"))

        do {
            _ = try await api.download(bucketIdOrKey: "avatars", blobId: "b1")
            XCTFail("a refused download must throw")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 502)
            XCTAssertNil(error.serverCode)
            XCTAssertEqual(
                error.message, "Blob download failed",
                "the message existing callers match on is unchanged"
            )
        }
    }

    // MARK: - The fourth site, which reads its bytes off `NetworkSession`

    /// `BlobManager.download` builds its own `URLRequest` rather than going
    /// through the transport, so it cannot be driven by `RecordingTransport`.
    /// Its body was discarded outright — not even `body` was kept — so this
    /// holds the source to the same parse the three sites above are asserted
    /// through, the way `ActorizedBlobManagerTests` holds this file to its
    /// construction shape.
    func testTheNetworkSessionDownloadParsesItsBodyToo() throws {
        let path = #filePath.replacingOccurrences(
            of: "Tests/JsBaoClientTests/ErrorCodeBlobPathsHermeticTests.swift",
            with: "Sources/JsBaoClient/Internal/BlobManager.swift"
        )
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .components(separatedBy: "\n")
        let failureLines = lines.indices.filter {
            lines[$0].contains("Blob download failed")
        }
        XCTAssertFalse(
            failureLines.isEmpty,
            "BlobManager no longer answers a failed download with that message"
        )
        for index in failureLines {
            let window = lines[max(0, index - 4)...min(lines.count - 1, index + 4)]
                .joined(separator: "\n")
            XCTAssertTrue(
                window.contains("fromBytes(") || window.contains("serverCode:"),
                "a failed download must carry the server's parsed code, not just a status "
                    + "(BlobManager.swift:\(index + 1))"
            )
        }
    }
}
