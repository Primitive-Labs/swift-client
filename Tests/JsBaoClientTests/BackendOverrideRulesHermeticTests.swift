import XCTest
@testable import JsBaoClient

/// The backend resolver's rules (#6185, project `client-backend-overrides`,
/// phase 2; intent criterion 4): which override a copy of the app takes, the
/// URLs it answers, what it ignores and what it skips, and the shared fixture
/// the JS suite holds to the server. Pure functions, no server.
final class BackendOverrideRulesHermeticTests: XCTestCase {

    private static let home = "home-app"
    private static let buildApiUrl = "https://home.example.com/"
    private static let buildWsUrl = "wss://ws.home.example.com/socket"

    private func build(_ version: String, platform: String = "ios") -> BackendBuild {
        BackendBuild(appId: Self.home, apiUrl: Self.buildApiUrl, wsUrl: Self.buildWsUrl, version: version, platform: platform)
    }

    private var homeChoice: BackendChoice {
        BackendChoice(appId: Self.home, apiUrl: Self.buildApiUrl, wsUrl: Self.buildWsUrl, overridden: false)
    }

    private func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// `{"ios": {...extra, "backendOverrides": <list>}}`.
    private func policy(_ list: String, extra: String = "") -> JSONValue {
        json(#"{"ios":{\#(extra.isEmpty ? "" : extra + ",")"backendOverrides":\#(list)}}"#)
    }

    private func choose(_ clients: JSONValue?, _ version: String, platform: String = "ios") -> BackendChoice {
        BackendOverrideRules.chooseBackend(clients: clients, build: build(version, platform: platform))
    }

    // MARK: - Behavior 1

    func testTheOverrideWithTheHighestFromAtOrBelowTheVersionWins() {
        let clients = policy(#"""
        [{"from":"2.0","appId":"app-two"},
         {"from":"3.0","appId":"app-three","future":"ignored"},
         {"from":"2.5","appId":""},
         {"from":"3.5","appId":"app-three-five","apiUrl":"https://b.example.com:8443/base/"}]
        """#)
        let two = BackendChoice(appId: "app-two", apiUrl: Self.buildApiUrl, wsUrl: Self.buildWsUrl, overridden: true)
        let three = BackendChoice(appId: "app-three", apiUrl: Self.buildApiUrl, wsUrl: Self.buildWsUrl, overridden: true)
        let threeFive = BackendChoice(
            appId: "app-three-five", apiUrl: "https://b.example.com:8443/base",
            wsUrl: "wss://b.example.com:8443/base", overridden: true
        )
        let table: [(String, BackendChoice)] = [
            ("1.9.9", homeChoice), ("1", homeChoice), ("2", two), ("2.0.0", two), ("2.4", two),
            ("2.9.999999", two), ("3", three), ("3.4", three), ("3.5.0", threeFive), ("10", threeFive),
        ]
        for (version, expected) in table {
            XCTAssertEqual(choose(clients, version), expected, version)
        }
        XCTAssertEqual(choose(policy(#"[{"from":"2.0.0","appId":"b"}]"#), "2").appId, "b")
        XCTAssertEqual(choose(policy(#"[{"from":"1.10","appId":"b"}]"#), "1.9").appId, Self.home)
    }

    // MARK: - Behavior 2

    func testAnOverrideWithoutApiUrlKeepsTheBuildURLsExactlyAsGiven() {
        XCTAssertEqual(
            choose(policy(#"[{"from":"1","appId":"b"}]"#), "1"),
            BackendChoice(appId: "b", apiUrl: Self.buildApiUrl, wsUrl: Self.buildWsUrl, overridden: true)
        )
    }

    func testAnApiUrlAnswersAsWrittenWithoutTrailingSlashesAndADerivedSocketURL() {
        let cases: [(String, String, String)] = [
            ("https://b.example.com", "https://b.example.com", "wss://b.example.com"),
            ("https://b.example.com/", "https://b.example.com", "wss://b.example.com"),
            ("https://b.example.com:8443/api/v1//", "https://b.example.com:8443/api/v1", "wss://b.example.com:8443/api/v1"),
            ("http://127.0.0.1:9123/", "http://127.0.0.1:9123", "ws://127.0.0.1:9123"),
            ("http://localhost:8080/x", "http://localhost:8080/x", "ws://localhost:8080/x"),
            ("http://localhost/", "http://localhost", "ws://localhost"),
            ("http://[::1]:7000/", "http://[::1]:7000", "ws://[::1]:7000"),
        ]
        for (apiUrl, expectedApi, expectedWs) in cases {
            XCTAssertEqual(
                choose(policy(#"[{"from":"1","appId":"b","apiUrl":"\#(apiUrl)"}]"#), "1"),
                BackendChoice(appId: "b", apiUrl: expectedApi, wsUrl: expectedWs, overridden: true),
                apiUrl
            )
        }
    }

    /// Edge case: an `apiUrl` equal to the build's still derives the socket URL.
    func testAnApiUrlEqualToTheBuildsStillDerivesTheSocketURL() {
        XCTAssertEqual(
            choose(policy(#"[{"from":"1","appId":"b","apiUrl":"https://home.example.com/"}]"#), "1"),
            BackendChoice(appId: "b", apiUrl: "https://home.example.com", wsUrl: "wss://home.example.com", overridden: true)
        )
    }

    // MARK: - Behavior 3

    private static let malformed: [(String, String)] = [
        ("a string", #""app-m""#),
        ("a number", "5"),
        ("null", "null"),
        ("a list", #"["2.0","app-m"]"#),
        ("from missing", #"{"appId":"app-m"}"#),
        ("from not a version", #"{"from":"two","appId":"app-m"}"#),
        ("from a number", #"{"from":2,"appId":"app-m"}"#),
        ("from with four parts", #"{"from":"2.0.0.0","appId":"app-m"}"#),
        ("appId missing", #"{"from":"2.0"}"#),
        ("appId a number", #"{"from":"2.0","appId":7}"#),
        ("appId empty", #"{"from":"2.0","appId":""}"#),
        ("appId of 129 characters", #"{"from":"2.0","appId":"\#(String(repeating: "a", count: 129))"}"#),
        ("appId the build's own", #"{"from":"2.0","appId":"home-app"}"#),
        ("appId the build's own with an apiUrl", #"{"from":"2.0","appId":"home-app","apiUrl":"https://elsewhere.example.com"}"#),
        ("apiUrl a number", #"{"from":"2.0","appId":"app-m","apiUrl":5}"#),
        ("apiUrl null", #"{"from":"2.0","appId":"app-m","apiUrl":null}"#),
        ("apiUrl empty", #"{"from":"2.0","appId":"app-m","apiUrl":""}"#),
        ("apiUrl too long", #"{"from":"2.0","appId":"app-m","apiUrl":"https://b.example.com/\#(String(repeating: "p", count: 2030))"}"#),
        ("apiUrl not a URL", #"{"from":"2.0","appId":"app-m","apiUrl":"b.example.com"}"#),
        ("apiUrl with user info", #"{"from":"2.0","appId":"app-m","apiUrl":"https://u:p@b.example.com"}"#),
        ("apiUrl with a user name", #"{"from":"2.0","appId":"app-m","apiUrl":"https://u@b.example.com"}"#),
        ("apiUrl with a query", #"{"from":"2.0","appId":"app-m","apiUrl":"https://b.example.com/?a=1"}"#),
        ("apiUrl with a bare ?", #"{"from":"2.0","appId":"app-m","apiUrl":"https://b.example.com/?"}"#),
        ("apiUrl with a fragment", #"{"from":"2.0","appId":"app-m","apiUrl":"https://b.example.com/#top"}"#),
        ("apiUrl over ftp", #"{"from":"2.0","appId":"app-m","apiUrl":"ftp://b.example.com"}"#),
        ("apiUrl over wss", #"{"from":"2.0","appId":"app-m","apiUrl":"wss://b.example.com"}"#),
        ("apiUrl over http to another host", #"{"from":"2.0","appId":"app-m","apiUrl":"http://b.example.com"}"#),
        ("apiUrl over http to a private address", #"{"from":"2.0","appId":"app-m","apiUrl":"http://10.0.0.1"}"#),
        ("a bad from with an unknown key", #"{"from":"two","appId":"app-m","future":true}"#),
        ("a bad appId with an unknown key", #"{"from":"2.0","appId":"","future":true}"#),
        ("a bad apiUrl with an unknown key", #"{"from":"2.0","appId":"app-m","apiUrl":"ftp://b.example.com","future":true}"#),
    ]

    func testEachMalformedOverrideIsSkippedWhileItsNeighboursStillApply() {
        let g1 = #"{"from":"1.0","appId":"good-one"}"#
        let g5 = #"{"from":"5.0","appId":"good-five"}"#
        for (what, item) in Self.malformed {
            let clients = policy("[\(g1),\(item),\(g5)]")
            XCTAssertEqual(choose(clients, "4.0").appId, "good-one", what)
            XCTAssertEqual(choose(clients, "5.0").appId, "good-five", what)
            XCTAssertEqual(choose(policy("[\(item)]"), "9.0"), homeChoice, what)
        }
    }

    func testAnUnknownKeyOnAnOverrideOrThePlatformTableIsIgnored() {
        let clients = policy(
            #"[{"from":"2.0","appId":"app-b","future":true}]"#,
            extra: #""latest":"3.0","future":{"anything":1}"#
        )
        XCTAssertEqual(choose(clients, "2.0").appId, "app-b")
    }

    // MARK: - Behavior 4

    func testOnlyTheFirstSixteenOverridesAreRead() {
        let list = (1...17).map { #"{"from":"\#($0)","appId":"app-\#($0)"}"# }.joined(separator: ",")
        for version in ["16", "17", "99"] {
            XCTAssertEqual(choose(policy("[\(list)]"), version).appId, "app-16", version)
        }
    }

    func testTheLaterOfTwoUsableOverridesWithEqualFromIsSkipped() {
        let clients = policy(#"[{"from":"2.0","appId":"first"},{"from":"2","appId":"second"}]"#)
        XCTAssertEqual(choose(clients, "2.0.0").appId, "first")
        XCTAssertEqual(choose(clients, "3").appId, "first")
        // A malformed override does not count as the first of two.
        let afterBad = policy(#"[{"from":"2.0","appId":""},{"from":"2","appId":"second"}]"#)
        XCTAssertEqual(choose(afterBad, "2").appId, "second")
    }

    func testAPolicyPlatformTableOrListThatCannotBeReadAnswersTheBuildsValues() {
        for list in [#""2.0""#, "2", #"{"from":"1","appId":"b"}"#, "null"] {
            XCTAssertEqual(choose(policy(list), "9"), homeChoice, list)
        }
        for clients in ["null", #""x""#, "5", "[]", #"{"ios":null}"#, #"{"ios":"x"}"#, #"{"ios":[]}"#,
                        #"{"android":{"backendOverrides":[{"from":"1","appId":"b"}]}}"#] {
            XCTAssertEqual(choose(json(clients), "9"), homeChoice, clients)
        }
        XCTAssertEqual(choose(nil, "9"), homeChoice)
    }

    // MARK: - Behavior 13 (the shared fixture)

    private struct CanonicalCase: Decodable {
        struct Answer: Decodable { let apiUrl: String; let wsUrl: String }
        let name: String
        let apiUrl: String
        let answer: Answer
    }

    private struct Fixture: Decodable {
        struct Build: Decodable { let appId: String; let apiUrl: String; let wsUrl: String }
        let build: Build
        let canonical: [CanonicalCase]
    }

    /// Every canonical URL push accepts answers the `apiUrl` and `wsUrl` the
    /// JS resolver answers (the vitest fixture test holds the same file to
    /// the server and to JS). No case is excepted.
    func testEveryCanonicalFixtureURLAnswersTheRecordedApiUrlAndWsUrl() throws {
        let url = ClientSourceText.packageRoot
            .appendingPathComponent("Tests/JsBaoClientTests/Fixtures/BackendOverrides/cases.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(fixture.canonical.count, 15)
        let at = BackendBuild(
            appId: fixture.build.appId, apiUrl: fixture.build.apiUrl, wsUrl: fixture.build.wsUrl,
            version: "2.0", platform: "p"
        )
        for c in fixture.canonical {
            let override: JSONValue = .object(["from": .string("2.0"), "appId": .string("b"), "apiUrl": .string(c.apiUrl)])
            let clients: JSONValue = .object(["p": .object(["backendOverrides": .array([override])])])
            let answer = BackendOverrideRules.chooseBackend(clients: clients, build: at)
            XCTAssertTrue(answer.overridden, c.name)
            XCTAssertEqual(answer.apiUrl, c.answer.apiUrl, c.name)
            XCTAssertEqual(answer.wsUrl, c.answer.wsUrl, c.name)
        }
    }

    func testHttpIsAcceptedOnlyOnTheLoopbackHosts() {
        for apiUrl in ["http://localhost:1", "http://127.0.0.1:1", "http://[::1]:1"] {
            XCTAssertTrue(choose(policy(#"[{"from":"1","appId":"b","apiUrl":"\#(apiUrl)"}]"#), "1").overridden, apiUrl)
        }
        for apiUrl in ["http://example.com", "http://127.0.0.2", "http://10.0.0.1", "http://[::2]", "http://localhost.example.com"] {
            XCTAssertFalse(choose(policy(#"[{"from":"1","appId":"b","apiUrl":"\#(apiUrl)"}]"#), "1").overridden, apiUrl)
        }
    }

    // MARK: - Edge cases

    // MARK: - Behavior 46

    /// A policy stored before the push rule may hold an `apiUrl` push now
    /// refuses. One with a character outside the plain set, or a host with an
    /// upper-case letter or `%`, is skipped and its neighbour still applies;
    /// one that is only missing its root slash is used as written.
    func testAValueStoredBeforeThePushRuleIsSkippedOutsideThePlainSet() {
        let g1 = #"{"from":"1.0","appId":"good-one"}"#
        for apiUrl in [
            "https://ẞ.de/",
            " https://b.example.com/",
            #"https:\\b.example.com/"#,
            "https://a.example/a|b",
            "HTTPS://b.example.com/",
            "https://B.example.com/",
            "https://%62.example.com/",
        ] {
            let item = #"{"from":"2.0","appId":"legacy","apiUrl":"\#(apiUrl)"}"#
            XCTAssertEqual(choose(policy("[\(g1),\(item)]"), "2.0").appId, "good-one", apiUrl)
            XCTAssertEqual(choose(policy("[\(item)]"), "2.0"), homeChoice, apiUrl)
        }
        XCTAssertEqual(
            choose(policy(#"[{"from":"2.0","appId":"legacy","apiUrl":"https://b.example.com"}]"#), "2.0"),
            BackendChoice(appId: "legacy", apiUrl: "https://b.example.com", wsUrl: "wss://b.example.com", overridden: true)
        )
    }

    // MARK: - Behavior 14

    /// The resolver reads `apiUrl` with Foundation; no URL parser port, ICU
    /// call or dynamic library load is left in the client's code.
    func testTheClientCarriesNoURLParserPort() throws {
        for source in try ClientSourceText.allClientSources() {
            let code = ClientSourceText.stripComments(source)
            for identifier in ["SpecialURL", "dlopen", "uidna_", "Punycode"] {
                XCTAssertFalse(code.contains(identifier), identifier)
            }
        }
    }

    func testLengthLimitsCountUTF16Units() {
        func appId(_ count: Int) -> String { String(repeating: "é", count: count) }
        XCTAssertTrue(choose(policy(#"[{"from":"1","appId":"\#(appId(128))"}]"#), "1").overridden)
        XCTAssertFalse(choose(policy(#"[{"from":"1","appId":"\#(appId(129))"}]"#), "1").overridden)
        // An astral character is two UTF-16 units, as the server's `.length` counts it.
        XCTAssertTrue(choose(policy(#"[{"from":"1","appId":"\#(String(repeating: "😀", count: 64))"}]"#), "1").overridden)
        XCTAssertFalse(choose(policy(#"[{"from":"1","appId":"a\#(String(repeating: "😀", count: 64))"}]"#), "1").overridden)

        let prefix = "https://b.example.com/"
        func apiUrl(_ count: Int) -> String { prefix + String(repeating: "p", count: count - prefix.utf16.count) }
        XCTAssertTrue(choose(policy(#"[{"from":"1","appId":"b","apiUrl":"\#(apiUrl(2048))"}]"#), "1").overridden)
        XCTAssertFalse(choose(policy(#"[{"from":"1","appId":"b","apiUrl":"\#(apiUrl(2049))"}]"#), "1").overridden)
    }
}
