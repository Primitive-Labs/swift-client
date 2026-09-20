import XCTest
@testable import JsBaoClient
import YSwift

/// What a purge has to REACH, and which doors an eviction can arrive through
/// (#3436, decision 3436-SO-06).
///
/// Criterion 7 is about a previous account's data not surviving a wipe, so the
/// question here is never "does the purge delete what it was told about" — the
/// suite beside this one asks that — but "does it find everything, and does it
/// run at all". Both of those are answered by inventory and by wiring rather
/// than by the delete statements.
final class Format2PurgeReachHermeticTests: XCTestCase {

    private var directories: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(atPath: directory) }
        directories = []
        super.tearDown()
    }

    private static func schema(withExtraField extra: Bool) -> PrimitiveSchema {
        var fields: [String: FieldDescriptor] = [
            "id": FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string, required: true),
        ]
        if extra { fields["addedLater"] = FieldDescriptor(type: .string) }
        return PrimitiveSchema(name: "Note", fields: fields)
    }

    private func newDatabaseDirectory() -> String {
        let directory = NSTemporaryDirectory() + "/f2-reach-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        directories.append(directory)
        return directory
    }

    private func newDatabasePath() -> String { newDatabaseDirectory() + "/store.sqlite" }

    private func makeProvider() async throws -> SQLiteStorageProvider {
        let provider = SQLiteStorageProvider(path: newDatabasePath())
        try await provider.initialize(namespace: "test")
        return provider
    }

    /// Rows the derived query table holds, by document.
    private func projectedRowCounts(
        _ host: any Format2SqlHost
    ) throws -> [String: Int] {
        try host.withConnection { connection in
            let table = BaoModelQueryEngine.sanitizeTableName("Note")
            let present = try connection.query(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                [.text(table)]
            )
            guard !present.isEmpty else { return [:] }
            var out: [String: Int] = [:]
            for row in try connection.query(
                "SELECT \"_meta_doc_id\" AS d, COUNT(*) AS n FROM \"\(table)\" GROUP BY d"
            ) {
                guard let documentId = row["d"].stringValue else { continue }
                out[documentId] = row["n"].intValue ?? 0
            }
            return out
        }
    }

    /// Two large documents on one database, each with a record projected into
    /// the shared query table.
    private func twoProjectedDocuments(
        _ host: any Format2SqlHost
    ) throws -> (coordinator: Format2Coordinator, first: String, second: String) {
        let coordinator = Format2Coordinator(
            host: host, clientId: "me", logger: Logger(level: .none)
        )
        var ids: [String] = []
        for index in 0..<2 {
            let documentId = "reach-\(index)-\(UUID().uuidString.prefix(8))"
            let doc = YDocument()
            let binding = try coordinator.bind(
                documentId: documentId, models: ["Note"], document: doc
            )
            _ = try binding.writePath.write(
                model: "Note",
                mutation: OverlayMutation(
                    id: "n\(index)", kind: .create, fields: ["title": .string("t")]
                ),
                fields: ["title"]
            )
            binding.projectModel(Self.schema(withExtraField: false))
            ids.append(documentId)
        }
        return (coordinator, ids[0], ids[1])
    }

    // MARK: - The inventory

    /// The projection MARKS say which models are projected and up to date.
    /// That is not an inventory of what is on disk, and taking it for one
    /// leaves rows behind: widening a model's table for a schema that gained a
    /// field withdraws every mark for that model — for every document at once
    /// — while the rows stay exactly where they were.
    func testAPurgeReachesRowsWhoseProjectionMarkWasWithdrawn() async throws {
        let host = try await makeProvider()
        let (_, first, second) = try twoProjectedDocuments(host)
        XCTAssertEqual(
            try projectedRowCounts(host), [first: 1, second: 1],
            "precondition: both documents have a projected row"
        )

        // The app ships a schema with a new field. The table is widened and
        // every mark for the model is withdrawn so each document re-projects.
        let projection = Format2QueryProjection(host: host, logger: Logger(level: .none))
        let store = Format2RecordStore(host: host, documentId: first, clientId: "me")
        _ = try? projection.ensureProjected(
            schema: Self.schema(withExtraField: true), store: store
        )

        try Format2RecordStore.purge(host: host, documentId: first)
        XCTAssertNil(
            try projectedRowCounts(host)[first],
            "the purge walked past rows whose mark a schema widening had withdrawn"
        )
        XCTAssertEqual(
            try projectedRowCounts(host)[second], 1,
            "and the sibling document's projected row is untouched"
        )
    }

    /// The same for the account wipe, which is the one criterion 7 names.
    func testPurgeAllReachesRowsWhoseProjectionMarkWasWithdrawn() async throws {
        let host = try await makeProvider()
        let (_, first, second) = try twoProjectedDocuments(host)

        let projection = Format2QueryProjection(host: host, logger: Logger(level: .none))
        let store = Format2RecordStore(host: host, documentId: first, clientId: "me")
        _ = try? projection.ensureProjected(
            schema: Self.schema(withExtraField: true), store: store
        )

        try Format2RecordStore.purgeAll(host: host)
        let remaining = try projectedRowCounts(host)
        XCTAssertEqual(
            remaining, [:],
            "an account wipe left a previous account's projected rows on disk: \(remaining)"
        )
        _ = (first, second)
    }

    // MARK: - The doors an eviction arrives through

    /// `documents.evict` is not the only one. `markMetadataDeleted`, an
    /// evicting close, the retention sweep and the handling of a document the
    /// server reports gone all go straight to `DocumentManager.evictLocalData`
    /// without passing through `JsBaoClient.evictLocalDocument`. A purge wired
    /// only to that method reports the document gone and leaves its records,
    /// its pending ops and its epoch mark where they were.
    ///
    /// `markMetadataDeleted` is the door driven here because its contract is
    /// the least ambiguous: its own documentation says Swift diverges from
    /// js-bao deliberately, because "callers want data actually gone, not just
    /// marked".
    func testMarkMetadataDeletedLeavesNothingOfALargeDocument() async throws {
        let client = await makeClient(databasePath: newDatabasePath())
        defer { Task { await client.destroy() } }

        let documentId = "reach-close-\(UUID().uuidString.prefix(8))"
        client.documentManager.createRemoteDocument = { _ in ["documentId": documentId] }
        _ = try await client.documentManager.createLocalDocument(
            documentId: documentId, title: "close", localOnly: false, documentFormat: 2
        )
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(enableNetworkSync: false, deferNetworkSync: true)
        )
        let binding = try XCTUnwrap(client.format2?.binding(documentId))
        _ = try binding.writePath.write(
            model: "Note",
            mutation: OverlayMutation(
                id: "n1", kind: .create, fields: ["title": .string("t")]
            ),
            fields: ["title"]
        )

        let stored = await client.offlineStore.getStorageProvider()
        let provider = try XCTUnwrap(stored)
        let host = try Format2Storage.host(for: provider)
        let before = try traces(host, documentId)
        XCTAssertFalse(before.isEmpty, "precondition: the document is on disk")

        await client.markMetadataDeleted(documentId)

        let after = try traces(host, documentId)
        XCTAssertEqual(
            after, [],
            "an eviction that did not come through `evictLocalDocument` left the "
            + "document's data behind: \(after)"
        )
    }

    private func traces(
        _ host: any Format2SqlHost, _ documentId: String
    ) throws -> [String] {
        var out: [String] = []
        let tables = Format2TableNames(documentId: documentId)
        let present = try host.withConnection { connection in
            Set(
                try connection.query("SELECT name FROM sqlite_master WHERE type = 'table'")
                    .compactMap { $0["name"].stringValue }
            )
        }
        for table in [tables.records, tables.stringSetIndex] where present.contains(table) {
            out.append("table \(table)")
        }
        for row in try Format2RecordStore.sharedRowCounts(host: host, documentId: documentId)
        where row.count > 0 {
            out.append("\(row.count) row(s) in \(row.table)")
        }
        return out
    }

    private func makeClient(databasePath: String) async -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: TestConfig.httpUrl,
            wsUrl: "ws://127.0.0.1:1",
            appId: "format2-purge-reach-test-app",
            token: makeTestJwt(userId: "reach-user"),
            offline: true,
            globalAdminAppId: TestConfig.globalAdminAppId,
            logLevel: .none,
            storageConfig: .sqlite(directory: databasePath),
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
        _ = await client.waitForStorageReady()
        client.registerModels([Self.schema(withExtraField: false)])
        return client
    }
}
