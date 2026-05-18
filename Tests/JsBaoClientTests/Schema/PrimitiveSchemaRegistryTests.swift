import XCTest
@testable import JsBaoClient

/// Tests the function-default registry that backs `$name`-style defaults
/// (e.g. `"$generate_ulid"`). Mirrors js-bao's `KNOWN_FUNCTION_DEFAULTS`.
///
/// Contract:
///  - `generate_ulid` is registered by default; `.resolve` returns a
///    generator that produces a valid 26-char ULID.
///  - Unknown names resolve to `nil` rather than throwing. "No default
///    applied" is a legal wire state — a Swift client encountering a
///    `$foo_custom` it doesn't know about must not crash.
///  - Custom names can be registered and resolved.
final class PrimitiveSchemaRegistryTests: XCTestCase {

    func testGenerateUlidIsRegisteredByDefault() throws {
        let gen = PrimitiveSchemaRegistry.shared.resolve("generate_ulid")
        XCTAssertNotNil(gen, "generate_ulid must be registered out of the box")
        if case let .id(ulid) = gen!() {
            XCTAssertEqual(ulid.count, 26, "ULID must be 26 chars")
        } else {
            XCTFail("generate_ulid generator should return a .id PrimitiveValue")
        }
    }

    func testGeneratedUlidsAreUnique() throws {
        let gen = PrimitiveSchemaRegistry.shared.resolve("generate_ulid")!
        let a = gen().asId
        let b = gen().asId
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b, "Two ULIDs generated back-to-back must differ")
    }

    func testUnknownNameResolvesToNil() throws {
        XCTAssertNil(PrimitiveSchemaRegistry.shared.resolve("unknown_function"))
        XCTAssertNil(PrimitiveSchemaRegistry.shared.resolve("$unknown_function"))
    }

    func testRegisteredCustomNameIsResolvable() throws {
        // Use a unique name so parallel test runs don't collide
        let name = "test_fixed_\(UUID().uuidString)"
        PrimitiveSchemaRegistry.shared.register(name: name) {
            .string("fixed-value")
        }
        let gen = PrimitiveSchemaRegistry.shared.resolve(name)
        XCTAssertEqual(gen?(), .string("fixed-value"))
    }

    /// The registry should accept a name with a leading `$` prefix (the
    /// form that appears in `_meta_*`) and strip it transparently.
    func testResolveAcceptsDollarPrefix() throws {
        let gen = PrimitiveSchemaRegistry.shared.resolve("$generate_ulid")
        XCTAssertNotNil(gen)
    }

    /// Registering the same name twice replaces the previous generator —
    /// useful for tests overriding a default.
    func testRegisterReplacesExisting() throws {
        let name = "test_replace_\(UUID().uuidString)"
        PrimitiveSchemaRegistry.shared.register(name: name) { .string("first") }
        PrimitiveSchemaRegistry.shared.register(name: name) { .string("second") }
        XCTAssertEqual(
            PrimitiveSchemaRegistry.shared.resolve(name)?(),
            .string("second")
        )
    }
}
