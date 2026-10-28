import Foundation
import XCTest
@testable import JsBaoClient

/// The client-callable doors server-functions phase 5 retired are gone from
/// the Swift client (#3188).
///
/// `workflows.runSync` called `POST workflows/{key}/run-sync`, `client.prompts`
/// and `client.integrations` called the member prompt-execute and
/// integration-proxy routes, and `databases.listOperations` /
/// `executeOperation` / `executeBatch` (with the `importRows` / `importCsv`
/// conveniences over it) called the operation routes. Each is replaced by a
/// server function the app calls with `client.functions.invoke`. Phase 6
/// (#3189) then retired `client.databases` whole, operation CRUD included —
/// `DatabasesRetiredHermeticTests` pins that.
///
/// A method that is gone cannot be called to show it is gone, so the removals
/// are read off the comment-stripped source (`ClientSourceText`), the same way
/// `FunctionsAPIHermeticTests` pins the functions method set.
final class PhaseFiveRetiredDoorsHermeticTests: XCTestCase {

    private func declaredFunctions(_ source: String) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"public func ([A-Za-z_][A-Za-z0-9_]*)"#)
        let range = NSRange(source.startIndex..., in: source)
        return Set(pattern.matches(in: source, range: range).compactMap { match -> String? in
            guard let r = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[r])
        })
    }

    func testNoSourceReachesTheRunSyncRoute() throws {
        // #3190 — `WorkflowsAPI` itself retired with the DSL engine, so no
        // client file can declare `runSync`; what is pinned is that nothing
        // left reaches the retired route.
        let api = ClientSourceText.packageRoot.appendingPathComponent("Sources/JsBaoClient/API")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: api.appendingPathComponent("WorkflowsAPI.swift").path),
            "WorkflowsAPI.swift retired with client.workflows (#3190)"
        )
        let sources = try ClientSourceText.allClientSources().map(ClientSourceText.stripComments)
        XCTAssertFalse(sources.contains { $0.contains("/run-sync") }, "no request reaches the retired route")
        for source in sources {
            XCTAssertFalse(try declaredFunctions(source).contains("runSync"))
        }
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

    func testNoSourceCarriesAnOperationDoor() throws {
        // The operation execute and batch doors were #3188's; the CRUD the
        // phase-5 pin kept "until phase 6" is gone with `DatabasesAPI`
        // (#3189), so no source names an operation route at all.
        let api = ClientSourceText.packageRoot.appendingPathComponent("Sources/JsBaoClient/API")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: api.appendingPathComponent("DatabasesAPI.swift").path),
            "DatabasesAPI.swift retired with client.databases (#3189)"
        )
        let sources = try ClientSourceText.allClientSources().map(ClientSourceText.stripComments)
        for retired in ["/operations/", "/execute\"", "struct DatabaseOperationInfo"] {
            XCTAssertFalse(sources.contains { $0.contains(retired) }, "\(retired) belonged to a retired door")
        }
    }
}
