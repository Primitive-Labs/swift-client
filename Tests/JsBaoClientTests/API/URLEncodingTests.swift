import XCTest
@testable import JsBaoClient

/// Unit tests for the centralized URL value-escaper and query builder
/// (`URLEncoding.encodeComponent` / `URLQuery`), the fix for #2076.
///
/// The old sub-API sites escaped with `.urlQueryAllowed` / `.urlPathAllowed`,
/// component-level charsets that leave value-separating characters (`+ & = /`
/// `; : @` space) unescaped. These tests pin `encodeURIComponent` parity: the
/// unreserved set survives byte-for-byte, everything else is percent-encoded —
/// the same bytes the JS client's `URLSearchParams` puts on the wire.
final class URLEncodingTests: XCTestCase {

    // MARK: - encodeComponent: byte-identical for safe values

    /// A slug (lowercase letters, no reserved chars) is unchanged — the common
    /// path segment / group type / query filter case.
    func test_slug_isByteIdentical() {
        XCTAssertEqual(URLEncoding.encodeComponent("editors"), "editors")
    }

    /// A ULID (uppercase + digits) is unchanged — the common id case.
    func test_ulid_isByteIdentical() {
        XCTAssertEqual(
            URLEncoding.encodeComponent("01ARZ3NDEKTSV4RRFFQ69G5FAV"),
            "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        )
    }

    /// The unreserved marks `encodeURIComponent` keeps literal all survive.
    func test_unreservedMarks_areByteIdentical() {
        XCTAssertEqual(URLEncoding.encodeComponent("-_.!~*'()"), "-_.!~*'()")
    }

    // MARK: - encodeComponent: reserved characters are escaped

    /// The live bug (#2076): a plus-addressed email. `.urlQueryAllowed` left
    /// `+` and `@` literal (`+` decodes to a space server-side, resolving the
    /// wrong user). `encodeURIComponent` escapes both.
    func test_plusAddressedEmail_escapesPlusAndAt() {
        XCTAssertEqual(
            URLEncoding.encodeComponent("a+b@x.com"),
            "a%2Bb%40x.com"
        )
    }

    /// The value-separating characters that the component charsets let through.
    func test_separatorCharacters_areEscaped() {
        XCTAssertEqual(URLEncoding.encodeComponent("a+b"), "a%2Bb")   // was literal under .urlQueryAllowed
        XCTAssertEqual(URLEncoding.encodeComponent("a&b"), "a%26b")
        XCTAssertEqual(URLEncoding.encodeComponent("a=b"), "a%3Db")
        XCTAssertEqual(URLEncoding.encodeComponent("a b"), "a%20b")   // space, not "+"
        XCTAssertEqual(URLEncoding.encodeComponent("a/b"), "a%2Fb")   // was literal under .urlPathAllowed
        XCTAssertEqual(URLEncoding.encodeComponent("a:b"), "a%3Ab")
        XCTAssertEqual(URLEncoding.encodeComponent("a;b"), "a%3Bb")
        XCTAssertEqual(URLEncoding.encodeComponent("a#b"), "a%23b")
        XCTAssertEqual(URLEncoding.encodeComponent("a?b"), "a%3Fb")
    }

    /// An ordinary email now escapes `@` to `%40`, matching the JS client's
    /// `URLSearchParams` output (both decode to the same value server-side).
    func test_ordinaryEmail_escapesAt() {
        XCTAssertEqual(
            URLEncoding.encodeComponent("user@example.com"),
            "user%40example.com"
        )
    }

    /// Non-ASCII is percent-encoded as UTF-8, not left literal — matching
    /// `encodeURIComponent` (and unlike `CharacterSet.alphanumerics`, which is
    /// Unicode-aware).
    func test_nonAscii_isUtf8PercentEncoded() {
        XCTAssertEqual(URLEncoding.encodeComponent("café"), "caf%C3%A9")
    }

    // MARK: - URLQuery

    func test_query_empty_producesEmptyString() {
        let q = URLQuery()
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(q.queryString, "")
    }

    func test_query_singleParam_hasLeadingQuestionMark() {
        var q = URLQuery()
        q.append("cursor", "abc")
        XCTAssertEqual(q.queryString, "?cursor=abc")
    }

    func test_query_preservesInsertionOrder() {
        var q = URLQuery()
        q.append("type", "editors")
        q.append("limit", 25)
        q.append("cursor", "abc")
        XCTAssertEqual(q.queryString, "?type=editors&limit=25&cursor=abc")
    }

    func test_query_encodesValues() {
        var q = URLQuery()
        q.append("email", "a+b@x.com")
        XCTAssertEqual(q.queryString, "?email=a%2Bb%40x.com")
    }

    func test_query_appendIfPresent_skipsNil() {
        var q = URLQuery()
        q.appendIfPresent("cursor", nil)
        q.appendIfPresent("tag", "urgent")
        XCTAssertEqual(q.queryString, "?tag=urgent")
    }

    func test_query_integerValue() {
        var q = URLQuery()
        q.append("limit", 50)
        XCTAssertEqual(q.queryString, "?limit=50")
    }
}
