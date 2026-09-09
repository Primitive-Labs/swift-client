import XCTest
@testable import JsBaoClient
import YSwift

/// A confirmed local-only document is not reported as holding unsynced changes
/// forever (issue #3200, review finding F4).
///
/// `hasUnsyncedLocalChanges` has a Swift-only third clause — "open but the
/// initial sync has not completed". A local-only document opened with
/// `enableNetworkSync: false` can never receive a sync completion, so that
/// clause never clears: `documents.evict` threw without `force` and
/// `evictAll(onlySynced:)` skipped the document forever. JS's guard is the
/// outbound flag map alone (`src/client/internal/documentManager.ts`), so the
/// clause is dropped for documents whose local-only classification is
/// confirmed. A document whose classification is still pending (#2691's unknown
/// state) keeps the conservative guard.
///
/// Server-free: unreachable URLs, memory storage, no connection.
final class LocalOnlyEvictParityHermeticTests: XCTestCase {

    private func makeClient(_ appId: String) -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:1",
            wsUrl: "ws://127.0.0.1:1",
            appId: appId,
            offline: true,
            logLevel: .none,
            storageConfig: .memory,
            sync: SyncConfig(outboundDebounce: 0),
            autoNetwork: false
        ))
    }

    private func createLocalOnly(_ client: JsBaoClient) async throws -> String {
        let result = try await client.createDocument(
            options: CreateDocumentOptions(title: "local only", localOnly: true)
        )
        return try XCTUnwrap(result.metadata?["documentId"]?.stringValue)
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    // MARK: - Behavior 22: the public status is truthful for local-only

    func testOpenedLocalOnlyDocumentReportsNoUnsyncedChangesAfterAWrite() async throws {
        let client = makeClient("local-only-evict-truthful")
        defer { Task { await client.destroy() } }
        _ = await client.waitForStorageReady()

        let documentId = try await createLocalOnly(client)
        let doc = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in map.updateValue("v", forKey: "k", transaction: txn) }
        await settle()

        XCTAssertTrue(client.documentManager.isLocalOnly(documentId))
        XCTAssertFalse(
            client.documentManager.hasUnsyncedLocalChanges(documentId),
            "a local-only document has no server to be out of sync with"
        )
    }

    func testOpenedLocalOnlyDocumentCanBeEvictedWithoutForce() async throws {
        let client = makeClient("local-only-evict-no-force")
        defer { Task { await client.destroy() } }
        _ = await client.waitForStorageReady()

        let documentId = try await createLocalOnly(client)
        let doc = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        let map: YMap<String> = doc.getOrCreateMap(named: "m")
        doc.transactSync { txn in map.updateValue("v", forKey: "k", transaction: txn) }
        await settle()

        try await client.documents.evict(documentId: documentId)
    }

    func testEvictAllOnlySyncedDoesNotSkipALocalOnlyDocument() async throws {
        let client = makeClient("local-only-evict-all")
        defer { Task { await client.destroy() } }
        _ = await client.waitForStorageReady()

        let documentId = try await createLocalOnly(client)
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        await settle()

        XCTAssertNotNil(
            client.documentManager.getLocalMetadata(documentId),
            "precondition: the created document has a local metadata row"
        )

        await client.documents.evictAll(options: EvictAllDocumentsOptions(onlySynced: true))

        // The row is what eviction takes away. (`hasLocalCopy` deliberately
        // keeps reporting a local copy for a local-only document that is still
        // open — #2691 — so it cannot tell an eviction from a skip.)
        XCTAssertNil(
            client.documentManager.getLocalMetadata(documentId),
            "an onlySynced sweep must not skip a local-only document forever"
        )
    }

    // MARK: - The guard is retained for everything else

    func testOrdinaryOpenDocumentAwaitingItsFirstSyncStillReportsUnsynced() async throws {
        let client = makeClient("local-only-evict-control")
        defer { Task { await client.destroy() } }
        _ = await client.waitForStorageReady()

        let documentId = "ordinary-unsynced-doc"
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )

        XCTAssertTrue(
            client.documentManager.hasUnsyncedLocalChanges(documentId),
            "an ordinary document that has not completed its initial sync keeps the guard"
        )
        do {
            try await client.documents.evict(documentId: documentId)
            XCTFail("evict without force must refuse a document with unsynced changes")
        } catch {
            let jsBaoError = try XCTUnwrap(error as? JsBaoError)
            XCTAssertEqual(jsBaoError.code, .invalidArgument)
        }
    }

    func testLocalOnlyDocumentWithPendingClassificationKeepsTheGuard() async throws {
        // #2691's unknown state: the store could not be read, so "local-only"
        // is a guess. The conservative guard stays until it is confirmed.
        let client = makeClient("local-only-evict-pending-classification")
        defer { Task { await client.destroy() } }
        _ = await client.waitForStorageReady()

        let documentId = "unclassified-local-only-doc"
        _ = try await client.openDocument(
            documentId,
            options: OpenDocumentOptions(waitForLoad: .local, enableNetworkSync: false)
        )
        client.documentManager.setMetadata(
            documentId,
            entry: LocalMetadataEntry(documentId: documentId, pendingCreate: false, localOnly: true)
        )
        client.documentManager.markLocalOnlyClassificationPendingForTest(documentId)

        XCTAssertTrue(
            client.documentManager.hasUnsyncedLocalChanges(documentId),
            "a document whose local-only classification is still pending keeps the guard"
        )
    }
}
