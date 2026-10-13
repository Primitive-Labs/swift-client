import XCTest
@testable import JsBaoClient

/// The record-log sender: tick batching, the send window, the frame target,
/// control frames in order, withdrawal and the two resends. Driven by a clock
/// this test advances by hand; the frames are the JS wire's.
final class RecordLogSenderHermeticTests: XCTestCase {

    /// A clock that runs what is due when told to.
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
            now += milliseconds
            while let due = scheduled.enumerated().filter({ $0.element.at <= now }).min(by: { $0.element.at < $1.element.at }) {
                scheduled.remove(at: due.offset)
                due.element.work()
            }
        }
    }

    private var clock = ManualClock()
    private var sent: [RecordLogUpFrame] = []
    private var online = true

    private func makeSender(window: Int = 8, frameTargetBytes: Int = 64 * 1024, batchMax: Int = 200) -> RecordLogSender {
        clock = ManualClock()
        sent = []
        return RecordLogSender(
            clock: clock, window: window, frameTargetBytes: frameTargetBytes, batchMax: batchMax,
            connected: { [unowned self] in self.online }, send: { [unowned self] in self.sent.append($0) }
        )
    }

    private func entry(_ seq: Int, size: Int = 0) -> RecordLogWireEntry {
        var fields: [String: JSONValue] = ["title": .string("t\(seq)")]
        if size > 0 { fields["blob"] = .string(String(repeating: "x", count: size)) }
        return RecordLogWireEntry(seq: seq, e: 1, k: 0, m: RecordLogMutation(model: "Note", id: "n\(seq)", kind: .create, fields: fields))
    }

    private func seqs(_ frame: RecordLogUpFrame) -> [Int] {
        if case .entries(let entries) = frame { return entries.map(\.seq) }
        return []
    }

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

    func testAtMostTheWindowIsInFlightUntilAcknowledged() {
        let sender = makeSender(window: 2)
        for seq in 1...5 { sender.enqueue(entry(seq)) }
        clock.advance(5)
        XCTAssertEqual(sent.map(seqs), [[1, 2]])
        XCTAssertEqual(sender.inFlightCount, 2)
        XCTAssertEqual(sender.queued, 3)
        sender.acknowledged(1)
        clock.advance(5)
        XCTAssertEqual(sent.map(seqs), [[1, 2], [3]])
        sender.acknowledged(2)
        sender.acknowledged(3)
        clock.advance(5)
        XCTAssertEqual(sent.map(seqs), [[1, 2], [3], [4, 5]])
    }

    func testABatchIsCutAtTheFrameTargetAndAtTwoHundredAndALargeEntryTravelsAlone() {
        let sender = makeSender(window: 1000, frameTargetBytes: 1000)
        sender.enqueue(entry(1, size: 300))
        sender.enqueue(entry(2, size: 300))
        sender.enqueue(entry(3, size: 300))
        sender.enqueue(entry(4, size: 3000))
        sender.enqueue(entry(5))
        clock.advance(5)
        XCTAssertEqual(sent.map(seqs), [[1, 2], [3], [4], [5]])

        let many = makeSender(window: 1000)
        for seq in 1...450 { many.enqueue(entry(seq)) }
        clock.advance(5)
        XCTAssertEqual(sent.map { seqs($0).count }, [200, 200, 50])
    }

    func testControlFramesKeepTheirPlaceAmongTheEntries() {
        let sender = makeSender()
        sender.enqueue(entry(1))
        sender.enqueueControl(.resume(nextSeq: 2, records: nil))
        sender.enqueue(entry(2))
        sender.enqueueControl(.declare(models: ["Note": .object([:])]))
        clock.advance(5)
        XCTAssertEqual(sent.map { $0.json["type"]?.stringValue ?? "" },
                       ["record.entries", "record.resume", "record.entries", "record.declare"])
        XCTAssertEqual(sent.map(seqs), [[1], [], [2], []])
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
        let sender = makeSender(window: 3)
        for seq in 1...5 { sender.enqueue(entry(seq)) }
        clock.advance(5)
        XCTAssertEqual(sent.map(seqs), [[1, 2, 3]])
        sender.acknowledged(1)
        sender.resendFrom(2, entries: [entry(3), entry(2)])
        clock.advance(5)
        XCTAssertEqual(sent.map(seqs).last, [2, 3, 4], "the missing entries again, in seq order, ahead of what was queued")

        sender.requeueInFlight([entry(4), entry(3)])
        XCTAssertEqual(sender.inFlightCount, 0)
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
        XCTAssertEqual(clock.pending, 0, "the tick is cancelled")
        clock.advance(5)
        XCTAssertEqual(sent.map(seqs), [[1]])
    }
}
