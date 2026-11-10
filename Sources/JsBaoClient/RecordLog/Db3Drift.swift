import Foundation

// Drift on a device answer (#5221): how far a db3 copy read on this device is
// behind the server, computed from the sync state a read captured with its
// rows, and the `maxDrift` refusal judged on it. A port of js-bao's
// `models/db3Drift.ts`.
//
// - A synced db3's drift is `entriesBehind = max(0, knownHead − cursor)`, a
//   lower bound, as of when the head was heard, `live` while this client's
//   session of it is open, with its unjudged writes. A synced db3 that has not
//   heard a head, and a db3 that lives only on this device, have none.
// - `maxDrift` is checked before any read; once the read answered, each db3 of
//   its scope is judged in scope order: a synced db3 with no head heard is
//   refused, one past `entries` or `age` is refused, a local-only db3 passes.
//   Nothing waits.

enum Db3DriftJudge {

    /// `maxDrift` as a read takes it, refused `.invalidArgument` before any
    /// read when a bound is negative or not finite.
    static func checked(_ maxDrift: Db3MaxDrift?) throws -> Db3MaxDrift? {
        guard let maxDrift else { return nil }
        if let entries = maxDrift.entries, entries < 0 {
            throw JsBaoError(
                code: .invalidArgument, message: "Invalid options.maxDrift.entries: must be a non-negative integer",
                details: ["entries": .number(Double(entries))]
            )
        }
        if let age = maxDrift.age, !age.isFinite || age < 0 {
            throw JsBaoError(code: .invalidArgument, message: "Invalid options.maxDrift.age: must be a non-negative finite number of seconds")
        }
        return maxDrift
    }

    /// One db3's drift from the sync state a read captured, or `nil` when it
    /// has none (local-only, or no head heard).
    static func of(_ sync: RecordLogDocumentSync?, live: Bool) -> Db3Drift? {
        guard let sync, !sync.localOnly, let head = sync.knownHead else { return nil }
        return Db3Drift(
            entriesBehind: max(0, head - sync.cursor),
            asOf: Date(timeIntervalSince1970: Double(sync.knownHeadAt ?? 0) / 1000),
            live: live,
            pendingWrites: sync.pendingWrites
        )
    }

    /// A page's `drift`: each of `documents` with a drift, by db3 id.
    static func drift(
        _ documents: [String], _ sync: [String: RecordLogDocumentSync], live: (String) -> Bool
    ) -> [String: Db3Drift] {
        var out: [String: Db3Drift] = [:]
        for documentId in documents {
            if let drift = of(sync[documentId], live: live(documentId)) { out[documentId] = drift }
        }
        return out
    }

    /// Judge a read's db3s against `maxDrift`, in `order`: the first that is
    /// synced and has not heard the server's position, or is past a bound,
    /// refuses the read `DB3_DRIFT_EXCEEDED`. A db3 that lives only on this
    /// device passes.
    static func judge(
        _ maxDrift: Db3MaxDrift?, order: [String], sync: [String: RecordLogDocumentSync], drift: [String: Db3Drift],
        now: Date = Date()
    ) throws {
        guard let maxDrift else { return }
        for documentId in order {
            if sync[documentId]?.localOnly == true { continue }
            let own = drift[documentId]
            if let own,
               maxDrift.entries.map({ own.entriesBehind <= $0 }) ?? true,
               maxDrift.age.map({ now.timeIntervalSince(own.asOf) <= $0 }) ?? true {
                continue
            }
            throw refusal(documentId, own, maxDrift, now: now)
        }
    }

    /// The `DB3_DRIFT_EXCEEDED` refusal of `db3Id`, its drift (`nil`: no head heard) and the bound.
    static func refusal(_ db3Id: String, _ drift: Db3Drift?, _ maxDrift: Db3MaxDrift, now: Date = Date()) -> JsBaoError {
        let bound = RecordLogJSON.text(json(maxDrift))
        let message: String
        if let drift {
            let ago = Int(max(0, now.timeIntervalSince(drift.asOf)) * 1000)
            message = "The db3 '\(db3Id)' is \(drift.entriesBehind) entries behind the server as of "
                + "\(ISO8601DateFormatter().string(from: drift.asOf)) (\(ago) ms ago), past maxDrift \(bound). "
                + "Subscribe to it and await ready() to catch it up, or widen maxDrift."
        } else {
            message = "The db3 '\(db3Id)' has not heard the server's position on this device, so how far behind its copy "
                + "is is unknown, and maxDrift \(bound) refuses it. Subscribe to it and await ready() before reading it "
                + "with maxDrift, or read without it."
        }
        return JsBaoError(
            code: .db3DriftExceeded, message: message,
            details: ["db3Id": .string(db3Id), "drift": drift.map(json) ?? .null, "maxDrift": json(maxDrift)]
        )
    }

    /// A drift as the JS client's `details.drift` carries it: `asOf` in epoch ms.
    static func json(_ drift: Db3Drift) -> JSONValue {
        .object([
            "entriesBehind": .number(Double(drift.entriesBehind)),
            "asOf": .number((drift.asOf.timeIntervalSince1970 * 1000).rounded()),
            "live": .bool(drift.live),
            "pendingWrites": .number(Double(drift.pendingWrites)),
        ])
    }

    /// A bound as the JS client's `details.maxDrift` carries it: `ageMs` in milliseconds.
    static func json(_ maxDrift: Db3MaxDrift) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if let entries = maxDrift.entries { object["entries"] = .number(Double(entries)) }
        if let age = maxDrift.age { object["ageMs"] = .number(age * 1000) }
        return .object(object)
    }
}
