import XCTest
import JsBaoClient

/// 4942-C001 — a model named `Db3WriteOptions` does not break its generated file.
///
/// A schema may name a model `Db3WriteOptions` (`class_name`, or a model
/// `db3_write_options`); its generated struct is a type in the app's module
/// and shadows the client's options type there. The generated db3 writes
/// therefore spell the options type `JsBaoClient.Db3WriteOptions`
/// (`SwiftEmitterDb3WritesHermeticTests` pins the emitted text). `AppModule`
/// below stands in for that module: its own `Db3WriteOptions` shadows the
/// client's, and the generated members' parameter spelling, copied verbatim,
/// still names the client's type. The plain `import` is an app's: the alias is
/// public.
private enum AppModule {
    /// The generated model a schema naming `Db3WriteOptions` produces.
    struct Db3WriteOptions: Equatable {
        var views: Double?
    }

    static func save(in documentId: String, options: JsBaoClient.Db3WriteOptions) -> JsBaoClient.Db3WriteOptions {
        options
    }

    static func increment(
        id: String, fields: [String: Double], in documentId: String,
        options: JsBaoClient.Db3WriteOptions = JsBaoClient.Db3WriteOptions()
    ) -> JsBaoClient.Db3WriteOptions {
        options
    }

    static func model() -> Db3WriteOptions {
        Db3WriteOptions(views: 2)
    }
}

final class Db3WriteOptionsShadowHermeticTests: XCTestCase {
    func testTheQualifiedNameIsTheClientsOptionsType() {
        XCTAssertTrue(JsBaoClient.Db3WriteOptions.self == Db3WriteOptions.self)
        XCTAssertTrue(CodegenAPI.WriteOptions.self == Db3WriteOptions.self)
    }

    func testTheGeneratedSpellingReachesTheClientsTypeWhereAModelShadowsIt() {
        // Outside the shadowing scope, an app passes the client's type as it always has.
        let passed = AppModule.save(
            in: "db3", options: Db3WriteOptions(condition: ["category": "open"], ifNotExists: true, confirm: true)
        )
        XCTAssertNotNil(passed.condition)
        XCTAssertTrue(passed.ifNotExists)
        XCTAssertTrue(passed.confirm)

        let defaulted = AppModule.increment(id: "r1", fields: ["views": 1], in: "db3")
        XCTAssertNil(defaulted.condition)
        XCTAssertFalse(defaulted.ifNotExists)
        XCTAssertFalse(defaulted.confirm)

        // The shadowing model is still the app's own type under its own name.
        XCTAssertEqual(AppModule.model(), AppModule.Db3WriteOptions(views: 2))
    }
}
