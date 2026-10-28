import CoreData
import XCTest
@testable import JsBaoClient

/// The Swift client runs on a SQLite of its own, pinned to the release
/// sqlite-wasm carries for the JS client (#4700, intent criterion 7 in part):
/// the store answers the same SQL on every OS it supports, and no database
/// file is opened by two SQLite libraries in one process.
final class BundledSQLiteHermeticTests: XCTestCase {

    /// `@sqlite.org/sqlite-wasm`'s version in `packages/js-bao/package.json`,
    /// with its `-build…` suffix removed (`3.53.4-build2` is SQLite 3.53.4).
    private static func sqliteWasmRelease() throws -> String {
        let text = try ClientSourceText.repoFile("packages/js-bao/package.json")
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let blocks = ["dependencies", "optionalDependencies", "devDependencies"]
        let pinned = try XCTUnwrap(
            blocks.lazy.compactMap { manifest[$0]?["@sqlite.org/sqlite-wasm"]?.stringValue }.first,
            "packages/js-bao/package.json names no @sqlite.org/sqlite-wasm version"
        )
        let release = pinned.trimmingCharacters(in: CharacterSet(charactersIn: "^~"))
        return release.range(of: "-build").map { String(release[..<$0.lowerBound]) } ?? release
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
    }

    func testTheBundledSQLiteIsBuiltThreadSafeWithoutLoadableExtensions() async throws {
        let provider = try await provider()
        let options = Set(try provider.withConnection { try $0.query("PRAGMA compile_options") }
            .compactMap { $0["compile_options"].stringValue })
        XCTAssertTrue(options.contains("THREADSAFE=1"), "compile options: \(options.sorted())")
        XCTAssertTrue(options.contains("OMIT_LOAD_EXTENSION"), "compile options: \(options.sorted())")
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
        XCTAssertEqual(version, try Self.sqliteWasmRelease(), "the store keeps the bundled SQLite beside Core Data")
    }
}
