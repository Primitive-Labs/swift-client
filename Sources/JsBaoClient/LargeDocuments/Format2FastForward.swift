import Foundation

/// Catching a client up on the sealed overlays it missed (#3437, behavior 14).
///
/// A port of `packages/js-bao/src/models/format2FastForward.ts`.
///
/// A client that was away while the room rotated is behind by whole epochs: its
/// merged view is missing every write since it left, and its own overlay
/// belongs to an epoch the room archived. It does NOT need the document back,
/// though. The sealed overlays between the epoch it holds and the one the room
/// is on are exactly the changes it missed, so applying them in order — each a
/// bounded, rotation-sized artifact — converges its merged view on the server's
/// `records` table without a base ever crossing the wire.
///
/// Two halves, deliberately separate:
///
/// - ``Format2FastForward/plan(current:target:sealed:)`` decides whether the
///   chain can be TRUSTED, from the handshake alone and before anything is
///   downloaded. A gap or a pruned archive means the sum of the overlays is not
///   the document, and the honest answer is to reload from a snapshot rather
///   than converge on a state that never existed.
/// - ``Format2FastForward/apply(_:fetch:fold:onApplied:)`` runs the plan. It
///   knows nothing about record stores or sockets: the caller fetches an
///   archive and folds a decoded overlay, which is what makes the ORDERING
///   testable without either.
///
/// The epoch mark is the caller's to move, and only after the whole chain has
/// landed: applying an overlay is idempotent at the record level, so a chain
/// that fails halfway is simply run again.
public enum Format2FastForward {

    /// Decide how a client on `current` reaches `target`.
    ///
    /// The chain runs from the epoch the client HOLDS, not the one after it:
    /// writes landed in that epoch after this client went away, and its archive
    /// is the only place they exist now. The target epoch itself is open — the
    /// client reaches that one by syncing, as it always did.
    public static func plan(
        current: Int,
        target: Int,
        sealed: [SealedEpochChainEntry]
    ) -> FastForwardPlan {
        guard target > 0 else { return .none(reason: .current) }
        // A document that never followed an epoch holds no overlay to be behind
        // with: it joins the epoch it is told about.
        guard current > 0 else { return .none(reason: .adopt) }
        guard target > current else { return .none(reason: .current) }

        var byEpoch: [Int: SealedEpochChainEntry] = [:]
        for entry in sealed { byEpoch[entry.epoch] = entry }

        // Every bulk-load discontinuity the chain crosses, as the handshake
        // named them (#3435). Collected from the whole range rather than found
        // by walking, because a hole PAST the first one says nothing: the base
        // the client is about to converge on covers everything after it.
        let discontinuities = sealed
            .filter { $0.baseDiscontinuity && $0.epoch >= current && $0.epoch < target }
            .map(\.epoch)
            .sorted()

        // The chain the client can still apply: to `target` ordinarily, and
        // only to the first flagged epoch when there is one, because past that
        // the document is the ingest's staged tables rather than these overlays
        // applied.
        let last = discontinuities.first ?? (target - 1)
        var steps: [FastForwardStep] = []
        var epoch = current
        while epoch <= last {
            guard let entry = byEpoch[epoch] else {
                return .reload(reason: .gap, epoch: epoch)
            }
            guard let path = entry.downloadPath, !path.isEmpty else {
                return .reload(reason: .unavailable, epoch: epoch)
            }
            steps.append(FastForwardStep(epoch: epoch, downloadPath: path))
            epoch += 1
        }

        if !discontinuities.isEmpty {
            return .converge(
                from: current, discontinuities: discontinuities, steps: steps
            )
        }
        return .apply(from: current, to: target, steps: steps)
    }

    /// Apply a verified chain, oldest epoch first, and report what landed.
    ///
    /// Strictly sequential: overlays are state deltas over one another, so
    /// applying a later one before an earlier one would let a stale value win.
    /// A failure propagates with the epochs before it already folded —
    /// harmless, because the caller has not moved the epoch mark and
    /// re-applying is idempotent.
    ///
    /// - Parameters:
    ///   - fetch: read one sealed epoch's archived overlay.
    ///   - fold: fold one decoded overlay into the merged view.
    ///   - onApplied: called after each epoch lands, with its place in the
    ///     chain. NOT optional, so a caller can record what landed with a
    ///     captured `inout` — which is how a retry knows to start at the epoch
    ///     that failed rather than at the beginning.
    /// - Throws: ``Format2FastForwardChainError`` naming the epoch that stopped
    ///   the chain — which is what the caller reports and what a retry starts
    ///   from, so it travels WITH the failure rather than being reconstructed.
    public static func apply(
        _ plan: FastForwardPlan,
        fetch: (FastForwardStep) throws -> Data,
        fold: (OverlayDocument, Int) throws -> Void,
        onApplied: (Int, Int, Int) -> Void = { _, _, _ in }
    ) throws {
        let steps = plan.steps
        for (index, step) in steps.enumerated() {
            do {
                let bytes = try fetch(step)
                let overlay = OverlayDocument()
                try overlay.applyUpdate([UInt8](bytes))
                try fold(overlay, step.epoch)
            } catch {
                throw Format2FastForwardChainError(epoch: step.epoch, underlying: error)
            }
            onApplied(step.epoch, index + 1, steps.count)
        }
    }
}

/// One archive to apply: the epoch, and the signed path its overlay is at.
public struct FastForwardStep: Equatable, Sendable {
    public let epoch: Int
    /// The origin-relative signed path the chain entry offered. Never logged.
    public let downloadPath: String

    public init(epoch: Int, downloadPath: String) {
        self.epoch = epoch
        self.downloadPath = downloadPath
    }
}

/// How a client behind the room reaches it.
public enum FastForwardPlan: Equatable, Sendable {

    /// Why there is nothing to catch up.
    public enum NoneReason: String, Equatable, Sendable {
        /// The marks already agree, or the target is not an epoch.
        case current
        /// This client follows no epoch at all: it ADOPTS the one it is told
        /// about rather than catching up to it.
        case adopt
    }

    /// Why a chain cannot be trusted.
    public enum Refusal: String, Equatable, Sendable {
        /// The chain skips an epoch: the client cannot know what happened in it.
        case gap
        /// The archive is gone — retention pruned it once a snapshot covered it.
        case unavailable
    }

    case none(reason: NoneReason)
    case apply(from: Int, to: Int, steps: [FastForwardStep])
    /// The chain crosses a bulk-load discontinuity (#3435).
    ///
    /// `steps` runs to the FIRST flagged epoch inclusive, which is the part of
    /// the chain that is still applicable: that epoch was sealed and archived
    /// through the ordinary path — a bulk-load swap calls the same `beginSeal` —
    /// and the writes made in it exist nowhere but its archive. What is unknown
    /// starts at E+1, where the ingest's staged tables took over, so the client
    /// needs a BASE past the highest discontinuity before it can move.
    case converge(from: Int, discontinuities: [Int], steps: [FastForwardStep])
    case reload(reason: Refusal, epoch: Int)

    /// The name the JS planner gives this plan, which is what the parity suite
    /// compares and what a log line carries.
    public var kind: String {
        switch self {
        case .none: return "none"
        case .apply: return "apply"
        case .converge: return "converge"
        case .reload: return "reload"
        }
    }

    /// The `reason` field of the plans that have one.
    public var reasonName: String? {
        switch self {
        case .none(let reason): return reason.rawValue
        case .reload(let reason, _): return reason.rawValue
        case .apply, .converge: return nil
        }
    }

    /// The archives to read, oldest first. Empty for a plan that runs nothing.
    public var steps: [FastForwardStep] {
        switch self {
        case .apply(_, _, let steps), .converge(_, _, let steps): return steps
        case .none, .reload: return []
        }
    }

    /// Every flagged epoch the chain crosses, ascending.
    public var discontinuities: [Int] {
        switch self {
        case .converge(_, let discontinuities, _): return discontinuities
        case .none, .apply, .reload: return []
        }
    }

    /// The epoch a refusal stopped at, or `nil` for a plan that did not refuse.
    public var refusedAt: Int? {
        switch self {
        case .reload(_, let epoch): return epoch
        case .none, .apply, .converge: return nil
        }
    }
}

/// A chain that could not be read, carrying the epoch that stopped it.
///
/// Which epoch it was is what the caller reports and what a retry starts from,
/// so it travels with the failure rather than being inferred afterwards — a
/// document that quietly stops syncing is the hardest kind of bug to diagnose.
public struct Format2FastForwardChainError: Error {
    public let epoch: Int
    public let underlying: Error

    public init(epoch: Int, underlying: Error) {
        self.epoch = epoch
        self.underlying = underlying
    }
}
