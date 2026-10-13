import Foundation

/// A storage provider that lets the record-log store group its saves into one
/// commit.
///
/// A format-3 save returns when its statements have run; it becomes durable
/// at a group commit shortly after, and saves issued together share that
/// commit. The group is a transaction held open on the provider's one
/// connection across saves, so it needs the provider's cooperation: any other
/// work on the provider's queue (a key-value write, a query)
/// closes the group before it runs, and never lands inside it.
///
/// Internal: the public ``StorageProvider`` and ``Format2SqlHost`` surfaces are
/// unchanged. A host that does not adopt it commits every save on its own.
protocol RecordLogGroupCommitHost: Format2SqlHost {
    /// The group commit of this host's connection: one per connection, shared
    /// by every format-3 document's store on it.
    var recordLogGroupCommit: RecordLogGroupCommit { get }

    /// Run `body` on the provider's queue with its connection, WITHOUT closing
    /// an open group first: the record-log store's own work, which joins it.
    func withRecordLogConnection<T>(_ body: (any Format2SqlConnection) throws -> T) throws -> T

    /// The commit to run before any other work on the queue. Called on the queue.
    func registerDeferredCommit(_ commit: @escaping (any Format2SqlConnection) -> Void)

    /// Forget the registered commit. Called on the queue.
    func clearDeferredCommit()

    /// Run `work` on the provider's queue after `milliseconds`.
    func scheduleOnQueue(afterMilliseconds milliseconds: Int, _ work: @escaping @Sendable () -> Void)
}

/// How the record-log store's transactions run on one connection: saves join
/// a group committed at `synchronous=NORMAL`, every other command commits on
/// its own at `NORMAL`, and the connection's own setting is put back after
/// each, so format-1 storage on the same connection commits as it always did.
///
/// **Saves.** The first save opens a group: it sets `PRAGMA synchronous=NORMAL`
/// (when the connection is not already there), issues `BEGIN IMMEDIATE`, and
/// registers a deferred commit with the host. Each save inside it is a
/// savepoint, so a save that throws removes only itself. The group commits at
/// the earliest of the commit timer, any record-log command that is not a
/// save, any other work on the host's queue (which the host closes the group
/// for), and an explicit ``flush(on:)``.
///
/// **Durability.** In WAL mode at `NORMAL` a commit is not synced to disk on
/// its own; it is durable at the next WAL checkpoint, or at the next commit
/// made at `FULL`. An app or process crash loses nothing; an OS crash or a
/// power loss may lose the last few groups. `fullfsync` is never set.
///
/// **Listeners.** A save's listener hears its group's outcome after the
/// `COMMIT` (or the rollback of a failed one), on the host's queue — so
/// nothing a save wrote is sent to the room before it is committed.
///
/// `@unchecked Sendable`: every mutable property below is read and written
/// only on the host's serial queue — inside ``RecordLogGroupCommitHost/withRecordLogConnection(_:)``,
/// a registered deferred commit, or the commit timer, all of which run there
/// (or, for a host that does not adopt the protocol, inside its
/// ``Format2SqlHost/withConnection(_:)``, whose contract is the same serial
/// queue). That queue is the lock; nothing here takes another.
final class RecordLogGroupCommit: @unchecked Sendable {

    /// The outcome a save's listener hears.
    typealias Listener = (Error?) -> Void

    private weak var host: (any RecordLogGroupCommitHost)?
    private let deferring: Bool
    /// How long a group stays open before its timer commits it. Set before
    /// the first save; a test lengthens it to hold a group open.
    var commitAfterMs: Int

    /// Depth of nested record-log calls on the queue; a nested call joins.
    private var depth = 0
    private var groupOpen = false
    private var generation = 0
    private var savepoints = 0
    /// The connection's own `synchronous`, to put back; `nil` when it was already `NORMAL`.
    private var restoreSynchronous: Int?
    /// The listeners of whatever transaction is open: the group's, or a command's.
    private var listeners: [Listener] = []
    private var _groupsCommitted = 0

    /// How many groups have committed: for a test that counts them.
    var groupsCommitted: Int { _groupsCommitted }

    /// Whether a group is open; read on the queue.
    var isGroupOpen: Bool { groupOpen }

    /// A group commit on `host`'s connection.
    init(host: any RecordLogGroupCommitHost, commitAfterMs: Int = RecordLogTransport.groupCommitMs) {
        self.host = host
        self.deferring = true
        self.commitAfterMs = commitAfterMs
    }

    /// A runner for a host that cannot defer a commit: every save commits on its own.
    init() {
        self.host = nil
        self.deferring = false
        self.commitAfterMs = 0
    }

    // MARK: - Running

    /// Run `body` as a save: in the open group (opening one), as a savepoint.
    /// A nested call joins whatever is open.
    func save<T>(_ connection: any Format2SqlConnection, listener: Listener? = nil, _ body: () throws -> T) throws -> T {
        if depth > 0 { return try nested(listener, body) }
        guard deferring else { return try command(connection, listener: listener, body) }
        if !groupOpen { try open(connection) }
        savepoints += 1
        let name = "record_log_save_\(savepoints)"
        try connection.executeScript("SAVEPOINT \(name)")
        depth = 1
        defer { depth = 0 }
        do {
            let value = try body()
            try connection.executeScript("RELEASE \(name)")
            if let listener { listeners.append(listener) }
            return value
        } catch {
            try? connection.executeScript("ROLLBACK TO \(name)")
            try? connection.executeScript("RELEASE \(name)")
            throw error
        }
    }

    /// Run `body` as a command of its own: the open group commits first, then
    /// `body` runs in its own transaction at `NORMAL`. A nested call joins.
    func command<T>(_ connection: any Format2SqlConnection, listener: Listener? = nil, _ body: () throws -> T) throws -> T {
        if depth > 0 { return try nested(listener, body) }
        commitGroup(connection)
        let previous = try normal(connection)
        do {
            try connection.executeScript("BEGIN IMMEDIATE")
        } catch {
            restore(connection, previous)
            throw error
        }
        depth = 1
        if let listener { listeners.append(listener) }
        let value: T
        do {
            value = try body()
            depth = 0
            try connection.executeScript("COMMIT")
        } catch {
            depth = 0
            try? connection.executeScript("ROLLBACK")
            restore(connection, previous)
            let heard = listeners
            listeners = []
            for listener in heard { listener(error) }
            throw error
        }
        restore(connection, previous)
        let heard = listeners
        listeners = []
        for listener in heard { listener(nil) }
        return value
    }

    /// Run `body` with no transaction of its own — a read. It sees whatever the
    /// open group has written, on the same connection.
    func read<T>(_ body: () throws -> T) throws -> T {
        depth += 1
        defer { depth -= 1 }
        return try body()
    }

    private func nested<T>(_ listener: Listener?, _ body: () throws -> T) throws -> T {
        depth += 1
        defer { depth -= 1 }
        let value = try body()
        if let listener { listeners.append(listener) }
        return value
    }

    /// Commit the open group now, if there is one. Called on the queue.
    func flush(on connection: any Format2SqlConnection) {
        guard depth == 0 else { return }
        commitGroup(connection)
    }

    // MARK: - The group

    private func open(_ connection: any Format2SqlConnection) throws {
        let previous = try normal(connection)
        do {
            try connection.executeScript("BEGIN IMMEDIATE")
        } catch {
            restore(connection, previous)
            throw error
        }
        restoreSynchronous = previous
        groupOpen = true
        generation += 1
        let opened = generation
        guard let host else { return }
        host.registerDeferredCommit { [weak self] connection in
            self?.commitGroup(connection)
        }
        host.scheduleOnQueue(afterMilliseconds: commitAfterMs) { [weak self, weak host] in
            guard let self, let host else { return }
            _ = try? host.withRecordLogConnection { connection in
                guard self.groupOpen, self.generation == opened, self.depth == 0 else { return }
                self.commitGroup(connection)
            }
        }
    }

    private func commitGroup(_ connection: any Format2SqlConnection) {
        guard groupOpen else { return }
        groupOpen = false
        host?.clearDeferredCommit()
        let heard = listeners
        listeners = []
        var failure: Error?
        do {
            try connection.executeScript("COMMIT")
            _groupsCommitted += 1
        } catch {
            failure = error
            try? connection.executeScript("ROLLBACK")
        }
        restore(connection, restoreSynchronous)
        restoreSynchronous = nil
        for listener in heard { listener(failure) }
    }

    // MARK: - synchronous

    /// Put the connection at `NORMAL`; answers the setting to put back, or
    /// `nil` when it was already there.
    private func normal(_ connection: any Format2SqlConnection) throws -> Int? {
        let current = try connection.query("PRAGMA synchronous").first?["synchronous"].intValue
        guard current != 1 else { return nil }
        try connection.executeScript("PRAGMA synchronous=NORMAL")
        return current
    }

    private func restore(_ connection: any Format2SqlConnection, _ previous: Int?) {
        guard let previous else { return }
        try? connection.executeScript("PRAGMA synchronous=\(previous)")
    }
}
