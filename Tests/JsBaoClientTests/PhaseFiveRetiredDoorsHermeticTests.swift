import Foundation
import XCTest
@testable import JsBaoClient

/// The client-callable doors server-functions phase 5 retired are gone from
/// the Swift client, and the operation CRUD surface phase 6 owns is not
/// (#3188).
///
/// `workflows.runSync` called `POST workflows/{key}/run-sync`, `client.prompts`
/// and `client.integrations` called the member prompt-execute and
/// integration-proxy routes, and `databases.listOperations` /
/// `executeOperation` / `executeBatch` (with the `importRows` / `importCsv`
/// conveniences over it) called the operation routes that are admin-only now.
/// Each is replaced by a server function the app calls with
/// `client.functions.invoke`.
///
/// A method that is gone cannot be called to show it is gone, so the removals
/// are read off the comment-stripped source (`ClientSourceText`), the same way
/// `FunctionsAPIHermeticTests` pins the functions method set. What survives is
/// exercised: `getOperation` still answers a decoded `DatabaseOperationInfo`.
final class PhaseFiveRetiredDoorsHermeticTests: XCTestCase {

    private func declaredFunctions(_ source: String) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"public func ([A-Za-z_][A-Za-z0-9_]*)"#)
        let range = NSRange(source.startIndex..., in: source)
        return Set(pattern.matches(in: source, range: range).compactMap { match -> String? in
            guard let r = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[r])
        })
    }

    func testWorkflowsApiCarriesNoRunSync() throws {
        let source = try ClientSourceText.code("API/WorkflowsAPI.swift")
        XCTAssertFalse(try declaredFunctions(source).contains("runSync"))
        XCTAssertFalse(source.contains("/run-sync"), "no request reaches the retired route")
    }

    func testTheClientCarriesNoPromptsOrIntegrationsFacade() throws {
        let client = try ClientSourceText.code("JsBaoClient.swift")
        XCTAssertFalse(client.contains("let prompts:"), "client.prompts retired")
        XCTAssertFalse(client.contains("let integrations:"), "client.integrations retired")

        let api = ClientSourceText.packageRoot.appendingPathComponent("Sources/JsBaoClient/API")
        for file in ["PromptsAPI.swift", "IntegrationsAPI.swift"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: api.appendingPathComponent(file).path),
                "\(file) retired with its member route"
            )
        }
    }

    func testNoSourceDeclaresARetiredType() throws {
        let sources = try ClientSourceText.allClientSources().map(ClientSourceText.stripComments)
        for declaration in [
            "class PromptsAPI",
            "class IntegrationsAPI",
            "struct ExecuteOperationOptions",
            "struct RunSyncWorkflowResult",
            "struct RunSyncResult",
            "struct CsvImportOptions",
        ] {
            XCTAssertFalse(
                sources.contains { $0.contains(declaration) },
                "\(declaration) belonged only to a retired door"
            )
        }
    }

    func testDatabasesApiDropsTheExecuteDoorsAndKeepsOperationCrud() throws {
        let source = try ClientSourceText.code("API/DatabasesAPI.swift")
        let functions = try declaredFunctions(source)
        for retired in ["listOperations", "executeOperation", "executeBatch", "importRows", "importCsv"] {
            XCTAssertFalse(functions.contains(retired), "\(retired) retired (#3188)")
        }
        XCTAssertFalse(source.contains("/execute\""), "no request reaches the execute route")
        XCTAssertFalse(source.contains("/batch\""), "no request reaches the batch route")

        // The operation concept is phase 6's: its CRUD methods and the type
        // they return stay, unchanged.
        for kept in ["createOperation", "getOperation", "updateOperation", "deleteOperation"] {
            XCTAssertTrue(functions.contains(kept), "\(kept) stays until phase 6")
        }
        for kept in ["createOperation", "getOperation", "updateOperation"] {
            XCTAssertTrue(
                source.range(
                    of: #"public func \#(kept)\([^)]*\) async throws -> DatabaseOperationInfo"#,
                    options: .regularExpression
                ) != nil,
                "\(kept) still returns DatabaseOperationInfo"
            )
        }
    }

    func testGetOperationStillDecodesDatabaseOperationInfo() async throws {
        let transport = RecordingTransport(json: #"""
        {"databaseId":"db_1","name":"listThings","type":"query","modelName":"Thing",
         "access":"true","definition":{},"createdBy":"u_1",
         "createdAt":"2026-10-07T00:00:00Z","modifiedAt":"2026-10-07T00:00:00Z"}
        """#)
        let info: DatabaseOperationInfo = try await DatabasesAPI(transport: transport)
            .getOperation(databaseId: "db_1", name: "listThings")
        XCTAssertEqual(info.name, "listThings")
        XCTAssertEqual(info.modelName, "Thing")
        XCTAssertEqual(transport.lastCall?.path, "/databases/db_1/operations/listThings")
    }
}
