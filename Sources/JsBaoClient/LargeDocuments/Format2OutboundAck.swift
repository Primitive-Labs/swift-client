import Foundation

/// The inclusive span of local sequences one outbound `update` frame carries.
public struct Format2SeqRange: Equatable, Sendable {
    public let from: Int
    public let to: Int

    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }
}

/// What each outbound frame of a large document may CLAIM (#3436, behavior 11).
///
/// A port of `src/client/internal/large-documents/outbound-ack.ts`, and the
/// rule it exists for is the server's: `AckTracker` treats a frame's
/// `[seqFrom, seq]` as coverage — every sequence in that span is taken to have
/// been committed by that frame — and answers the contiguous high-water mark,
/// which the client prunes `_pending_ops` against. So a frame that claims a
/// sequence whose CONTENT it does not carry gets that write acknowledged as
/// durable: the client drops the pending op, and if the frame that really
/// carried it never arrives, the write is gone with nothing left to resend it.
///
/// The claim therefore cannot be computed from the durable marks. "Everything
/// above the acked mark" is exactly the over-claim above whenever more than one
/// frame is in flight, or whenever a write commits while an earlier frame is
/// still on its way. It has to be recorded where the content is: the sequence
/// is noted when the Yjs update is ENQUEUED and claimed by the frame that
/// actually carries that update.
///
/// ## One mark per queued update, claimed by the batch
///
/// A flush does NOT always send everything queued: `mergeBudgetPrefix` merges
/// the longest prefix of the queue that fits one frame and leaves the rest for
/// the next pass. So "the highest sequence enqueued" is the wrong claim for the
/// same reason the durable mark is — two 60 KB writes queue as two updates, one
/// frame goes out, and a claim over both gets the SECOND write acknowledged
/// although its bytes are still sitting in the queue. The same hole opens for a
/// write enqueued between the batch being chosen and the frame being stamped.
///
/// So the ledger keeps one mark per queued update, in enqueue order, aligned
/// with the outbound queue itself — and a claim takes exactly as many marks as
/// the batch has updates, off the front. A mark of zero is an update that
/// carries no local sequence of its own; it holds the update's place in the
/// line so the alignment survives it.
///
/// Three marks per document, plus the durable acked mark in the record store:
///
/// - *queued*  — one per update not yet on the wire, in order;
/// - *covered* — the highest sequence a frame the socket accepted has claimed;
/// - *sent*    — the highest sequence stamped on an accepted frame.
public final class Format2OutboundAckLedger: @unchecked Sendable {

    /// What one frame claimed, and what has to go back if it never left.
    public struct Claim: Equatable, Sendable {
        /// The marks taken off the queue, in order — the frame's own updates.
        public let marks: [Int]
        /// The span to stamp, or `nil` when none of those updates carried a
        /// local sequence.
        public let range: Format2SeqRange?

        public init(marks: [Int], range: Format2SeqRange?) {
            self.marks = marks
            self.range = range
        }
    }

    private let lock = NSLock()
    private var queued: [String: [Int]] = [:]
    private var covered: [String: Int] = [:]
    private var sent: [String: Int] = [:]
    private var withheld: [String: Int] = [:]

    public init() {}

    // MARK: - Withholding what a judgement is owed on (#3437, behavior 27)

    /// Hold every sequence at or below `seq` back from every claim.
    ///
    /// Set before the fresh overlay of a DEFERRED carry is installed. Those
    /// sequences' content is on the sealed overlay this client is leaving and
    /// on no frame it has sent, so a claim covering them would get them
    /// acknowledged and pruned from `_pending_ops` unsent — the writes gone
    /// with nothing left to resend them.
    ///
    /// It applies to the ordinary claim AND to the whole-state claim, because
    /// Swift's whole-state span reads the DURABLE acked mark: the two are
    /// different numbers exactly when a deferral is outstanding. The JS client
    /// withholds only for a flagged seal because its claims come from an
    /// in-session ledger of what it has actually transmitted; Swift's
    /// mechanism differs, so the withhold has to cover every deferral
    /// (finding 3437-SO-02).
    ///
    /// The ceiling only ever RISES: a second deferral arriving before the first
    /// is judged must not lower the floor under sequences already held back.
    public func withhold(_ documentId: String, upTo seq: Int) {
        guard seq > 0 else { return }
        lock.withLock {
            withheld[documentId] = max(withheld[documentId] ?? 0, seq)
        }
    }

    /// The survivors have been stated and the dropped sequences forgotten: the
    /// ordinary floor applies again.
    public func releaseWithheld(_ documentId: String) {
        lock.withLock { _ = withheld.removeValue(forKey: documentId) }
    }

    /// The highest sequence currently held back. Zero when none is.
    public func withheldCeiling(_ documentId: String) -> Int {
        lock.withLock { withheld[documentId] ?? 0 }
    }

    /// Note the sequence the update just enqueued for `documentId` covers.
    ///
    /// Called ONCE per enqueue, whatever the sequence — including `0`, for an
    /// update this client committed no local write for. The entry is the
    /// update's place in the queue, and a claim counts places.
    public func note(_ documentId: String, seq: Int) {
        lock.withLock {
            // The first note that carries a sequence fixes this session's
            // floor. Sequences below it belong to ops this session did not
            // write — their content is in no frame it sends, so claiming them
            // would report a write as durable that the server may never have
            // received. (Adopting a previous instance's pending ops is #3437's.)
            if covered[documentId] == nil, seq > 0 { covered[documentId] = seq - 1 }
            queued[documentId, default: []].append(max(0, seq))
        }
    }

    /// Claim the span for the frame now being built, which carries the first
    /// `count` queued updates.
    ///
    /// Returns `nil` only when nothing is queued at all. A claim whose updates
    /// carried no local sequence has a `nil` range and still has to be settled,
    /// so a failed send puts its places back in the line.
    public func take(_ documentId: String, covering count: Int) -> Claim? {
        lock.withLock {
            guard count > 0, var marks = queued[documentId], !marks.isEmpty else {
                return nil
            }
            let taken = Array(marks.prefix(count))
            marks.removeFirst(taken.count)
            if marks.isEmpty {
                queued.removeValue(forKey: documentId)
            } else {
                queued[documentId] = marks
            }
            guard let to = taken.max(), to > 0 else {
                return Claim(marks: taken, range: nil)
            }
            let ceiling = withheld[documentId] ?? 0
            // A frame whose every sequence is owed a judgement claims NOTHING,
            // and still takes its places: the queue this ledger counts is the
            // outbound queue, and the two have to stay in step.
            guard to > ceiling else { return Claim(marks: taken, range: nil) }
            let from = max(min((covered[documentId] ?? to - 1) + 1, to), ceiling + 1)
            return Claim(marks: taken, range: Format2SeqRange(from: from, to: to))
        }
    }

    /// Claim EVERYTHING this client owes, for a frame carrying the overlay's
    /// WHOLE state (#3436, finding 3436-B01).
    ///
    /// A whole-state update is self-contained: every local write this client
    /// has committed is in it, whether or not a delta frame for it ever
    /// reached the room.
    ///
    /// So its span is everything the SERVER has not acknowledged — `from` is
    /// the durable acked mark plus one — and NOT the local floor an ordinary
    /// claim starts at. The two are different numbers exactly when this frame
    /// matters: the deltas that were refused have all been claimed, so the
    /// local floor sits at the top while the server's mark is stuck below the
    /// first one it could not integrate. A claim from the local floor would
    /// name a span with a hole under it and the server's contiguous mark would
    /// never move (measured live: a burst of eight writes stuck at four).
    ///
    /// It takes NO places. The queue this ledger counts is the outbound update
    /// queue, and this frame is not built from it — those updates are still
    /// there and will still be sent; draining their places would leave the two
    /// out of step and the frame that really carries them would go out
    /// unstamped.
    public func wholeState(_ documentId: String, from: Int, upTo highest: Int) -> Claim {
        guard highest > 0, highest >= from else { return Claim(marks: [], range: nil) }
        // Except what a judgement is owed on (behavior 27). Those writes are
        // NOT in this frame: a deferred carry installs the fresh overlay
        // without them, precisely so recency can have its say first.
        let floor = max(1, max(from, withheldCeiling(documentId) + 1))
        guard highest >= floor else { return Claim(marks: [], range: nil) }
        return Claim(marks: [], range: Format2SeqRange(from: floor, to: highest))
    }

    /// The socket accepted the frame that made `claim`.
    public func markSent(_ documentId: String, claim: Claim?) {
        guard let range = claim?.range, range.to > 0 else { return }
        lock.withLock {
            covered[documentId] = max(covered[documentId] ?? 0, range.to)
            sent[documentId] = max(sent[documentId] ?? 0, range.to)
        }
    }

    /// The send failed: the batch stays queued, so its places go back at the
    /// FRONT of the line, in the order they were taken.
    ///
    /// `covered` was not advanced (the frame never went out), so the next claim
    /// starts from the same place.
    public func restore(_ documentId: String, claim: Claim?) {
        guard let claim, !claim.marks.isEmpty else { return }
        lock.withLock {
            queued[documentId] = claim.marks + (queued[documentId] ?? [])
        }
    }

    /// The highest sequence waiting to be claimed. Zero when nothing is.
    public func queuedSeq(_ documentId: String) -> Int {
        lock.withLock { queued[documentId]?.max() ?? 0 }
    }

    /// How many updates are waiting to be claimed.
    public func queuedCount(_ documentId: String) -> Int {
        lock.withLock { queued[documentId]?.count ?? 0 }
    }

    /// The highest sequence a frame the socket accepted has carried.
    public func sentSeq(_ documentId: String) -> Int {
        lock.withLock { sent[documentId] ?? 0 }
    }

    /// The outbound queue was discarded without being sent — drop its places
    /// so the ledger stays aligned with it.
    ///
    /// The withhold ceiling SURVIVES this: a move discards the frames queued
    /// against the overlay it is leaving, and the judgement those sequences are
    /// owed is exactly as outstanding afterwards as it was before.
    public func forgetQueued(_ documentId: String) {
        lock.withLock { _ = queued.removeValue(forKey: documentId) }
    }

    /// Drop a closed document's marks.
    public func forget(_ documentId: String) {
        lock.withLock {
            queued.removeValue(forKey: documentId)
            covered.removeValue(forKey: documentId)
            sent.removeValue(forKey: documentId)
            withheld.removeValue(forKey: documentId)
        }
    }
}
