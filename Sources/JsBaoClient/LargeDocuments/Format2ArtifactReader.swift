import Foundation

/// Reading one of a document's artifacts through the grant the room minted for
/// it (#3436 behavior 23 and edge E10, #3437 behavior 15).
///
/// The client never learns an R2 key. `epoch.info` hands it origin-relative
/// paths carrying expiring signatures — the room is a Durable Object and has no
/// reliable idea which host this client reached it through, while this client
/// knows exactly.
///
/// ## Why a refused signature is a step and not a failure
///
/// The signature lives about an hour: long enough to download megabytes with
/// retries, short enough that a leaked URL is not a standing read of the
/// document. A base of the size this whole design exists for takes longer than
/// that on an ordinary connection, and so can a CHAIN of sealed archives, so
/// treating an expiry as an error would break exactly the loads that matter and
/// restarting on one would mean never finishing. Asking the room for fresh
/// grants over the socket that is already open and repeating the one read that
/// was refused costs nothing already committed.
///
/// ONCE, though. A second refusal with a grant just minted is not an expiry —
/// it is something else, and a reader that kept spinning on it would be
/// indistinguishable from one that had hung. The refusal that comes back then
/// is reported with the status the FIRST read was refused with, which is the
/// one that says what happened.
///
/// This type is the RULE, and only the rule. `Format2SnapshotSource` reads a
/// manifest and its chunks through one of these; a catch-up reads each sealed
/// epoch's archive through one of these; and there is exactly one description
/// of what a refused signature means.
final class Format2ArtifactReader: @unchecked Sendable {

    /// What one read of an artifact answered.
    struct Answer: Sendable {
        let status: Int
        let body: Data

        init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }

        var ok: Bool { status >= 200 && status < 300 }
    }

    /// Statuses that mean "this signature is no longer good", and only those.
    /// A 404 means something a new signature cannot fix — retention has taken
    /// the object — and a 500 is the server's problem, not the grant's.
    static let grantRefusedStatuses: Set<Int> = [401, 403]

    private let apiUrl: String
    private let documentId: String
    private let performRead: (URL) throws -> Answer
    private let refreshGrant: () throws -> String?
    private let logger: Logger?

    private let lock = NSLock()
    private var granted: String

    /// - Parameters:
    ///   - grantPath: the origin-relative signed path the room offered.
    ///   - read: perform one read. Injected so the addressing can be stated
    ///     without a server, which is the half that decides what is read.
    ///   - refreshGrant: ask the room for fresh grants; the new path for this
    ///     artifact, or `nil` when none came back.
    init(
        apiUrl: String,
        documentId: String,
        grantPath: String,
        logger: Logger? = nil,
        read: @escaping (URL) throws -> Answer,
        refreshGrant: @escaping () throws -> String? = { nil }
    ) {
        self.apiUrl = apiUrl
        self.documentId = documentId
        self.granted = grantPath
        self.logger = logger
        self.performRead = read
        self.refreshGrant = refreshGrant
    }

    /// The path currently held for this artifact.
    var grantPath: String { lock.withLock { granted } }

    /// Where `suffix` is, within the grant currently held.
    func url(suffix: String = "") throws -> URL {
        let path = lock.withLock { granted }
        guard let base = URL(string: apiUrl),
              let resolved = URL(string: path + suffix, relativeTo: base)
        else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "Document `\(documentId)` was given an artifact grant "
                    + "that is not a usable path."
            )
        }
        return resolved.absoluteURL
    }

    /// Read `suffix` under the held grant, refreshing the signature once if it
    /// is refused.
    ///
    /// - Parameter what: how the artifact is named in a log line and in the
    ///   refusal an application may record. Named by its PLACE, never by its
    ///   key or its grant path.
    func read(suffix: String = "", what: String) throws -> Answer {
        let first = try performRead(try url(suffix: suffix))
        if first.ok { return first }
        guard Format2ArtifactReader.grantRefusedStatuses.contains(first.status) else {
            throw failed(what: what, status: first.status)
        }
        logger?.debug(
            "[format2] the grant for", documentId, "was refused reading", what,
            "— asking the room for a fresh one"
        )
        // A refresh that yields nothing leaves the held grant in place, and the
        // one retry happens anyway: the room may have re-minted the same path,
        // and a read that fails again is reported with the status that said
        // what happened.
        if let fresh = try refreshGrant(), !fresh.isEmpty {
            lock.withLock { granted = fresh }
        }
        let second = try performRead(try url(suffix: suffix))
        if second.ok { return second }
        throw failed(what: what, status: first.status)
    }

    private func failed(what: String, status: Int) -> JsBaoError {
        JsBaoError(
            code: .unavailable,
            message: "Reading \(what) of \(documentId) failed: \(status)",
            details: [
                "documentId": .string(documentId),
                "status": .number(Double(status)),
            ]
        )
    }

    /// The ordinary transport: one read per artifact, through the client's one
    /// `NetworkSession` helper, so a failed read surfaces as `JsBaoNetworkError`
    /// rather than a raw `URLError` like every other HTTP path in this client.
    ///
    /// BLOCKING, and deliberately so. The loader and the chain are synchronous
    /// because the store they write into is — every chunk's rows and its mark
    /// are ONE SQLite transaction on the provider's own serial queue — and
    /// making them asynchronous would put an `await` between them. The caller
    /// runs the whole load on a plain dispatch queue, off both the socket's
    /// receive loop and the cooperative pool, so the thread this parks is one
    /// nothing else is waiting on.
    static func urlSessionReader() -> (URL) throws -> Answer {
        { url in
            let semaphore = DispatchSemaphore(value: 0)
            let outcome = ReadOutcome()
            Task.detached(priority: .utility) {
                do {
                    let (data, response) = try await NetworkSession.data(from: url)
                    outcome.answered(Answer(
                        status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                        body: data
                    ))
                } catch {
                    outcome.failed(error)
                }
                semaphore.signal()
            }
            semaphore.wait()
            return try outcome.resolve()
        }
    }

    /// Where the awaited read hands its result back across the wait.
    private final class ReadOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: Answer?
        private var failure: Error?

        func answered(_ answer: Answer) { lock.withLock { self.answer = answer } }
        func failed(_ error: Error) { lock.withLock { self.failure = error } }

        func resolve() throws -> Answer {
            try lock.withLock {
                if let failure { throw failure }
                return answer ?? Answer(status: 0, body: Data())
            }
        }
    }
}
