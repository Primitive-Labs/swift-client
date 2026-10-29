import XCTest
@testable import JsBaoClient

/// #5000 behavior 25 — every public `client.db3` method that sends a request
/// naming a db3 waits for that db3's pending create first.
///
/// The db3 API files are read (comments stripped) and each public method of
/// each class is found, so a method added later is checked without being
/// listed here. A method whose body sends through its transport must call
/// `awaitCreate(_:)`, the wait for a pending create's commit, unless it is
/// listed below with the reason it does not wait. A `Db3API` with a wired
/// client is checked live by `Db3LocalFirstCreateLiveTests`, behavior 24.
final class Db3PendingCreateWaitHermeticTests: XCTestCase {

    private static let files = ["API/Db3API.swift", "API/Db3PermissionsAPI.swift", "API/Db3IngestsAPI.swift"]

    /// Methods that never wait, by class, and why.
    private static let excluded: [String: [String: String]] = [
        "Db3API": [
            "subscribe": "local lifecycle: a pending create's subscription is available at once and ready after the commit",
            "unsubscribe": "local lifecycle",
            "refresh": "local lifecycle",
            "state": "local lifecycle",
            "evict": "local lifecycle",
            "stored": "local lifecycle, no id",
            "setRetentionPolicy": "local lifecycle, no id",
            "blobs": "its upload queue holds work for a db3 the server does not have yet",
            "delete": "keeps its behaviour on a pending create",
            "create": "creates the db3",
            "getOrCreateWithAlias": "creates the db3",
            "listMine": "names no db3",
            "permissions": "answers a Db3PermissionsAPI, whose methods are checked",
        ],
        "Db3IngestsAPI": ["buildChunks": "builds chunks on this device"],
    ]

    /// One public method: its class, name and body.
    private struct Method {
        let owner: String
        let name: String
        let body: String
    }

    private static func methods() throws -> [Method] {
        var found: [Method] = []
        for file in files {
            let code = try ClientSourceText.code(file)
            let classes = try NSRegularExpression(pattern: #"public final class (\w+)"#)
                .matches(in: code, range: NSRange(code.startIndex..., in: code))
                .compactMap { match -> (String.Index, String)? in
                    guard let whole = Range(match.range, in: code), let name = Range(match.range(at: 1), in: code) else { return nil }
                    return (whole.lowerBound, String(code[name]))
                }
            let funcs = try NSRegularExpression(pattern: #"public func (\w+)"#)
                .matches(in: code, range: NSRange(code.startIndex..., in: code))
            for match in funcs {
                guard let whole = Range(match.range, in: code), let nameRange = Range(match.range(at: 1), in: code) else { continue }
                guard let owner = classes.last(where: { $0.0 < whole.lowerBound })?.1 else { continue }
                guard let open = code[whole.upperBound...].firstIndex(of: "{") else { continue }
                var depth = 0
                var end = open
                for index in code[open...].indices {
                    if code[index] == "{" { depth += 1 }
                    if code[index] == "}" { depth -= 1 }
                    if depth == 0 { end = index; break }
                }
                found.append(Method(owner: owner, name: String(code[nameRange]), body: String(code[open...end])))
            }
        }
        return found
    }

    func testEveryPublicDb3MethodThatSendsARequestWaitsForAPendingCreate() throws {
        let all = try Self.methods()
        XCTAssertGreaterThan(all.count, 30, "the scan found the db3 API's methods")
        var checked = 0
        for method in all where Self.excluded[method.owner]?[method.name] == nil {
            guard method.body.contains("transport.") else { continue }
            checked += 1
            XCTAssertTrue(
                method.body.contains("awaitCreate("),
                "\(method.owner).\(method.name) sends a request without waiting for a pending create"
            )
        }
        XCTAssertGreaterThan(checked, 25, "the covered methods were checked")
    }

    func testTheExcludedMethodsExist() throws {
        let all = try Self.methods()
        for (owner, names) in Self.excluded {
            for name in names.keys {
                XCTAssertTrue(all.contains { $0.owner == owner && $0.name == name }, "\(owner).\(name) is listed but does not exist")
            }
        }
    }
}
