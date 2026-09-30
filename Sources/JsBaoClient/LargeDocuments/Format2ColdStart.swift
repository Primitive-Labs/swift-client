import Foundation

/// Opening a large document with nothing local to start from (#3436,
/// behavior 25).
///
/// A port of `packages/js-bao/src/models/format2ColdStart.ts`'s planner. A
/// fresh client is not "behind": it holds no overlay, so there is nothing to
/// catch up from. Under epochs that is not enough — the epoch it would adopt
/// holds only the changes since the last rotation, and everything older lives
/// in the server's `records` table and in the base snapshot — so a client that
/// just joined would show an almost-empty document and, because a create is
/// decided against the merged view, would `_replace` records that still exist.
///
/// This module DECIDES; it does not run. Which of the plans this client can
/// honour is `Format2Coordinator`'s business and is deliberately narrow: `join`
/// and a cold client's `snapshot` whose base covers the room's epoch. Every
/// other plan stops the document, because running it needs the sealed chain,
/// which is #3437's.

/// One sealed epoch as `epoch.info` reports it.
public struct SealedEpochChainEntry: Sendable, Equatable {
    public let epoch: Int
    public let sealedAt: Int
    /// A bulk load re-founded the document here (#3435): no chain crosses this
    /// epoch, because the sum of the overlays on either side is not the
    /// document.
    public let baseDiscontinuity: Bool
    /// The signed path this client may read the archived overlay at, while the
    /// grant lives. `nil` once retention has taken it.
    public let downloadPath: String?

    public init(
        epoch: Int,
        sealedAt: Int = 0,
        baseDiscontinuity: Bool = false,
        downloadPath: String? = nil
    ) {
        self.epoch = epoch
        self.sealedAt = sealedAt
        self.baseDiscontinuity = baseDiscontinuity
        self.downloadPath = downloadPath
    }
}

/// The base snapshot a handshake offered, or a later `snapshot.ready`
/// announced.
///
/// Typed rather than the frame's own dictionary because it OUTLIVES the frame:
/// the next handshake reads it, a load in flight refreshes its grant from it,
/// and a `snapshot.ready` replaces it. State a frame handler keeps is state
/// something else has to agree with about its shape.
public struct SnapshotOffer: Sendable, Equatable {
    /// The epoch this base is a base FOR — the one a client that installs it
    /// ends up on.
    public let epoch: Int
    public let buildId: String?
    /// How many rows it carries, as the room reported them.
    public let rows: Int
    public let manifestVersion: Int?
    /// The origin-relative signed path the manifest is at and the chunks are
    /// under. Never logged.
    public let downloadPath: String?

    public init(
        epoch: Int,
        buildId: String? = nil,
        rows: Int = 0,
        manifestVersion: Int? = nil,
        downloadPath: String? = nil
    ) {
        self.epoch = epoch
        self.buildId = buildId
        self.rows = rows
        self.manifestVersion = manifestVersion
        self.downloadPath = downloadPath
    }
}

/// How a document with no local state should be opened.
public enum ColdStartPlan: Equatable, Sendable {
    /// The document already follows an epoch: the catch-up path owns it.
    case catchUp
    /// Nothing was ever archived — the current overlay IS the document.
    case join
    /// Materialize this snapshot, then apply the overlays sealed since.
    case snapshot(base: Int)
    /// No snapshot yet: the sealed chain from `base` is the document.
    case overlays(base: Int)
    /// A bulk load stands between every base on offer and the room (#3435).
    /// Not a refusal: the ingest's own base is being built, and the
    /// `snapshot.ready` that announces it is what this plan waits for.
    case awaitBase(discontinuities: [Int])
    /// Neither a base nor a complete chain is available.
    case unavailable(reason: String)

    /// The name the JS planner gives this plan, which is what a refusal's
    /// `details.plan` carries and what the parity suite compares.
    public var kind: String {
        switch self {
        case .catchUp: return "catch-up"
        case .join: return "join"
        case .snapshot: return "snapshot"
        case .overlays: return "overlays"
        case .awaitBase: return "await-base"
        case .unavailable: return "unavailable"
        }
    }
}

public enum Format2ColdStart {

    /// Decide how to open a document the client has no epoch mark for.
    ///
    /// A snapshot is preferred whenever the client can chain forward from it:
    /// one base plus the overlays after it, rather than replaying every epoch
    /// since the document was created — the cost this epic exists to remove.
    /// When the chain above the snapshot is broken but the whole chain from
    /// the first epoch is intact, that chain is used instead; it says the same
    /// thing, more expensively.
    public static func plan(
        held: Int,
        reported: Int,
        sealed: [SealedEpochChainEntry],
        snapshotEpoch: Int?
    ) -> ColdStartPlan {
        if held > 0 { return .catchUp }
        if reported <= 0 { return .join }

        let sealed = sealed.sorted { $0.epoch < $1.epoch }
        if sealed.isEmpty { return .join }

        if let base = snapshotEpoch, base > 0, base <= reported,
           chainIsWhole(sealed, from: base, to: reported) {
            return .snapshot(base: base)
        }

        if sealed[0].epoch == 1, chainIsWhole(sealed, from: 1, to: reported) {
            return .overlays(base: 1)
        }

        // Before refusing: is the only thing between what is on offer and the
        // room a bulk load (#3435)? While the ingest's own build registers the
        // handshake still offers the PRE-ingest base, and `chainIsWhole`
        // rightly refuses to cross the flagged epoch. But the chain UP TO it
        // is applicable, and the base that describes the far side is being
        // built right now. "Wait for it" is the honest answer; `unavailable`
        // stops the document, which is the opposite.
        let start = (snapshotEpoch.map { $0 > 0 ? $0 : 1 }) ?? 1
        let discontinuities = sealed
            .filter { $0.baseDiscontinuity && $0.epoch >= start && $0.epoch < reported }
            .map(\.epoch)
        if let first = discontinuities.first,
           chainIsWhole(sealed, from: start, to: first),
           isGranted(sealed, epoch: first) {
            return .awaitBase(discontinuities: discontinuities)
        }

        return .unavailable(reason: "no-base")
    }

    /// Whether every epoch in `[from, to)` is a readable link of the chain.
    private static func chainIsWhole(
        _ sealed: [SealedEpochChainEntry], from: Int, to: Int
    ) -> Bool {
        var byEpoch: [Int: SealedEpochChainEntry] = [:]
        for entry in sealed { byEpoch[entry.epoch] = entry }
        var epoch = from
        while epoch < to {
            guard let entry = byEpoch[epoch] else { return false }
            if entry.baseDiscontinuity { return false }
            if entry.downloadPath == nil { return false }
            epoch += 1
        }
        return true
    }

    /// Whether this epoch's own archive is one the client may still read.
    private static func isGranted(_ sealed: [SealedEpochChainEntry], epoch: Int) -> Bool {
        sealed.first { $0.epoch == epoch }?.downloadPath != nil
    }
}
