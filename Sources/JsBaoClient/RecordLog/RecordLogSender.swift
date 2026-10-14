import Foundation

/// The timer the sender gathers a tick with. A session supplies one that hops
/// back onto itself; a test supplies one it advances by hand.
protocol RecordLogClock: AnyObject {
    /// Run `work` after `milliseconds`; answers a handle for ``cancel(_:)``.
    func schedule(afterMilliseconds milliseconds: Int, _ work: @escaping () -> Void) -> Int
    /// Forget a scheduled `work`.
    func cancel(_ handle: Int)
}

/// A clock made of two closures, for an owner that schedules on itself.
final class RecordLogClosureClock: RecordLogClock {
    private let scheduleWork: (Int, @escaping () -> Void) -> Int
    private let cancelWork: (Int) -> Void

    init(schedule: @escaping (Int, @escaping () -> Void) -> Int, cancel: @escaping (Int) -> Void) {
        scheduleWork = schedule
        cancelWork = cancel
    }

    func schedule(afterMilliseconds milliseconds: Int, _ work: @escaping () -> Void) -> Int {
        scheduleWork(milliseconds, work)
    }

    func cancel(_ handle: Int) { cancelWork(handle) }
}

/// The upstream half of a format-3 document's connection: entries written
/// within one tick leave together, one `record.entries` frame is in flight
/// until the room has answered each of its entries, and what was written
/// meanwhile leaves as the next frame, cut at
/// ``RecordLogTransport/frameEntriesMax`` entries and the frame target. A
/// frame unanswered for ``RecordLogTransport/frameWaitMs`` stops holding the
/// next back. `record.resume` and `record.declare` frames keep their place
/// among the entries. A port of js-bao's `record-log-client/sender.ts`.
///
/// Not thread-safe: its owner (the document's session) calls it from one
/// isolation domain, and its clock runs `work` there.
final class RecordLogSender {
    private enum Queued {
        case entry(RecordLogWireEntry, bytes: Int)
        case control(RecordLogUpFrame)

        var entrySeq: Int? {
            if case .entry(let entry, _) = self { return entry.seq }
            return nil
        }
    }

    private var queue: [Queued] = []
    private var inFlight = Set<Int>()
    /// A frame sent and not yet answered in full: the numbers it still owes.
    private struct OwedFrame {
        let id: Int
        var owed: Set<Int>
    }

    /// The frames sent and not yet answered in full, oldest first.
    private var frames: [OwedFrame] = []
    private var framesSent = 0
    private var timer: Int?
    /// Runs out when the oldest frame has waited `frameWaitMs`.
    private var frameTimer: Int?
    private let tickMs: Int
    private let frameTargetBytes: Int
    private let batchMax: Int
    private let frameWaitMs: Int
    private let clock: RecordLogClock
    private let send: (RecordLogUpFrame) -> Void
    private let connected: () -> Bool

    init(
        clock: RecordLogClock,
        tickMs: Int = RecordLogTransport.tickMs,
        frameTargetBytes: Int = RecordLogTransport.frameTargetBytes,
        batchMax: Int = RecordLogTransport.frameEntriesMax,
        frameWaitMs: Int = RecordLogTransport.frameWaitMs,
        connected: @escaping () -> Bool,
        send: @escaping (RecordLogUpFrame) -> Void
    ) {
        self.clock = clock
        self.tickMs = tickMs
        self.frameTargetBytes = frameTargetBytes
        self.batchMax = batchMax
        self.frameWaitMs = frameWaitMs
        self.connected = connected
        self.send = send
    }

    /// Entries queued and not yet sent.
    var queued: Int { queue.filter { $0.entrySeq != nil }.count }

    /// Entries sent and not yet acknowledged.
    var inFlightCount: Int { inFlight.count }

    /// `record.entries` frames that hold the next back: sent, not answered in
    /// full, and within their wait.
    var framesInFlight: Int { frames.count }

    private func isQueued(_ seq: Int) -> Bool { queue.contains { $0.entrySeq == seq } }

    private static func queued(_ entry: RecordLogWireEntry) -> Queued {
        .entry(entry, bytes: recordLogJSONBytes(entry.json))
    }

    /// Queue an entry to send; one already queued or in flight is not queued twice.
    func enqueue(_ entry: RecordLogWireEntry) {
        guard !inFlight.contains(entry.seq), !isQueued(entry.seq) else { return }
        queue.append(Self.queued(entry))
        schedule()
    }

    /// An entry was withdrawn before the room judged it. Still queued, it is
    /// replaced by `replacement` (a void marker) or dropped; in flight, the
    /// room's answer to it is still owed and nothing changes.
    func withdraw(_ seq: Int, replacement: RecordLogWireEntry? = nil) {
        guard let at = queue.firstIndex(where: { $0.entrySeq == seq }) else { return }
        if let replacement {
            queue[at] = Self.queued(replacement)
        } else {
            queue.remove(at: at)
        }
    }

    /// The room is missing entries from `expected` on: every entry in flight
    /// from there is sent again, in `seq` order, ahead of what is queued. A
    /// frame no longer owes them; one that owed nothing else is done.
    func resendFrom(_ expected: Int, entries: [RecordLogWireEntry]) {
        inFlight = inFlight.filter { $0 < expected }
        forget { $0 >= expected }
        let again = entries
            .filter { $0.seq >= expected && !isQueued($0.seq) }
            .sorted { $0.seq < $1.seq }
            .map(Self.queued)
        queue.insert(contentsOf: again, at: 0)
        if !queue.isEmpty { schedule() }
    }

    /// The writer was opened again on the same connection: every entry in
    /// flight goes back to the head of the queue in `seq` order, in its form
    /// among `unjudged`; one no longer there is dropped. No frame is in
    /// flight any more.
    func requeueInFlight(_ unjudged: [RecordLogWireEntry]) {
        var bySeq: [Int: RecordLogWireEntry] = [:]
        for entry in unjudged { bySeq[entry.seq] = entry }
        var again: [Queued] = []
        for seq in inFlight.sorted() {
            guard let entry = bySeq[seq], !isQueued(seq) else { continue }
            again.append(Self.queued(entry))
        }
        inFlight = []
        clearFrames()
        queue.insert(contentsOf: again, at: 0)
        if !queue.isEmpty { schedule() }
    }

    /// Queue a `record.resume` or `record.declare` frame, after every entry queued before it.
    func enqueueControl(_ frame: RecordLogUpFrame) {
        queue.append(.control(frame))
        schedule()
    }

    /// The room has judged `seq` (a result, `void`, `duplicate` or a
    /// refusal): its frame no longer owes it, and a frame answered in full
    /// lets the next leave at the next tick.
    func acknowledged(_ seq: Int) {
        let answered = inFlight.remove(seq) != nil
        forget { $0 == seq }
        if answered, !queue.isEmpty { schedule() }
    }

    /// Forget everything queued and in flight: the connection that would carry it is gone.
    func reset() {
        queue = []
        inFlight = []
        clearFrames()
        if let timer { clock.cancel(timer) }
        timer = nil
    }

    /// The transport may have come back: send what waits, at the next tick.
    func kick() {
        if !queue.isEmpty { schedule() }
    }

    private func schedule() {
        guard timer == nil else { return }
        timer = clock.schedule(afterMilliseconds: tickMs) { [weak self] in
            guard let self else { return }
            self.timer = nil
            self.flush()
        }
    }

    /// The frames no longer owe the numbers `owed` picks; one that owes nothing is done.
    private func forget(_ owed: (Int) -> Bool) {
        let oldest = frames.first?.id
        for index in frames.indices { frames[index].owed = frames[index].owed.filter { !owed($0) } }
        frames.removeAll { $0.owed.isEmpty }
        if frames.first?.id != oldest {
            clearFrameTimer()
            armFrameTimer()
        }
    }

    private func clearFrames() {
        frames = []
        clearFrameTimer()
    }

    private func clearFrameTimer() {
        if let frameTimer { clock.cancel(frameTimer) }
        frameTimer = nil
    }

    /// Time the oldest frame. Unanswered at the end of its wait, it stops
    /// holding the next back; its numbers stay in flight, so a `record.gap`
    /// still sends them again and their answers are still taken.
    private func armFrameTimer() {
        guard frameTimer == nil, !frames.isEmpty else { return }
        frameTimer = clock.schedule(afterMilliseconds: frameWaitMs) { [weak self] in
            guard let self else { return }
            self.frameTimer = nil
            self.frames.removeFirst()
            self.armFrameTimer()
            if !self.queue.isEmpty { self.schedule() }
        }
    }

    /// Send what the frame in flight and the transport allow now.
    func flush() {
        guard connected() else { return }
        var batch: [RecordLogWireEntry] = []
        var bytes = 0
        func sendBatch() {
            guard !batch.isEmpty else { return }
            send(.entries(batch))
            framesSent += 1
            frames.append(OwedFrame(id: framesSent, owed: Set(batch.map(\.seq))))
            armFrameTimer()
            batch = []
            bytes = 0
        }
        while let head = queue.first {
            switch head {
            case .control(let frame):
                sendBatch()
                queue.removeFirst()
                send(frame)
            case .entry(let entry, let size):
                if batch.isEmpty, frames.count >= RecordLogTransport.framesInFlight { return }
                let fits = batch.count < batchMax && (batch.isEmpty || bytes + size <= frameTargetBytes)
                if !fits {
                    sendBatch()
                    continue
                }
                queue.removeFirst()
                batch.append(entry)
                bytes += size
                inFlight.insert(entry.seq)
                // An entry above the target travels alone.
                if size > frameTargetBytes { sendBatch() }
            }
        }
        sendBatch()
    }
}
