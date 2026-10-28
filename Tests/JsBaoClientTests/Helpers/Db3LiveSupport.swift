import Foundation
import XCTest
@testable import JsBaoClient

/// What the live `client.db3` suites share: db3s written through the room's
/// `submit` route, the room's subscriber count, a db3 made resident and
/// unsubscribed, frame gates, and outcomes read as codes.
extension RecordLogLiveApp {
    static func ulid() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return "01" + String((0..<24).map { _ in alphabet[Int.random(in: 0..<32)] })
    }

    /// Write `rows` records of `model` (`p000001`…, `title: "row n"`) to `documentId` through the room's `submit` route.
    func submit(_ documentId: String, model: String, rows: Int, from first: Int = 1) async throws {
        let writer = Self.ulid()
        var seq = 0
        var at = first
        while at < first + rows {
            let count = min(500, first + rows - at)
            let mutations: [[String: Any]] = (at..<(at + count)).map { n in
                ["model": model, "id": String(format: "p%06d", n), "kind": "create", "fields": ["title": "row \(n)"]]
            }
            let state = try await route(documentId, "state")
            let epochs = state["epochs"] as? [String: Any] ?? [:]
            seq += 1
            let answered = try await route(documentId, "submit", [
                "writer": writer,
                "entry": [
                    "seq": seq, "e": (epochs["current"] as? NSNumber)?.intValue ?? 1, "k": (state["lsn"] as? NSNumber)?.intValue ?? 0,
                    "m": mutations[0], "also": Array(mutations.dropFirst()),
                ] as [String: Any],
            ])
            XCTAssertEqual((answered["outcome"] as? [String: Any])?["status"] as? String, "accepted")
            at += count
        }
    }

    /// A db3 created by its own client, with `rows` records of `model` written through the room, paged `pageRows` to a page.
    func db3Written(_ rows: Int, model: String, pageRows: Int = 100) async throws -> String {
        let creator = try await client("creator-\(Self.ulid().suffix(4))", models: [])
        let documentId = try await createDocument(creator)
        _ = try await route(documentId, "set-limits", ["segmentQuietMs": 3_600_000, "catchUpPageRows": pageRows])
        if rows > 0 { try await submit(documentId, model: model, rows: rows) }
        return documentId
    }

    func subscribers(_ id: String) async throws -> Int {
        (try await route(id, "state")["subscribers"] as? [Any])?.count ?? -1
    }

    func subscribersBecome(_ id: String, _ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await eventually(timeout: 15, description: "\(count) room subscriber(s) of \(id)") {
            try await self.subscribers(id) == count
        }
    }

    /// Subscribe, wait for live, dispose: the db3 is resident and unsubscribed.
    func residentOn(_ client: JsBaoClient, _ id: String) async throws {
        let handle = try client.db3.subscribe(id)
        try await handle.ready()
        handle.dispose()
        try await eventually(description: "\(id) to be unsubscribed") {
            let state = try await client.db3.state(id)
            return !state.subscribed && state.phase == .idle
        }
    }
}

/// Drop or hold a client's record frames before its sessions see them.
final class Db3FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    // `@unchecked Sendable`: the rules are read and written under `lock`.
    private var rules: [(UUID, @Sendable ([String: JSONValue]) -> Bool)] = []

    init(_ client: JsBaoClient) {
        client.recordLogFrameGateForTest = { [weak self] frame in
            guard let self else { return true }
            let rules = self.lock.withLock { self.rules }
            return !rules.contains { $0.1(frame) }
        }
    }

    /// Drop every frame `match` takes until the answered stop is called.
    @discardableResult
    func drop(_ match: @escaping @Sendable ([String: JSONValue]) -> Bool) -> @Sendable () -> Void {
        let token = UUID()
        lock.withLock { rules.append((token, match)) }
        return { [weak self] in self?.lock.withLock { self?.rules.removeAll { $0.0 == token } } }
    }

    /// Every record frame of `id`.
    static func of(_ id: String) -> @Sendable ([String: JSONValue]) -> Bool {
        { $0["documentId"]?.stringValue == id && ($0["type"]?.stringValue?.hasPrefix("record.") ?? false) }
    }
}

/// An outcome as a code: `"resolved"`, or the thrown `JsBaoError`'s code.
func db3Outcome(_ body: () async throws -> Void) async -> String {
    do {
        try await body()
        return "resolved"
    } catch {
        return (error as? JsBaoError)?.code.rawValue ?? "\(error)"
    }
}
