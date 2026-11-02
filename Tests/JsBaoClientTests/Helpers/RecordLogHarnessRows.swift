import Foundation
@testable import JsBaoClient

/// The db3 storage harness's rows (`tests/perf/db3-storage/README.md`), as
/// the db3 lab's import converts IMDb's `title.basics`: numbers as numbers,
/// absent values left out, `genres` a string set. The Swift twin of
/// `tests/helpers/db3-storage-rows.ts`: the IMDb TSV when one is present
/// (README step 1, or `DB3_STORAGE_TSV`); otherwise 100,000 deterministic
/// synthetic rows of the same shape, whose titles are shorter than IMDb's,
/// so their sizes are a diagnostic and never the project's size criterion.
enum RecordLogHarnessRows {
    enum Source: String {
        case imdb
        case synthetic
    }

    /// Where README step 1 puts the TSV.
    static let tsvPath: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tests/perf/db3-storage/data/title.basics.tsv").path

    /// The TSV a run reads: `DB3_STORAGE_TSV`, else README step 1's file, when it exists.
    static var tsv: String? {
        let path = ProcessInfo.processInfo.environment["DB3_STORAGE_TSV"] ?? tsvPath
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// `count` IMDb rows from `path` as `[id, patch]`, in id order; fewer when the file is shorter.
    static func imdb(_ path: String, count: Int = 100_000) throws -> [(id: String, patch: [String: JSONValue])] {
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true)
        guard let header = lines.first?.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) else { return [] }
        var rows: [(id: String, patch: [String: JSONValue])] = []
        for line in lines.dropFirst().prefix(count) {
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            var value: [String: String] = [:]
            for (index, name) in header.enumerated() where index < cells.count { value[name] = cells[index] }
            var patch: [String: JSONValue] = [
                "titleType": .string(value["titleType"] ?? ""), "primaryTitle": .string(value["primaryTitle"] ?? ""),
                "originalTitle": .string(value["originalTitle"] ?? ""),
            ]
            for field in ["isAdult", "startYear", "endYear", "runtimeMinutes"] where value[field] != "\\N" {
                patch[field] = Double(value[field] ?? "").map(JSONValue.number) ?? .null
            }
            if let genres = value["genres"], genres != "\\N" {
                patch["genres"] = .array(genres.split(separator: ",", omittingEmptySubsequences: false).map { .string(String($0)) })
            }
            rows.append((value["tconst"] ?? "", patch))
        }
        return rows.sorted { Array($0.id.utf8).lexicographicallyPrecedes(Array($1.id.utf8)) }
    }

    private static let genres = [
        "Action", "Adult", "Adventure", "Animation", "Biography", "Comedy", "Crime", "Documentary", "Drama", "Family",
        "Fantasy", "Film-Noir", "Game-Show", "History", "Horror", "Music", "Musical", "Mystery", "News", "Reality-TV",
        "Romance", "Sci-Fi", "Short", "Sport", "Talk-Show", "Thriller", "War", "Western",
    ]
    private static let types = ["short", "movie", "tvSeries", "tvEpisode", "video", "tvMovie"]
    private static let words = ["the", "love", "night", "city", "blue", "story", "of", "man", "river", "song", "last", "house"]

    /// `count` synthetic rows, the TS generator's draw for draw (seed 5133).
    static func synthetic(count: Int = 100_000) -> [(id: String, patch: [String: JSONValue])] {
        var state: UInt32 = 5133
        func next() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state) / 4_294_967_296
        }
        func pick(_ list: [String]) -> String { list[Int(next() * Double(list.count))] }
        return (0..<count).map { i in
            let length = 1 + Int(next() * 4)
            let title = (0..<length).map { _ in pick(words) }.joined(separator: " ")
            var patch: [String: JSONValue] = ["titleType": .string(pick(types))]
            patch["primaryTitle"] = .string(title)
            patch["originalTitle"] = .string(title)
            patch["isAdult"] = .number(next() < 0.02 ? 1 : 0)
            if next() < 0.9 { patch["startYear"] = .number(Double(1890 + Int(next() * 135))) }
            if next() < 0.1 { patch["endYear"] = .number(Double(1900 + Int(next() * 125))) }
            if next() < 0.6 { patch["runtimeMinutes"] = .number(Double(1 + Int(next() * 180))) }
            var members: [String] = []
            var k = Int(next() * 4)
            while k > 0 {
                let genre = pick(genres)
                if !members.contains(genre) { members.append(genre) }
                k -= 1
            }
            patch["genres"] = .array(members.map(JSONValue.string))
            let digits = String(i + 1)
            return ("tt" + String(repeating: "0", count: max(0, 7 - digits.count)) + digits, patch)
        }
    }
}
