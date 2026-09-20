import XCTest
@testable import JsBaoClient

/// Where a base snapshot's artifacts are read from, and what happens when the
/// signature that authorizes a read expires under one (#3436, behavior 23,
/// edge E10).
///
/// The client never learns an R2 key: `epoch.info` hands it an origin-relative
/// signed path, the manifest is at that path and a chunk is under it. Getting
/// the addressing wrong is not a visible failure — it is a read of a DIFFERENT
/// build's chunk, which then fails its digest check for a reason that looks
/// like corruption. #3433 lost five agent runs to exactly that, in a test
/// helper that re-derived the address the product already computes.
final class Format2SnapshotSourceHermeticTests: XCTestCase {

    private func chunk(
        model: String = "Note",
        ordinal: Int = 3,
        path: String? = "Note/3",
        key: String = "app/doc/7-b1/Note/3.ndjson.gz"
    ) -> SnapshotChunkEntry {
        SnapshotChunkEntry(
            key: key, path: path, ordinal: ordinal, model: model,
            bytes: 10, rows: 1, firstId: "a", lastId: "a", sha256: "x"
        )
    }

    /// A source over a recording reader.
    private func source(
        grantPath: String = "/artifact/tok-1",
        answers: @escaping (URL, Int) -> Format2SnapshotSource.Answer,
        refresh: @escaping () -> String? = { nil },
        reads: NSMutableArray = NSMutableArray()
    ) -> (Format2SnapshotSource, NSMutableArray) {
        var attempt = 0
        let source = Format2SnapshotSource(
            apiUrl: "https://api.example.test",
            documentId: "doc-1",
            grantPath: grantPath,
            read: { url in
                reads.add(url.absoluteString)
                defer { attempt += 1 }
                return answers(url, attempt)
            },
            refreshGrant: { refresh() }
        )
        return (source, reads)
    }

    private func ok(_ body: String = "{}") -> Format2SnapshotSource.Answer {
        Format2SnapshotSource.Answer(status: 200, body: Data(body.utf8))
    }

    // MARK: - Behavior 23 — addressing

    func testTheManifestIsAtTheGrantPathAndAChunkIsUnderIt() throws {
        let (source, _) = self.source(answers: { _, _ in self.ok() })
        XCTAssertEqual(
            try source.manifestURL().absoluteString,
            "https://api.example.test/artifact/tok-1"
        )
        XCTAssertEqual(
            try source.chunkURL(chunk()).absoluteString,
            "https://api.example.test/artifact/tok-1/Note/3"
        )
    }

    /// The entry's own `path` wins: the KEY of a reused entry names an object
    /// under a build the grant is not for, and asking the granted build for
    /// its own chunk `n` reads a different object that then fails its digest.
    func testAReusedChunkIsAddressedByItsSourcedPathAndNotItsKey() throws {
        let (source, _) = self.source(answers: { _, _ in self.ok() })
        let reused = SnapshotChunkEntry(
            key: "app/doc/4-older/Note/1.ndjson.gz",
            path: "4-older/Note/1", ordinal: 9, model: "Note",
            bytes: 10, rows: 1, firstId: "a", lastId: "a", sha256: "x"
        )
        XCTAssertEqual(
            try source.chunkURL(reused).absoluteString,
            "https://api.example.test/artifact/tok-1/4-older/Note/1"
        )
    }

    func testAManifestWrittenBeforePathsExistedIsAddressedFromItsKey() throws {
        let (source, _) = self.source(answers: { _, _ in self.ok() })
        XCTAssertEqual(
            try source.chunkURL(chunk(path: nil)).absoluteString,
            "https://api.example.test/artifact/tok-1/Note/3"
        )
    }

    func testAnUnaddressableEntryIsRefusedRatherThanGuessedAt() {
        let (source, reads) = self.source(answers: { _, _ in self.ok() })
        XCTAssertThrowsError(
            try source.fetchChunk(chunk(path: "../elsewhere/0"))
        ) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .snapshotManifestInvalid)
        }
        XCTAssertEqual(reads.count, 0, "nothing was read for an entry with no address")
    }

    // MARK: - Behavior 23 — the grant refresh

    func testARefusedSignatureIsRenewedOnceAndTheReadRepeated() throws {
        let (source, reads) = self.source(
            answers: { url, attempt in
                if attempt == 0 {
                    return Format2SnapshotSource.Answer(status: 403, body: Data())
                }
                XCTAssertTrue(url.absoluteString.contains("tok-2"))
                return self.ok("chunk bytes")
            },
            refresh: { "/artifact/tok-2" }
        )
        XCTAssertEqual(try source.fetchChunk(chunk()), Data("chunk bytes".utf8))
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(reads[0] as? String, "https://api.example.test/artifact/tok-1/Note/3")
        XCTAssertEqual(reads[1] as? String, "https://api.example.test/artifact/tok-2/Note/3")
        // And the fresh grant is the one every LATER read uses, so a load of
        // hundreds of chunks pays the refresh once rather than per chunk.
        XCTAssertEqual(source.grantPath, "/artifact/tok-2")
    }

    func testA401IsARefusedSignatureToo() throws {
        let (source, reads) = self.source(
            answers: { _, attempt in
                attempt == 0
                    ? Format2SnapshotSource.Answer(status: 401, body: Data())
                    : self.ok("bytes")
            },
            refresh: { "/artifact/tok-2" }
        )
        XCTAssertEqual(try source.fetchChunk(chunk()), Data("bytes".utf8))
        XCTAssertEqual(reads.count, 2)
    }

    /// A 404 means something a new signature cannot fix — retention has taken
    /// the object — so it is reported rather than retried.
    func testAStatusThatIsNotASignatureRefusalIsNotRetried() {
        var refreshed = 0
        let (source, reads) = self.source(
            answers: { _, _ in Format2SnapshotSource.Answer(status: 404, body: Data()) },
            refresh: { refreshed += 1; return "/artifact/tok-2" }
        )
        XCTAssertThrowsError(try source.fetchChunk(chunk())) { error in
            let failure = error as? JsBaoError
            XCTAssertEqual(failure?.code, .unavailable)
            XCTAssertEqual(failure?.details?["status"], .number(404))
        }
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(refreshed, 0)
    }

    /// Edge E10 — never more than one retry per read, and the refusal carries
    /// the status the FIRST read was refused with, which is the one that says
    /// what happened.
    func testASecondRefusalIsReportedWithTheOriginalStatusAndNotRetriedAgain() {
        var refreshed = 0
        let (source, reads) = self.source(
            answers: { _, _ in Format2SnapshotSource.Answer(status: 403, body: Data()) },
            refresh: { refreshed += 1; return "/artifact/tok-\(refreshed + 1)" }
        )
        XCTAssertThrowsError(try source.fetchChunk(chunk())) { error in
            let failure = error as? JsBaoError
            XCTAssertEqual(failure?.details?["status"], .number(403))
            // The message names the chunk's PLACE, never its key or the
            // signed path it was read at.
            XCTAssertTrue(failure?.message.contains("{model: Note, ordinal: 3}") == true)
            XCTAssertFalse(failure?.message.contains("tok-") == true)
            XCTAssertFalse(failure?.message.contains("app/doc") == true)
        }
        XCTAssertEqual(reads.count, 2, "one retry, never a loop")
        XCTAssertEqual(refreshed, 1)
    }

    /// Edge E10 — a refresh that yields no new path fails with the original
    /// status rather than hanging or refusing differently.
    func testARefreshThatYieldsNoNewPathFailsWithTheOriginalStatus() {
        let (source, reads) = self.source(
            answers: { _, _ in Format2SnapshotSource.Answer(status: 403, body: Data()) },
            refresh: { nil }
        )
        XCTAssertThrowsError(try source.fetchChunk(chunk())) { error in
            XCTAssertEqual((error as? JsBaoError)?.details?["status"], .number(403))
        }
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(source.grantPath, "/artifact/tok-1")
    }

    // MARK: - The manifest read

    func testTheManifestIsDecodedAndValidatedAsItIsRead() throws {
        let manifest: [String: Any] = [
            "version": 3, "epoch": 7, "buildId": "b1", "createdAt": 0,
            "schema": [:], "chunks": [], "totals": ["rows": 0, "bytes": 0],
        ]
        let (source, _) = self.source(answers: { _, _ in
            Format2SnapshotSource.Answer(
                status: 200,
                body: try! JSONSerialization.data(withJSONObject: manifest)
            )
        })
        XCTAssertEqual(try source.manifest().buildId, "b1")

        var broken = manifest
        broken["version"] = 99
        let (refusing, _) = self.source(answers: { _, _ in
            Format2SnapshotSource.Answer(
                status: 200,
                body: try! JSONSerialization.data(withJSONObject: broken)
            )
        })
        XCTAssertThrowsError(try refusing.manifest()) { error in
            XCTAssertEqual((error as? JsBaoError)?.code, .snapshotManifestUnsupported)
        }
    }
}
