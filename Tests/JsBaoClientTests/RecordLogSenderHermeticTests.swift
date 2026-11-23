import XCTest
@testable import JsBaoClient

/// The record-log sender: tick batching, one `record.entries` frame in flight
/// and its wait, the frame target and entry cap, control frames in order,
/// withdrawal and the two resends. Driven by a clock this test advances by
/// hand; the frames are the JS wire's, and the scripts are the JS sender
/// tests' (`record-log-client-sender-4307`, `record-log-client-sender-4484`).
final class RecordLogSenderHermeticTests: XCTestCase {

    /// A clock that runs what is due when told to, each at its own time.
    final class ManualClock: RecordLogClock {
        private var now = 0
        private var next = 0
        private var scheduled: [(handle: Int, at: Int, work: () -> Void)] = []

        func schedule(afterMilliseconds milliseconds: Int, _ work: @escaping () -> Void) -> Int {
            next += 1
            scheduled.append((next, now + milliseconds, work))
            return next
        }

        func cancel(_ handle: Int) { scheduled.removeAll { $0.handle == handle } }

        var pending: Int { scheduled.count }

        func advance(_ milliseconds: Int) {
            let until = now + milliseconds
            while let due = scheduled.enumerated().filter({ $0.element.at <= until }).min(by: {
                ($0.element.at, $0.element.handle) < ($1.element.at, $1.element.handle)
            }) {
                scheduled.remove(at: due.offset)
                now = due.element.at
                due.element.work()
            }
            now = until
        }
    }

    /// The frame wait the sender runs with by default.
    private static let wait = 2_000

    private var clock = ManualClock()
    private var sent: [RecordLogUpFrame] = []
    private var online = true

    private func makeSender(frameTargetBytes: Int = 64 * 1024, batchMax: Int? = nil) -> RecordLogSender {
        clock = ManualClock()
        sent = []
        let send: (RecordLogUpFrame) -> Void = { [unowned self] in self.sent.append($0) }
        if let batchMax {
            return RecordLogSender(
                clock: clock, frameTargetBytes: frameTargetBytes, batchMax: batchMax,
                connected: { [unowned self] in self.online }, send: send
            )
        }
        return RecordLogSender(
            clock: clock, frameTargetBytes: frameTargetBytes, connected: { [unowned self] in self.online }, send: send
        )
    }

    private func entry(_ seq: Int, size: Int = 0) -> RecordLogWireEntry {
        var fields: [String: JSONValue] = ["title": .string("t\(seq)")]
        if size > 0 { fields["blob"] = .string(String(repeating: "x", count: size)) }
        return RecordLogWireEntry(seq: seq, e: 1, k: 0, m: RecordLogMutation(model: "Note", id: "n\(seq)", kind: .create, fields: fields))
    }

    private func voidEntry(_ seq: Int) -> RecordLogWireEntry {
        RecordLogWireEntry(seq: seq, e: 1, k: 0, isVoid: true)
    }

    private func seqs(_ frame: RecordLogUpFrame) -> [Int] {
        if case .entries(let entries) = frame { return entries.map(\.seq) }
        return []
    }

    /// Each frame sent: its numbers (a void one marked `v`), or a control frame's type.
    private var shapes: [String] {
        sent.map { frame in
            if case .entries(let entries) = frame {
                return entries.map { "\($0.seq)\($0.isVoid ? "v" : "")" }.joined(separator: ",")
            }
            return frame.json["type"]?.stringValue ?? "?"
        }
    }

    private func run(_ from: Int, _ to: Int) -> String { (from...to).map(String.init).joined(separator: ",") }

    // MARK: - Ticks, the frame target, control frames (#4307 behavior 9)

    func testEntriesEnqueuedWithinOneTickLeaveInOneFrame() {
        let sender = makeSender()
        for seq in 1...3 { sender.enqueue(entry(seq)) }
        sender.enqueue(entry(2))
        XCTAssertEqual(sent, [], "nothing leaves before the tick")
        XCTAssertEqual(clock.pending, 1, "one tick gathers them all")
        clock.advance(5)
        XCTAssertEqual(sent.map(seqs), [[1, 2, 3]], "one record.entries, an entry queued twice sent once")
        XCTAssertEqual(sent.first?.json["type"], "record.entries")
    }

    func testOneFrameIsInFlightUntilItsLastEntryIsAcknowledged() {
        let sender = makeSender()
        for seq in 1...8 { sender.enqueue(entry(seq)) }
        clock.advance(5)
        for seq in 9...12 { sender.enqueue(entry(seq)) }
        clock.advance(5)
        XCTAssertEqual(shapes, [run(1, 8)])
        XCTAssertEqual(sender.inFlightCount, 8)
        clock.advance(50)
        XCTAssertEqual(sent.count, 1)
        for seq in 1...7 { sender.acknowledged(seq) }
        clock.advance(5)
        XCTAssertEqual(sent.count, 1)
        sender.acknowledged(8)
        clock.advance(5)
        XCTAssertEqual(shapes, [run(1, 8), run(9, 12)])
    }

    func testABatchIsCutAtTheFrameTargetAndAtTheCapAndALargeEntryTravelsAlone() {
        let sender = makeSender(frameTargetBytes: 1000)
        sender.enqueue(entry(1, size: 300))
        sender.enqueue(entry(2, size: 300))
        sender.enqueue(entry(3, size: 300))
        sender.enqueue(entry(4, size: 3000))
        sender.enqueue(entry(5))
        for answered in [[], [1, 2], [3], [4]] {
            for seq in answered { sender.acknowledged(seq) }
            clock.advance(5)
        }
        XCTAssertEqual(sent.map(seqs), [[1, 2], [3], [4], [5]], "one frame at a time, each once the one before is acknowledged")

        let many = makeSender(batchMax: 200)
        for seq in 1...450 { many.enqueue(entry(seq)) }
        for answered in [0..<0, 1..<201, 201..<401] {
            for seq in answered { many.acknowledged(seq) }
            clock.advance(5)
        }
        XCTAssertEqual(sent.map { seqs($0).count }, [200, 200, 50])
    }

    func testControlFramesKeepTheirPlaceAmongTheEntries() {
        let sender = makeSender()
        sender.enqueue(entry(1))
        sender.enqueueControl(.resume(nextSeq: 2, records: nil))
        sender.enqueue(entry(2))
        sender.enqueueControl(.declare(models: ["Note": .object([:])]))
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "record.resume"], "2 waits behind the frame in flight, the declaration with it")
        sender.acknowledged(1)
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "record.resume", "2", "record.declare"])
    }

    func testWithdrawReplacesAQueuedEntryWithItsVoidMarker() {
        let sender = makeSender()
        sender.enqueue(entry(1))
        sender.enqueue(entry(2))
        sender.withdraw(1, replacement: RecordLogWireEntry(seq: 1, e: 1, k: 0, isVoid: true))
        sender.withdraw(2)
        clock.advance(5)
        guard case .entries(let entries) = sent.first else { return XCTFail("\(sent)") }
        XCTAssertEqual(entries.map(\.seq), [1])
        XCTAssertEqual(entries.first?.isVoid, true)
        XCTAssertNil(entries.first?.m)
        XCTAssertEqual(entries.first?.json, ["seq": 1, "e": 1, "k": 0, "void": true])
    }

    func testResendFromAndRequeueInFlightPutEntriesBackAtTheHeadInSeqOrder() {
        let sender = makeSender()
        for seq in 1...3 { sender.enqueue(entry(seq)) }
        clock.advance(5)
        for seq in 4...5 { sender.enqueue(entry(seq)) }
        XCTAssertEqual(sent.map(seqs), [[1, 2, 3]])
        sender.acknowledged(1)
        sender.resendFrom(2, entries: [entry(3), entry(2)])
        clock.advance(5)
        XCTAssertEqual(sent.map(seqs).last, [2, 3, 4, 5], "the missing entries again, in seq order, ahead of what was queued")

        sender.requeueInFlight([entry(4), entry(3), entry(5)])
        XCTAssertEqual(sender.inFlightCount, 0)
        XCTAssertEqual(sender.framesInFlight, 0)
        clock.advance(5)
        XCTAssertEqual(sent.map(seqs).last, [3, 4, 5], "in flight entries back at the head; 2 is no longer unjudged and is dropped")
    }

    func testNothingLeavesWhileDisconnectedAndResetForgetsEverything() {
        let sender = makeSender()
        online = false
        sender.enqueue(entry(1))
        clock.advance(5)
        XCTAssertEqual(sent, [])
        online = true
        sender.kick()
        clock.advance(5)
        XCTAssertEqual(sent.map(seqs), [[1]])

        sender.enqueue(entry(2))
        sender.reset()
        XCTAssertEqual(sender.queued, 0)
        XCTAssertEqual(sender.inFlightCount, 0)
        XCTAssertEqual(sender.framesInFlight, 0)
        XCTAssertEqual(clock.pending, 0, "the tick and the frame wait are cancelled")
        clock.advance(5)
        XCTAssertEqual(sent.map(seqs), [[1]])
    }

    // MARK: - One frame in flight (#4484 behaviors 1–5, the JS scripts)

    func testByDefaultABurstLeaves64EntriesAFrameOneFramePerRoundTrip() {
        let sender = makeSender()
        for seq in 1...200 { sender.enqueue(entry(seq)) }
        clock.advance(5)
        XCTAssertEqual(shapes, [run(1, 64)])
        for (from, to) in [(1, 64), (65, 128), (129, 192)] {
            clock.advance(50)
            XCTAssertEqual(sender.framesInFlight, 1)
            for seq in from...to { sender.acknowledged(seq) }
            clock.advance(5)
        }
        XCTAssertEqual(shapes, [run(1, 64), run(65, 128), run(129, 192), run(193, 200)])
    }

    func testAtACapOf200FourHundredFiftyLeaveAs200Then200Then50() {
        let sender = makeSender(batchMax: 200)
        for seq in 1...450 { sender.enqueue(entry(seq)) }
        clock.advance(5)
        XCTAssertEqual(shapes, [run(1, 200)])
        XCTAssertEqual(sender.framesInFlight, 1)
        XCTAssertEqual(sender.inFlightCount, 200)
        for seq in 1..<200 {
            sender.acknowledged(seq)
            clock.advance(5)
        }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sender.framesInFlight, 1)
        sender.acknowledged(200)
        XCTAssertEqual(sender.framesInFlight, 0)
        XCTAssertEqual(sent.count, 1, "the next frame leaves at the next tick, not at once")
        clock.advance(5)
        XCTAssertEqual(shapes, [run(1, 200), run(201, 400)])
        for seq in 201...400 { sender.acknowledged(seq) }
        clock.advance(5)
        XCTAssertEqual(shapes, [run(1, 200), run(201, 400), run(401, 450)])
        XCTAssertEqual(sender.framesInFlight, 1)
    }

    func testABurstQueuedBehindAFrameLeavesAsOneFrameAtItsLastAnswer() {
        let sender = makeSender(batchMax: 200)
        for seq in 1...3 { sender.enqueue(entry(seq)) }
        clock.advance(5)
        XCTAssertEqual(shapes, ["1,2,3"])
        for seq in 4...200 {
            sender.enqueue(entry(seq))
            if seq % 50 == 0 { clock.advance(5) }
        }
        clock.advance(5)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sender.queued, 197)
        sender.acknowledged(1)
        sender.acknowledged(2)
        clock.advance(5)
        XCTAssertEqual(sent.count, 1)
        sender.acknowledged(3)
        clock.advance(5)
        XCTAssertEqual(shapes, ["1,2,3", run(4, 200)])
        XCTAssertEqual(sender.framesInFlight, 1)
    }

    func testAnEntryEnqueuedWhileTheFirstFrameIsOutRidesTheSecond() {
        let sender = makeSender()
        sender.enqueue(entry(1))
        clock.advance(5)
        sender.enqueue(entry(2))
        clock.advance(40)
        sender.enqueue(entry(3))
        clock.advance(40)
        XCTAssertEqual(shapes, ["1"])
        sender.acknowledged(1)
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "2,3"])
    }

    func testALoneEntryLeavesAtTheTickAlone() {
        let sender = makeSender()
        sender.enqueue(entry(1))
        clock.advance(4)
        XCTAssertEqual(sent, [])
        clock.advance(1)
        XCTAssertEqual(shapes, ["1"])
        XCTAssertEqual(sender.framesInFlight, 1)
    }

    func testAResumeAtTheHeadLeavesWhileAFrameIsOutAndOneBehindABlockedEntryWaitsWithIt() {
        let sender = makeSender()
        sender.enqueue(entry(1))
        clock.advance(5)
        sender.enqueueControl(.resume(nextSeq: 2, records: nil))
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "record.resume"])
        sender.enqueue(entry(2))
        sender.enqueueControl(.declare(models: [:]))
        sender.enqueue(entry(3))
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "record.resume"])
        sender.acknowledged(1)
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "record.resume", "2", "record.declare"])
        XCTAssertEqual(sender.framesInFlight, 1)
        sender.acknowledged(2)
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "record.resume", "2", "record.declare", "3"])
    }

    func testAnEntryAboveTheTargetIsTheOneFrameOutAndTheTargetHoldsOneFramePerRoundTrip() {
        let sender = makeSender(frameTargetBytes: 1000)
        sender.enqueue(entry(1, size: 5000))
        sender.enqueue(entry(2, size: 300))
        sender.enqueue(entry(3, size: 300))
        sender.enqueue(entry(4, size: 300))
        clock.advance(5)
        XCTAssertEqual(shapes, ["1"])
        sender.acknowledged(1)
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "2,3"])
        XCTAssertEqual(sender.framesInFlight, 1)
        sender.acknowledged(2)
        sender.acknowledged(3)
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "2,3", "4"])
    }

    func testARefusalsAcknowledgementIsTheEntrysAnswerAndANumberNotInFlightChangesNothing() {
        let sender = makeSender()
        sender.enqueue(entry(1))
        sender.enqueue(entry(2))
        clock.advance(5)
        sender.enqueue(entry(3))
        sender.enqueue(entry(4))
        clock.advance(5)
        sender.acknowledged(99)
        clock.advance(5)
        XCTAssertEqual(sender.framesInFlight, 1)
        XCTAssertEqual(sent.count, 1)
        // 1 is answered with its result; 2 is refused, and the queued 3 and 4 are withdrawn with it.
        sender.acknowledged(1)
        sender.withdraw(3, replacement: voidEntry(3))
        sender.withdraw(4)
        sender.acknowledged(2)
        XCTAssertEqual(sender.framesInFlight, 0)
        clock.advance(5)
        XCTAssertEqual(shapes, ["1,2", "3v"])
    }

    func testAFrameAnsweredOutOfOrderIsFreedOnlyByItsLastAnswer() {
        let sender = makeSender()
        for seq in 1...3 { sender.enqueue(entry(seq)) }
        clock.advance(5)
        sender.enqueue(entry(4))
        sender.acknowledged(3)
        sender.acknowledged(1)
        clock.advance(5)
        XCTAssertEqual(sent.count, 1)
        sender.acknowledged(2)
        clock.advance(5)
        XCTAssertEqual(shapes, ["1,2,3", "4"])
    }

    func testAFrameUnansweredForTheWaitStopsCountingAndAGapResendsItAheadOfWhatWasQueued() {
        let sender = makeSender()
        sender.enqueue(entry(1))
        clock.advance(5)
        sender.enqueue(entry(2))
        clock.advance(Self.wait - 1)
        XCTAssertEqual(shapes, ["1"])
        clock.advance(1)
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "2"])
        XCTAssertEqual(sender.framesInFlight, 1)
        XCTAssertEqual(sender.inFlightCount, 2)
        sender.enqueue(entry(3))
        // The room never saw 1: it answers the second frame with a gap from 1.
        sender.resendFrom(1, entries: [entry(1), entry(2)])
        XCTAssertEqual(sender.framesInFlight, 0)
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "2", "1,2,3"])
    }

    func testAnAnswerAfterTheWaitIsAcceptedAndNothingIsSentTwice() {
        let sender = makeSender()
        sender.enqueue(entry(1))
        clock.advance(5)
        sender.enqueue(entry(2))
        clock.advance(Self.wait + 5)
        XCTAssertEqual(shapes, ["1", "2"])
        sender.acknowledged(1)
        XCTAssertEqual(sender.inFlightCount, 1)
        XCTAssertEqual(sender.framesInFlight, 1)
        clock.advance(5)
        sender.enqueue(entry(2))
        clock.advance(5)
        XCTAssertEqual(sent.count, 2, "2 is still in flight: committed again, it is not queued twice")
        sender.acknowledged(2)
        XCTAssertEqual(sender.framesInFlight, 0)
        sender.enqueue(entry(3))
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "2", "3"])
    }

    func testTheWaitRunsForTheOldestFrameOnlyFromTheMomentItWasSent() {
        let sender = makeSender()
        sender.enqueue(entry(1))
        clock.advance(5)
        clock.advance(Self.wait - 100)
        sender.acknowledged(1)
        sender.enqueue(entry(2))
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "2"])
        sender.enqueue(entry(3))
        // Past where the first frame's wait would have ended, short of the second's.
        clock.advance(200)
        XCTAssertEqual(shapes, ["1", "2"])
        clock.advance(Self.wait)
        XCTAssertEqual(shapes, ["1", "2", "3"])
    }

    func testAFrameAnsweredBeforeTheWaitClearsItAndWithNothingQueuedTheNextEntryLeavesAtItsTick() {
        let answered = makeSender()
        answered.enqueue(entry(1))
        clock.advance(5)
        answered.acknowledged(1)
        clock.advance(Self.wait * 2)
        XCTAssertEqual(shapes, ["1"])
        XCTAssertEqual(answered.framesInFlight, 0)

        let idle = makeSender()
        idle.enqueue(entry(1))
        clock.advance(5 + Self.wait)
        XCTAssertEqual(idle.framesInFlight, 0)
        XCTAssertEqual(idle.inFlightCount, 1)
        XCTAssertEqual(sent.count, 1)
        idle.enqueue(entry(2))
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "2"])
    }

    func testAResendFromInsideTheFrameWaitsForTheRestOfItAndOneFromItsFirstNumberGoesAtOnce() {
        let partial = makeSender()
        for seq in 1...3 { partial.enqueue(entry(seq)) }
        clock.advance(5)
        partial.enqueue(entry(4))
        partial.resendFrom(2, entries: [entry(3), entry(2)])
        XCTAssertEqual(partial.framesInFlight, 1)
        clock.advance(5)
        XCTAssertEqual(sent.count, 1)
        partial.acknowledged(1)
        clock.advance(5)
        XCTAssertEqual(shapes, ["1,2,3", "2,3,4"])

        let whole = makeSender()
        for seq in 1...3 { whole.enqueue(entry(seq)) }
        clock.advance(5)
        whole.enqueue(entry(4))
        whole.resendFrom(1, entries: [entry(1), entry(2), entry(3)])
        XCTAssertEqual(whole.framesInFlight, 0)
        clock.advance(5)
        XCTAssertEqual(shapes, ["1,2,3", "1,2,3,4"])
    }

    func testAGapWhileFiveToEightIsOutAndThreeAndFourNeverArrivedResendsThreeToEightAsOneFrame() {
        let sender = makeSender()
        sender.enqueue(entry(3))
        sender.enqueue(entry(4))
        clock.advance(5)
        for seq in 5...8 { sender.enqueue(entry(seq)) }
        clock.advance(Self.wait + 5)
        XCTAssertEqual(shapes, ["3,4", "5,6,7,8"])
        sender.resendFrom(3, entries: (3...8).map { entry($0) })
        XCTAssertEqual(sender.framesInFlight, 0)
        clock.advance(5)
        XCTAssertEqual(shapes.last, run(3, 8))
    }

    func testRequeueInFlightForgetsTheFrameAndItsWait() {
        let sender = makeSender()
        for seq in 1...3 { sender.enqueue(entry(seq)) }
        clock.advance(5)
        sender.enqueue(entry(4))
        sender.requeueInFlight((1...4).map { entry($0) })
        XCTAssertEqual(sender.framesInFlight, 0)
        XCTAssertEqual(sender.inFlightCount, 0)
        clock.advance(5)
        XCTAssertEqual(shapes, ["1,2,3", "1,2,3,4"])
        sender.enqueue(entry(5))
        // Past where the forgotten frame's wait would have ended, short of the new frame's.
        clock.advance(Self.wait - 2)
        XCTAssertEqual(sent.count, 2)
        clock.advance(10)
        XCTAssertEqual(shapes.last, "5")
    }

    func testResetForgetsTheFrameAndItsWait() {
        let sender = makeSender()
        sender.enqueue(entry(1))
        clock.advance(5)
        sender.reset()
        XCTAssertEqual(sender.framesInFlight, 0)
        for seq in 1...3 { sender.enqueue(entry(seq)) }
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "1,2,3"])
        sender.enqueue(entry(4))
        clock.advance(Self.wait - 2)
        XCTAssertEqual(sent.count, 2)
    }

    func testWithdrawReplacesOrDropsAQueuedEntryAsBefore() {
        let sender = makeSender()
        sender.enqueue(entry(1))
        clock.advance(5)
        sender.enqueue(entry(2))
        sender.enqueue(entry(3))
        sender.withdraw(2, replacement: voidEntry(2))
        sender.withdraw(3)
        sender.withdraw(1)
        sender.acknowledged(1)
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "2v"])
    }

    func testKickWhileAFrameIsOutSendsNothingAndAfterItsAnswerTheNextTickSends() {
        let sender = makeSender()
        sender.enqueue(entry(1))
        clock.advance(5)
        sender.enqueue(entry(2))
        sender.kick()
        clock.advance(50)
        XCTAssertEqual(sent.count, 1)
        sender.acknowledged(1)
        sender.kick()
        clock.advance(5)
        XCTAssertEqual(shapes, ["1", "2"])
    }
}
