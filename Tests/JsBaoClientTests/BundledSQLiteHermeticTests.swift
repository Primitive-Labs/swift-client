import CoreData
import JsBaoSQLite
import XCTest
@testable import JsBaoClient

/// The Swift client runs on a SQLite of its own, pinned to the release
/// sqlite-wasm carries for the JS client (#4700, intent criterion 7 in part):
/// the store answers the same SQL on every OS it supports, and no database
/// file is opened by two SQLite libraries in one process.
final class BundledSQLiteHermeticTests: XCTestCase {

    /// The SQLite release js-bao's own sqlite-wasm build carries: the first
    /// line of `packages/js-bao/vendor/sqlite-wasm/VERSION`, `SQLite <release>`.
    private static func sqliteWasmRelease() throws -> String {
        let path = "packages/js-bao/vendor/sqlite-wasm/VERSION"
        let first = try ClientSourceText.repoFile(path).split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertTrue(first.hasPrefix("SQLite "), "\(path) starts with `SQLite <release>`, not \(first)")
        return String(first.dropFirst("SQLite ".count)).trimmingCharacters(in: .whitespaces)
    }

    /// The vec1 line of the same file, `vec1: <version>`, whole.
    private static func sqliteWasmVec1Line() throws -> String {
        let path = "packages/js-bao/vendor/sqlite-wasm/VERSION"
        let lines = try ClientSourceText.repoFile(path).split(separator: "\n").map(String.init)
        return try XCTUnwrap(lines.first { $0.hasPrefix("vec1: ") }, "\(path) names its vec1")
    }

    /// The vec1 version alone, `0.8` of `vec1: 0.8`.
    private static func sqliteWasmVec1() throws -> String {
        String(try sqliteWasmVec1Line().dropFirst("vec1: ".count)).trimmingCharacters(in: .whitespaces)
    }

    private func provider() async throws -> SQLiteStorageProvider {
        let provider = SQLiteStorageProvider(path: nil)
        try await provider.initialize(namespace: "bundled-sqlite-\(UUID().uuidString)")
        return provider
    }

    // MARK: - Behaviour 1: the store's SQLite is sqlite-wasm's release

    func testTheStoreAnswersTheSQLiteReleaseSqliteWasmCarries() async throws {
        let expected = try Self.sqliteWasmRelease()
        XCTAssertFalse(expected.isEmpty)
        let provider = try await provider()
        let version = try provider.withConnection { try $0.query("SELECT sqlite_version() AS v") }
            .first?["v"].stringValue
        XCTAssertEqual(version, expected, "the store runs the bundled SQLite, not the OS's")
        XCTAssertEqual(SQLITE_VERSION, expected, "the JsBaoSQLite module's header is the same release")
    }

    // MARK: - #5227 behaviour 2: the pin file agrees with the wasm build's

    /// `Vendor/JsBaoSQLite/VERSION` names the release the binary is built from,
    /// so a stale pin file fails here even while the binary is right.
    func testThePinFileNamesTheWasmBuildsReleaseAndVec1() throws {
        let lines = try ClientSourceText.packageFile("Vendor/JsBaoSQLite/VERSION").split(separator: "\n").map(String.init)
        let release = try Self.sqliteWasmRelease()
        let parts = release.split(separator: ".").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 3, "a release is major.minor.patch, not \(release)")
        let number = parts.count == 3 ? parts[0] * 1_000_000 + parts[1] * 10_000 + parts[2] * 100 : 0
        XCTAssertEqual(lines.first, "SQLite \(release) amalgamation (sqlite-amalgamation-\(number).zip)")
        XCTAssertEqual(lines.first { $0.hasPrefix("vec1: ") }, try Self.sqliteWasmVec1Line())
    }

    // MARK: - #5227 behaviours 3-4: vec1 answers on the store's connection

    func testTheStoreAnswersVec1Info() async throws {
        let expected = try Self.sqliteWasmVec1()
        let provider = try await provider()
        let info = try provider.withConnection { try $0.query("SELECT vec1_info() AS v") }.first?["v"].stringValue
        XCTAssertTrue(info?.hasPrefix("version \(expected) ") == true, "vec1_info(): \(info ?? "nil")")
    }

    /// js-bao's browser probe's fixture (#5226): row 2 is nearest to the query
    /// point, at squared L2 distance 0.02.
    func testTheStoreAnswersANearestNeighbourQueryThroughVec1() async throws {
        let provider = try await provider()
        try provider.withConnection { connection in
            try connection.executeScript("CREATE VIRTUAL TABLE v USING vec1")
            try connection.executeScript(#"INSERT INTO v(cmd, arg) VALUES ('rebuild', '{index:"flat",distance:"l2"}')"#)
            for (rowid, vector) in [(1, "[0,0,1]"), (2, "[1,0,0]"), (3, "[0,1,0]")] {
                try connection.execute(
                    "INSERT INTO v(rowid, vector) VALUES (?, vec1_from_json(?))", [.integer(Int64(rowid)), .text(vector)]
                )
            }
            let query = "[0.9,0.1,0]"
            let nearest = try connection.query(
                "SELECT rowid, vec1_l2_distance(vector, vec1_from_json(?)) AS d FROM v(vec1_from_json(?), '{K:3}') ORDER BY d LIMIT 1",
                [.text(query), .text(query)]
            ).first
            XCTAssertEqual(nearest?["rowid"].intValue, 2)
            guard case let .real(distance)? = nearest?["d"] else {
                return XCTFail("the distance is a real: \(String(describing: nearest?["d"]))")
            }
            XCTAssertEqual(distance, 0.02, accuracy: 1e-6)
        }
    }

    // MARK: - #5227 behaviour 5: SQLite sets vec1 up itself, on each connection it opens

    /// The hook is `SQLITE_EXTRA_AUTOEXT`, run by every connection as it opens,
    /// beside FTS5. Neither initialization hook is used: under `THREADSAFE=1`
    /// `SQLITE_EXTRA_INIT_MUTEXED` deadlocks registering an auto-extension (the
    /// registration allocates while holding the static main mutex, and the
    /// allocation re-enters initialization, which takes that mutex again), and
    /// `SQLITE_EXTRA_INIT` runs after SQLite counts itself initialized, so a
    /// concurrent first connection could open without vec1.
    func testTheBundledSQLiteSetsUpVec1OnEachConnectionItOpens() async throws {
        let provider = try await provider()
        let options = Set(try provider.withConnection { try $0.query("PRAGMA compile_options") }
            .compactMap { $0["compile_options"].stringValue })
        for option in [
            "EXTRA_AUTOEXT=jsbao_sqlite3_vec1_autoext", "THREADSAFE=1", "OMIT_LOAD_EXTENSION", "ENABLE_FTS5",
            "ENABLE_MATH_FUNCTIONS", "OMIT_DEPRECATED",
            // #5230: as js-bao's sqlite-wasm build has it, so a measurement reads a store's pages by table.
            "ENABLE_DBSTAT_VTAB",
        ] {
            XCTAssertTrue(options.contains(option), "\(option) missing from \(options.sorted())")
        }
        XCTAssertEqual(
            options.filter { $0.hasPrefix("EXTRA_INIT=") || $0.hasPrefix("EXTRA_INIT_MUTEXED=") }, [],
            "no initialization hook"
        )
    }

    // MARK: - #5227 behaviour 6: one vec1 source for every device build

    func testTheVendoredVec1IsTheNodePackagesCopy() throws {
        let swift = ClientSourceText.packageRoot.appendingPathComponent("Vendor/JsBaoSQLite/vec1.c")
        let node = ClientSourceText.repoRoot.appendingPathComponent("packages/primitive-vec1-node/src/vec1.c")
        let vendored = try XCTUnwrap(FileManager.default.contents(atPath: swift.path), "\(swift.path) is missing")
        let reference = try XCTUnwrap(FileManager.default.contents(atPath: node.path), "\(node.path) is missing")
        XCTAssertFalse(reference.isEmpty)
        XCTAssertTrue(vendored == reference, "Vendor/JsBaoSQLite/vec1.c differs from packages/primitive-vec1-node/src/vec1.c")
    }

    // MARK: - #5227 behaviour 7: any connection the library opens has vec1

    func testARawConnectionOpenedOutsideTheStoreAnswersVec1() throws {
        let expected = try Self.sqliteWasmVec1()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT vec1_info()", -1, &statement, nil) == SQLITE_OK else {
            return XCTFail(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW, String(cString: sqlite3_errmsg(db)))
        let info = sqlite3_column_text(statement, 0).map { String(cString: $0) }
        XCTAssertTrue(info?.hasPrefix("version \(expected) ") == true, "vec1_info(): \(info ?? "nil")")
    }

    func testTheBundledSQLiteIsBuiltThreadSafeWithoutLoadableExtensions() async throws {
        let provider = try await provider()
        let options = Set(try provider.withConnection { try $0.query("PRAGMA compile_options") }
            .compactMap { $0["compile_options"].stringValue })
        XCTAssertTrue(options.contains("THREADSAFE=1"), "compile options: \(options.sorted())")
        XCTAssertTrue(options.contains("OMIT_LOAD_EXTENSION"), "compile options: \(options.sorted())")
    }

    // MARK: - #5223 behaviour 1: FTS5 is compiled in

    /// A device text index is a contentless FTS5 table (#5223, kept by the
    /// `'delete'` command since #5309), so the bundled SQLite carries FTS5,
    /// beside the options it already had.
    func testTheBundledSQLiteIsBuiltWithFTS5() async throws {
        let provider = try await provider()
        let options = Set(try provider.withConnection { try $0.query("PRAGMA compile_options") }
            .compactMap { $0["compile_options"].stringValue })
        XCTAssertTrue(options.contains("ENABLE_FTS5"), "compile options: \(options.sorted())")
        XCTAssertTrue(options.contains("THREADSAFE=1"), "compile options: \(options.sorted())")
        XCTAssertTrue(options.contains("OMIT_LOAD_EXTENSION"), "compile options: \(options.sorted())")
        try provider.withConnection { connection in
            try connection.executeScript(
                "CREATE VIRTUAL TABLE t USING fts5(f0, content='', tokenize='unicode61 remove_diacritics 2')"
            )
            try connection.executeScript("INSERT INTO t (rowid, f0) VALUES (1, 'Crème brûlée')")
            let hits = try connection.query("SELECT rowid AS id FROM t WHERE t MATCH '\"creme\"'")
            XCTAssertEqual(hits.compactMap { $0["id"].intValue }, [1])
        }
    }

    // MARK: - Behaviour 2: nothing links the system SQLite

    /// Every `.swift` file under `directory`, as (path relative to the
    /// repository, contents).
    private static func swiftFiles(under directory: String) throws -> [(String, String)] {
        let root = ClientSourceText.repoRoot.appendingPathComponent(directory)
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw XCTSkip("cannot walk \(directory)")
        }
        var files: [(String, String)] = []
        for case let url as URL in walk where url.pathExtension == "swift" {
            let relative = directory + url.path.dropFirst(root.path.count)
            files.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    func testNoSourceImportsTheSystemSQLiteModule() throws {
        var importing: [String] = []
        for directory in ["swift-client/Sources", "packages/swift-primitive-app/Sources"] {
            let files = try Self.swiftFiles(under: directory)
            XCTAssertFalse(files.isEmpty, "\(directory) holds Swift sources")
            for (path, text) in files where text.split(separator: "\n").contains(where: {
                $0.trimmingCharacters(in: .whitespaces) == "import SQLite3"
            }) {
                importing.append(path)
            }
        }
        XCTAssertEqual(importing, [], "these files still import the system SQLite3 module")
    }

    func testNoManifestLinksTheSystemSQLiteLibrary() throws {
        for manifest in ["swift-client/Package.swift", "packages/swift-primitive-app/Package.swift"] {
            let text = ClientSourceText.stripComments(try ClientSourceText.repoFile(manifest))
            XCTAssertFalse(text.contains("linkedLibrary(\"sqlite3\""), "\(manifest) links the system sqlite3")
        }
    }

    // MARK: - Edge 36: Core Data keeps the OS's SQLite, on its own file

    /// A pin, not a red: the two libraries live side by side in one process,
    /// each on its own file, which is the invariant the bundling relies on.
    func testCoreDataAndTheStoreCoexistOnTheirOwnFiles() async throws {
        let directory = NSTemporaryDirectory() + "bundled-sqlite-coredata-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let entity = NSEntityDescription()
        entity.name = "Note"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        let title = NSAttributeDescription()
        title.name = "title"
        title.attributeType = .stringAttributeType
        entity.properties = [title]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        let container = NSPersistentContainer(name: "BundledSQLite", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: URL(fileURLWithPath: directory + "/coredata.sqlite"))
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        XCTAssertNil(loadError)

        let provider = SQLiteStorageProvider(path: directory + "/store.sqlite")
        try await provider.initialize(namespace: "bundled-sqlite-coredata")
        defer { Task { await provider.close() } }

        let context = container.viewContext
        let note = NSManagedObject(entity: entity, insertInto: context)
        note.setValue("from core data", forKey: "title")
        try context.save()
        try await provider.put(store: "documents", key: "k", value: "from the store", metadata: nil)

        let fetched = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Note"))
        XCTAssertEqual(fetched.compactMap { $0.value(forKey: "title") as? String }, ["from core data"])
        let stored: StorageRecord<String>? = try await provider.get(store: "documents", key: "k")
        XCTAssertEqual(stored?.value, "from the store")
        let version = try provider.withConnection { try $0.query("SELECT sqlite_version() AS v") }
            .first?["v"].stringValue
        let expected = try Self.sqliteWasmRelease()
        XCTAssertEqual(version, expected, "the store keeps the bundled SQLite beside Core Data")
    }

    // MARK: - #5227 edge 16: a store the earlier release wrote opens on this one

    /// `Fixtures/BundledSQLite/store-3.53.4.sqlite` was written by the bundled
    /// 3.53.4 (three `documents` rows and a contentless FTS5 table), captured
    /// before the move; the test opens a copy, never the fixture.
    func testAStoreWrittenByTheEarlierReleaseOpensReadsAndWrites() async throws {
        let fixture = ClientSourceText.packageRoot
            .appendingPathComponent("Tests/JsBaoClientTests/Fixtures/BundledSQLite/store-3.53.4.sqlite")
        let directory = NSTemporaryDirectory() + "bundled-sqlite-upgrade-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/store.sqlite"
        try FileManager.default.copyItem(atPath: fixture.path, toPath: path)

        let provider = SQLiteStorageProvider(path: path)
        try await provider.initialize(namespace: "store-3.53.4")
        for i in 1...3 {
            let stored: StorageRecord<String>? = try await provider.get(store: "documents", key: "doc-\(i)")
            XCTAssertEqual(stored?.value, "value \(i) written by 3.53.4")
        }
        try await provider.put(store: "documents", key: "doc-4", value: "written by the new release", metadata: nil)
        let written: StorageRecord<String>? = try await provider.get(store: "documents", key: "doc-4")
        XCTAssertEqual(written?.value, "written by the new release")
        try provider.withConnection { connection in
            let hits = try connection.query("SELECT rowid AS id FROM notes_text WHERE notes_text MATCH '\"creme\"'")
            XCTAssertEqual(hits.compactMap { $0["id"].intValue }, [1])
            XCTAssertEqual(try connection.query("PRAGMA integrity_check").first?["integrity_check"].stringValue, "ok")
        }
        let version = try provider.withConnection { try $0.query("SELECT sqlite_version() AS v") }
            .first?["v"].stringValue
        XCTAssertEqual(version, try Self.sqliteWasmRelease())
        await provider.close()
    }

    // MARK: - #5227 edge 17: no loadable extensions

    func testLoadExtensionIsRefused() async throws {
        let provider = try await provider()
        XCTAssertThrowsError(try provider.withConnection { try $0.query("SELECT load_extension('x')") }) { error in
            XCTAssertTrue("\(error)".contains("no such function: load_extension"), "\(error)")
        }
    }

    // MARK: - #5227 edge 18: the device text table as #5224 left it

    /// The device DDL since #5224: contentless without `contentless_delete`,
    /// kept by FTS5's `'delete'` command and ranked by `bm25`.
    func testAContentlessTextTableKeptByTheDeleteCommandRanksWithBm25() async throws {
        let provider = try await provider()
        try provider.withConnection { connection in
            try connection.executeScript(
                "CREATE VIRTUAL TABLE t USING fts5(f0, content='', tokenize='unicode61 remove_diacritics 2')"
            )
            try connection.executeScript(
                "INSERT INTO t (rowid, f0) VALUES (1, 'x'), (2, 'Crème brûlée crème'), (3, 'crème anglaise')"
            )
            try connection.executeScript("INSERT INTO t(t, rowid, f0) VALUES ('delete', 1, 'x')")
            let ranked = try connection.query(
                "SELECT rowid AS id, -bm25(t) AS score FROM t WHERE t MATCH '\"creme\"' ORDER BY score DESC"
            )
            XCTAssertEqual(ranked.compactMap { $0["id"].intValue }, [2, 3])
            XCTAssertEqual(try connection.query("SELECT rowid AS id FROM t WHERE t MATCH 'x'").count, 0)
        }
    }
}
