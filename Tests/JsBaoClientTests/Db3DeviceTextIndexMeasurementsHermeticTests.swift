import XCTest
@testable import JsBaoClient

/// #5223 behavior 24 (measurement) — what a device text index costs in the
/// Swift store, logged (it informs, never gates), as js-bao's
/// `db3-device-text-index-measurements-5222.test.ts` logs it for JS: a
/// 100,000-row bulk load with and without a text index, the index built after
/// the load instead; a `$search` for the top 20 at 100,000 rows for a word
/// and for a three-word phrase; and a one-row local commit before and after a
/// text index and a member table on its model. Each figure is the median of
/// its samples, printed as one `[5223 measurement]` line; the asserts only
/// check the figures were taken over answering queries. #5309 adds a one-row
/// local patch and delete with a text index, the writes whose trigger
/// bodies it changes, as `[5309 measurement]` lines.
final class Db3DeviceTextIndexMeasurementsHermeticTests: XCTestCase {

    private static let words = [
        "apple", "pear", "plum", "river", "stone", "light", "night", "green", "blue", "garden", "report", "quarter", "review",
        "meeting", "budget", "travel", "summer", "winter", "market", "signal",
    ]
    private static let text = RecordLogIndexEntry(
        name: "idx_text_note", model: "Note", fields: ["title", "body"], unique: false, kind: .text, on: .device
    )
    private static let tags = RecordLogIndexEntry(name: "idx_members_note_tags", model: "Note", fields: ["tags"], unique: false, members: true)

    private var worlds: [Db3DeviceIndexWorld] = []

    override func tearDown() {
        for world in worlds { world.remove() }
        worlds = []
        super.tearDown()
    }

    private func world(_ label: String) async throws -> Db3DeviceIndexWorld {
        let world = try await Db3DeviceIndexWorld.make("measure-\(label)")
        worlds.append(world)
        return world
    }

    private static func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }

    private static func log(_ name: String, _ value: Double, digits: Int = 0, issue: String = "5223") {
        let line = "[\(issue) measurement] \(name): \(String(format: "%.\(digits)f", value))\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func ms(_ since: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1_000_000
    }

    /// js-bao's measurement rows: three words of title, twelve of body, two tags.
    private static func rows(_ n: Int) -> [(id: String, title: String, body: String, tags: [String])] {
        var state: UInt32 = 5222
        func next() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state) / 4_294_967_296
        }
        func pick() -> String { words[Int(next() * Double(words.count))] }
        return (0..<n).map { i in
            let title = (0..<3).map { _ in pick() }.joined(separator: " ")
            let body = (0..<12).map { _ in pick() }.joined(separator: " ")
            return (String(format: "r%06d", i), title, body, [pick(), pick()])
        }
    }

    /// A synced store holding `n` rows from one bulk load, its text index registered first when `text`; and the load's time.
    private func loaded(_ n: Int, text: Bool) async throws -> (world: Db3DeviceIndexWorld, store: RecordLogStore, ms: Double) {
        let world = try await world(text ? "text" : "plain")
        let store = try world.store("db3-measure")
        let writer = world.writer("db3-measure")
        if text { try store.syncIndexes([Self.text]) }
        let attempt = try store.beginReceipt(writer: writer, kind: .load, id: "LMEASURE").attempt
        let all = Self.rows(n)
        let started = DispatchTime.now()
        for start in stride(from: 0, to: all.count, by: 10_000) {
            _ = try store.applyLoadChunk(writer: writer, sessionId: "LMEASURE", attempt: attempt, model: "Note", lines: all[start..<min(start + 10_000, all.count)].map {
                RecordLogLoadLine(id: $0.id, patch: ["title": .string($0.title), "body": .string($0.body), "tags": .array($0.tags.map { .string($0) })])
            })
        }
        _ = try store.completeLoad(writer: writer, sessionId: "LMEASURE", attempt: attempt, mode: .merge, models: ["Note"])
        return (world, store, Self.ms(started))
    }

    func testLogsA100000RowLoadWithAndWithoutATextIndexAndTheIndexBuiltAfterIt() async throws {
        let without = try await loaded(100_000, text: false)
        let withText = try await loaded(100_000, text: true)
        let built = DispatchTime.now()
        try without.store.syncIndexes([Self.text])
        let buildMs = Self.ms(built)
        Self.log("load 100,000 rows, no text index (ms)", without.ms)
        Self.log("load 100,000 rows, text index kept by triggers (ms)", withText.ms)
        Self.log("text index built over 100,000 loaded rows (ms)", buildMs)
        XCTAssertEqual(try withText.store.countView("Note", ["$search": "apple"]), try without.store.countView("Note", ["$search": "apple"]))
        XCTAssertGreaterThan(try withText.store.countView("Note", ["$search": "apple"]), 0)
    }

    func testLogsASearchForTheTop20At100000Rows() async throws {
        let (_, store, _) = try await loaded(100_000, text: true)
        var common: [Double] = []
        var phrase: [Double] = []
        for i in 0..<25 {
            var started = DispatchTime.now()
            let word = Self.words[i % Self.words.count]
            XCTAssertEqual(try store.queryView("Note", ["$search": .string(word)], options: QueryOptions(limit: 20)).data.count, 20)
            common.append(Self.ms(started))
            started = DispatchTime.now()
            let three = (0..<3).map { Self.words[(i + $0) % Self.words.count] }.joined(separator: " ")
            _ = try store.queryView("Note", ["$search": .string("\"\(three)\"")], options: QueryOptions(limit: 20))
            phrase.append(Self.ms(started))
        }
        Self.log("$search top 20 of 100,000, a word half the rows hold, swift-sqlite (ms)", Self.median(Array(common.dropFirst(5))), digits: 2)
        Self.log("$search top 20 of 100,000, a three-word phrase, swift-sqlite (ms)", Self.median(Array(phrase.dropFirst(5))), digits: 2)
    }

    func testLogsAOneRowLocalCommitBeforeAndAfterATextIndexAndAMemberTable() async throws {
        for indexed in [false, true] {
            let world = try await world(indexed ? "commit-indexed" : "commit-plain")
            let store = try world.store("db3-local", localOnly: true)
            if indexed { try store.syncIndexes([Self.text, Self.tags]) }
            var samples: [Double] = []
            for row in Self.rows(2_000) {
                let started = DispatchTime.now()
                _ = try store.commitEntries(writer: world.writer("db3-local"), writes: [RecordLogWrite(mutations: [RecordLogMutation(
                    model: "Note", id: row.id, kind: .create, fields: ["title": .string(row.title), "body": .string(row.body)],
                    stringSetDeltas: ["tags": Dictionary(row.tags.map { ($0, true) }, uniquingKeysWith: { a, _ in a })]
                )])])
                try store.flush()
                samples.append(Self.ms(started))
            }
            Self.log("one-row local commit, \(indexed ? "with" : "without") a text index and a member table (ms)",
                     Self.median(Array(samples.dropFirst(200))), digits: 3)
            XCTAssertEqual(try store.countView("Note", [:]), 2_000)
        }
    }

    func testLogsAOneRowLocalPatchAndDeleteWithATextIndex() async throws {
        let world = try await world("patch-delete")
        let store = try world.store("db3-local", localOnly: true)
        try store.syncIndexes([Self.text])
        let writer = world.writer("db3-local")
        let rows = Self.rows(2_000)
        for row in rows {
            _ = try store.commitEntries(writer: writer, writes: [RecordLogWrite(mutations: [RecordLogMutation(
                model: "Note", id: row.id, kind: .create, fields: ["title": .string(row.title), "body": .string(row.body)]
            )])])
        }
        try store.flush()
        func timed(_ mutation: (Int, (id: String, title: String, body: String, tags: [String])) -> RecordLogMutation) throws -> Double {
            var samples: [Double] = []
            for (i, row) in rows.enumerated() {
                let started = DispatchTime.now()
                _ = try store.commitEntries(writer: writer, writes: [RecordLogWrite(mutations: [mutation(i, row)])])
                try store.flush()
                samples.append(Self.ms(started))
            }
            return Self.median(Array(samples.dropFirst(200)))
        }
        let patch = try timed { i, row in
            RecordLogMutation(model: "Note", id: row.id, kind: .patch, fields: ["title": .string(rows[(i + 1) % rows.count].title)])
        }
        XCTAssertEqual(try store.countView("Note", [:]), 2_000)
        let delete = try timed { _, row in RecordLogMutation(model: "Note", id: row.id, kind: .delete) }
        Self.log("one-row local patch of title, with a text index (ms)", patch, digits: 3, issue: "5309")
        Self.log("one-row local delete, with a text index (ms)", delete, digits: 3, issue: "5309")
        XCTAssertEqual(try store.countView("Note", [:]), 0)
        XCTAssertEqual(try world.drift(), [])
    }
}
