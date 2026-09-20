import Foundation

/// Reading a base snapshot through the ONE grant the handshake minted for it
/// (#3436, behavior 23, edge E10).
///
/// The manifest is at the grant path itself and chunk `n` of model `M` at
/// `{path}/{M}/{n}`, or at the sourced form when the build carried that chunk
/// forward from an earlier one. That addressing is this type's whole job.
///
/// What a refused signature means is NOT: that rule lives in
/// ``Format2ArtifactReader``, because a sealed epoch's archive is read by the
/// same rule (#3437, behavior 15) and two descriptions of "refresh once" would
/// be two chances to disagree about it.
final class Format2SnapshotSource: @unchecked Sendable {

    /// What one read answered. The reader's type, so a caller that stubs reads
    /// for a base and for an archive writes one kind of answer.
    typealias Answer = Format2ArtifactReader.Answer

    static var grantRefusedStatuses: Set<Int> { Format2ArtifactReader.grantRefusedStatuses }

    private let reader: Format2ArtifactReader

    /// - Parameters:
    ///   - grantPath: the origin-relative signed path `epoch.info` offered.
    ///   - read: perform one read. Injected so the addressing can be stated
    ///     without a server, which is the half that decides what is read.
    ///   - refreshGrant: ask the room for fresh grants; the new path, or `nil`
    ///     when none came back.
    init(
        apiUrl: String,
        documentId: String,
        grantPath: String,
        logger: Logger? = nil,
        read: @escaping (URL) throws -> Answer,
        refreshGrant: @escaping () throws -> String? = { nil }
    ) {
        self.reader = Format2ArtifactReader(
            apiUrl: apiUrl,
            documentId: documentId,
            grantPath: grantPath,
            logger: logger,
            read: read,
            refreshGrant: refreshGrant
        )
    }

    /// The path currently held for this build's artifacts.
    var grantPath: String { reader.grantPath }

    /// Where the manifest is: the grant path itself.
    func manifestURL() throws -> URL { try reader.url() }

    /// Where one chunk is, within the grant for its build.
    func chunkURL(_ chunk: SnapshotChunkEntry) throws -> URL {
        try reader.url(suffix: "/\(snapshotChunkPath(chunk))")
    }

    /// Read the manifest, decoded and validated.
    func manifest() throws -> SnapshotManifest {
        let answer = try reader.read(what: "the snapshot manifest")
        return try SnapshotManifest.decode(bytes: answer.body)
    }

    /// Read one chunk's bytes. The loader owns what happens to them.
    func fetchChunk(_ chunk: SnapshotChunkEntry) throws -> Data {
        try reader.read(
            suffix: "/\(snapshotChunkPath(chunk))",
            // Named by its PLACE, never its key or its grant path: this string
            // reaches a log line and an error an application may record.
            what: "snapshot chunk {model: \(chunk.model), ordinal: "
                + "\(chunk.ordinal.map(String.init) ?? "?")}"
        ).body
    }

    /// The ordinary transport. See ``Format2ArtifactReader/urlSessionReader()``.
    static func urlSessionReader() -> (URL) throws -> Answer {
        Format2ArtifactReader.urlSessionReader()
    }
}
