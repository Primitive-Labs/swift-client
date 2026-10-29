import Foundation
import XCTest
@testable import JsBaoClient

/// The Swift client has no locks API (#4959).
///
/// Named locks are server-function-only: a direct call to `locks/acquire`,
/// `locks/renew` or `locks/release` is refused `FUNCTION_ROUTE_FUNCTION_ONLY`,
/// so an app takes a lock in a server function (`ctx.locks`) it invokes with
/// `client.functions`. `client.locks`, its types and `.lockTimeout` are gone.
///
/// A member that is gone cannot be called to show it is gone, so the removals
/// are read off the comment-stripped sources (`ClientSourceText`), the
/// `DatabasesRetiredHermeticTests` shape.
final class LocksRetiredHermeticTests: XCTestCase {

    private static let retiredFiles = [
        "API/LocksAPI.swift",
        "Types/LocksTypes.swift",
    ]

    func testTheLockSourcesAreGone() {
        let sources = ClientSourceText.packageRoot.appendingPathComponent("Sources/JsBaoClient")
        for file in Self.retiredFiles {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: sources.appendingPathComponent(file).path),
                "\(file) retired with client.locks"
            )
        }
    }

    func testTheClientHasNoLocksMember() throws {
        let client = try ClientSourceText.code("JsBaoClient.swift")
        XCTAssertFalse(client.contains("let locks:"), "client.locks retired")
        XCTAssertFalse(client.contains("LocksAPI("), "client.locks retired")
        XCTAssertTrue(client.contains("let functions:"), "client.functions stays")
    }

    func testNoSourceDeclaresARetiredLockType() throws {
        let sources = try ClientSourceText.allClientSources().map(ClientSourceText.stripComments)
        for declaration in [
            "class LocksAPI",
            "struct LockHandle",
            "struct LockContention",
            "struct LockAcquireResponse",
            "struct LockStatus",
            "struct LockListEntry",
        ] {
            XCTAssertFalse(
                sources.contains { $0.contains(declaration) },
                "\(declaration) retired with client.locks"
            )
        }
    }

    func testThereIsNoLockTimeoutCode() {
        XCTAssertNil(JsBaoErrorCode(rawValue: "LOCK_TIMEOUT"))
    }
}
