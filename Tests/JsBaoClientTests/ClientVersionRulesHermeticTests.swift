import XCTest
@testable import JsBaoClient

/// The client version rules: what a version and a platform name are, how two
/// versions compare, which version and platform a client reports, and the
/// status one policy gives a client. Pure functions, tested directly; the
/// precondition that stops `JsBaoClient.init` on a refusal is not exercised.
final class ClientVersionRulesHermeticTests: XCTestCase {

    private typealias Rules = ClientVersionRules

    private func resolve(
        optionVersion: String? = nil,
        optionPlatform: String? = nil,
        bundleVersion: Any? = nil,
        osPlatform: String = "ios"
    ) -> ClientIdentityResolution {
        Rules.resolveClientIdentity(
            optionVersion: optionVersion,
            optionPlatform: optionPlatform,
            bundleVersion: bundleVersion,
            osPlatform: osPlatform
        )
    }

    // MARK: - Behavior 1: identity from the bundle and the OS, options replace

    func testNoOptionsReportTheBundleVersionAndTheOSPlatform() {
        let resolved = resolve(bundleVersion: "2.4.1", osPlatform: "ios")
        XCTAssertNil(resolved.refusal)
        XCTAssertEqual(resolved.identity, ClientIdentity(version: "2.4.1", platform: "ios"))

        let mac = resolve(bundleVersion: "3.0", osPlatform: "macos")
        XCTAssertEqual(mac.identity, ClientIdentity(version: "3.0", platform: "macos"))
    }

    func testTheOSDefaultIsIosOrMacos() {
        #if os(iOS)
        XCTAssertEqual(Rules.osPlatform, "ios")
        #elseif os(macOS)
        XCTAssertEqual(Rules.osPlatform, "macos")
        #endif
        XCTAssertTrue(Rules.isLegalPlatformName(Rules.osPlatform))
    }

    func testAnOptionReplacesTheCorrespondingValue() {
        let version = resolve(optionVersion: "5.1", bundleVersion: "2.4.1", osPlatform: "ios")
        XCTAssertEqual(version.identity, ClientIdentity(version: "5.1", platform: "ios"))

        let platform = resolve(optionPlatform: "ipados", bundleVersion: "2.4.1", osPlatform: "ios")
        XCTAssertEqual(platform.identity, ClientIdentity(version: "2.4.1", platform: "ipados"))

        let both = resolve(optionVersion: "7", optionPlatform: "kiosk", bundleVersion: "2.4.1")
        XCTAssertEqual(both.identity, ClientIdentity(version: "7", platform: "kiosk"))
    }

    // MARK: - Behavior 2: refusals name the value, its source and the fix

    private static let illegalVersions: [String] = [
        "1.2.3.4", "1.0-beta", "v1", "1..2", "1234567", "1.\u{0663}", "", "   ",
    ]

    func testAnIllegalOptionVersionIsRefusedNamingTheValueSourceAndFix() throws {
        for value in Self.illegalVersions {
            let refusal = try XCTUnwrap(resolve(optionVersion: value, bundleVersion: "1.0").refusal, "row \(value)")
            XCTAssertTrue(refusal.contains("\"\(value)\""), "names the value: \(refusal)")
            XCTAssertTrue(refusal.contains("appVersion option"), "names the source: \(refusal)")
            XCTAssertTrue(refusal.contains("pass a legal version as appVersion:"), "names the fix: \(refusal)")
        }
    }

    func testAnIllegalBundleVersionIsRefusedNamingTheValueSourceAndFix() throws {
        for value in Self.illegalVersions {
            let refusal = try XCTUnwrap(resolve(bundleVersion: value).refusal, "row \(value)")
            XCTAssertTrue(refusal.contains("\"\(value)\""), "names the value: \(refusal)")
            XCTAssertTrue(refusal.contains("CFBundleShortVersionString"), "names the source: \(refusal)")
            XCTAssertTrue(refusal.contains("MARKETING_VERSION"), "names the fix: \(refusal)")
            XCTAssertTrue(refusal.contains("appVersion:"), "names the other fix: \(refusal)")
        }
    }

    func testAnEmptyValueIsShownAsTwoQuotes() throws {
        let bundle = try XCTUnwrap(resolve(bundleVersion: "").refusal)
        XCTAssertTrue(bundle.contains("\"\""), bundle)
        let option = try XCTUnwrap(resolve(optionVersion: "", bundleVersion: "1.0").refusal)
        XCTAssertTrue(option.contains("\"\""), option)
    }

    func testAnIllegalOptionPlatformIsRefusedNamingTheValueSourceAndFix() throws {
        for value in ["iOS", "-ios", String(repeating: "a", count: 33), "", "  ", "ios\u{0663}", "1ios", "i_os"] {
            let refusal = try XCTUnwrap(resolve(optionPlatform: value, bundleVersion: "1.0").refusal, "row \(value)")
            XCTAssertTrue(refusal.contains("\"\(value)\""), "names the value: \(refusal)")
            XCTAssertTrue(refusal.contains("platform option"), "names the source: \(refusal)")
            XCTAssertTrue(refusal.contains("pass a legal name as platform:"), "names the fix: \(refusal)")
        }
    }

    func testPlatformNamesFollowTheServerPattern() {
        XCTAssertTrue(Rules.isLegalPlatformName("ios"))
        XCTAssertTrue(Rules.isLegalPlatformName("a"))
        XCTAssertTrue(Rules.isLegalPlatformName("apple-tv2"))
        XCTAssertTrue(Rules.isLegalPlatformName("a" + String(repeating: "b", count: 31)))
        XCTAssertFalse(Rules.isLegalPlatformName("a" + String(repeating: "b", count: 32)))
        XCTAssertFalse(Rules.isLegalPlatformName("ÿos"))
    }

    // MARK: - Behavior 3: an appVersion option skips the bundle check

    func testWithAnAppVersionOptionAnIllegalBundleVersionIsNotRefused() {
        for bundle: Any in ["1.0-beta", "", "   ", 42] {
            let resolved = resolve(optionVersion: "1.2", bundleVersion: bundle)
            XCTAssertNil(resolved.refusal, "bundle \(bundle)")
            XCTAssertEqual(resolved.identity.version, "1.2")
        }
    }

    // MARK: - Behavior 4: a missing key is no version; a present illegal one is refused

    func testABundleWithNoVersionKeyResolvesToNoVersionAndNoRefusal() {
        let resolved = resolve(bundleVersion: nil, osPlatform: "macos")
        XCTAssertNil(resolved.refusal)
        XCTAssertEqual(resolved.identity, ClientIdentity(version: nil, platform: "macos"))
    }

    func testAPresentEmptyOrNonStringBundleVersionIsRefused() throws {
        XCTAssertNotNil(resolve(bundleVersion: "").refusal)
        let number = try XCTUnwrap(resolve(bundleVersion: 3).refusal)
        XCTAssertTrue(number.contains("\"3\""), number)
        XCTAssertNotNil(resolve(bundleVersion: ["1.0"]).refusal)
    }

    // MARK: - Behavior 38: the bundle under `swift test` (measurement)

    func testBundleMainUnderSwiftTestCarriesNoVersionOrALegalOne() {
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
        print("[#6036 measurement] Bundle.main=\(Bundle.main.bundlePath) CFBundleShortVersionString=\(raw.map { "\($0)" } ?? "<absent>")")
        let resolved = resolve(bundleVersion: raw, osPlatform: Rules.osPlatform)
        XCTAssertNil(resolved.refusal, "intent assumption 3: \(resolved.refusal ?? "")")
    }

    // MARK: - Behavior 7: numeric comparison, missing parts zero

    func testVersionsCompareNumericallyWithMissingPartsZero() {
        XCTAssertEqual(Rules.compareClientVersions("1.2", "1.2.0"), 0)
        XCTAssertEqual(Rules.compareClientVersions("1.10", "1.9"), 1)
        XCTAssertEqual(Rules.compareClientVersions("1.9", "1.10"), -1)
        XCTAssertEqual(Rules.compareClientVersions("01.2", "1.2"), 0)
        XCTAssertEqual(Rules.compareClientVersions("2", "1.999999.999999"), 1)
        XCTAssertNil(Rules.compareClientVersions("1.x", "1.2"))
        XCTAssertEqual(Rules.parseClientVersion("1.2"), [1, 2, 0])
        XCTAssertEqual(Rules.parseClientVersion("000001"), [1, 0, 0])
        XCTAssertNil(Rules.parseClientVersion("1.2.3.4"))
        XCTAssertNil(Rules.parseClientVersion(" 1.2"))
    }

    // MARK: - Behavior 6: one status per row of one policy

    private static let policy = ClientVersionPolicyRecord(clients: [
        "ios": ClientPlatformVersions(latest: "3.0", minRecommended: "2.5", minRequired: "2.0", updateUrl: "itms-apps://x"),
        "web": ClientPlatformVersions(updateUrl: "https://example.com"),
    ])

    func testEachRowOfOnePolicyGetsItsStatus() {
        let rows: [(String?, String?, ClientVersionPolicyRecord?, AppVersionStatus, String)] = [
            ("1.9.9", "ios", Self.policy, .updateRequired, "below minRequired"),
            ("2.0", "ios", Self.policy, .updateRecommended, "at minRequired, below minRecommended"),
            ("2.4", "ios", Self.policy, .updateRecommended, "between minRequired and minRecommended"),
            ("2.5", "ios", Self.policy, .updateAvailable, "at minRecommended"),
            ("2.9", "ios", Self.policy, .updateAvailable, "between minRecommended and latest"),
            ("3.0", "ios", Self.policy, .current, "equal to latest"),
            ("3.0.0", "ios", Self.policy, .current, "equal to latest, written longer"),
            ("4.1", "ios", Self.policy, .current, "above latest"),
            (nil, "ios", Self.policy, .unknown, "no version"),
            ("1.0", nil, Self.policy, .unknown, "no platform"),
            ("1.0", "ios", nil, .unknown, "no policy"),
            ("1.0", "android", Self.policy, .unknown, "no table for the platform"),
            ("1.0", "web", Self.policy, .current, "a table with only updateUrl"),
        ]
        for (version, platform, policy, expected, label) in rows {
            XCTAssertEqual(
                Rules.clientVersionStatus(version: version, platform: platform, policy: policy),
                expected, label
            )
        }
    }

    // MARK: - Edge: a policy value that does not parse is read as unset

    func testAMinRequiredThatDoesNotParseIsUnsetAndTheOtherKeysApply() {
        let policy = ClientVersionPolicyRecord(clients: [
            "ios": ClientPlatformVersions(latest: "3.0", minRecommended: "2.5", minRequired: "two"),
        ])
        XCTAssertEqual(Rules.clientVersionStatus(version: "1.0", platform: "ios", policy: policy), .updateRecommended)
        XCTAssertEqual(Rules.clientVersionStatus(version: "2.7", platform: "ios", policy: policy), .updateAvailable)
    }

    // MARK: - Edge: a body with no usable `clients` map is an empty policy

    func testABodyWithNoClientsMapReadsAsAnEmptyPolicy() throws {
        for body in [#"{}"#, #"{"clients":[]}"#, #"{"clients":"ios"}"#, #"{"clients":null}"#] {
            let record = try XCTUnwrap(ClientVersionPolicyRecord.decode(from: Data(body.utf8)), body)
            XCTAssertEqual(record, ClientVersionPolicyRecord(clients: [:]), body)
            XCTAssertEqual(Rules.clientVersionStatus(version: "1.0", platform: "ios", policy: record), .unknown, body)
        }
        XCTAssertNil(ClientVersionPolicyRecord.decode(from: Data("not json".utf8)))
        XCTAssertNil(ClientVersionPolicyRecord.decode(from: Data("[1]".utf8)))
    }

    func testABodyIsReadKeyByKey() throws {
        let body = #"{"clients":{"ios":{"latest":"3.0","minRequired":2,"updateUrl":"itms-apps://x","enforce":true,"extra":1},"web":"x"}}"#
        let record = try XCTUnwrap(ClientVersionPolicyRecord.decode(from: Data(body.utf8)))
        XCTAssertEqual(record.clients["ios"], ClientPlatformVersions(
            latest: "3.0", minRecommended: nil, minRequired: nil, updateUrl: "itms-apps://x", enforce: true
        ))
        XCTAssertNil(record.clients["web"])
    }
}
