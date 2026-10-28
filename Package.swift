// swift-tools-version: 6.1
//
// 6.1, not 6.0 (#2966): the tools version is what PackagePlugin gates its API
// on, and `Target.directoryURL` — the only non-deprecated way for
// `JsBaoCodegenPlugin` to read the consuming target's source directory —
// arrived in PackageDescription 6.1. At 6.0 the plugin had to go through
// `target.directory.string`, and SwiftPM compiles the plugin inside every
// package that uses it, so that deprecation warning printed on every consumer
// build. The floor this imposes on consumers is a Swift 6.1 toolchain
// (Xcode 16.3); `docs/README.md` documents it and
// `PluginDeprecationHermeticTests` keeps the two in step.
import PackageDescription

let package = Package(
    name: "JsBaoClient",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "JsBaoClient",
            targets: ["JsBaoClient"]
        ),
        // The SQLite every connection in this package opens (#4700): the
        // release sqlite-wasm carries for the JS client, built from source, so
        // the store answers the same SQL on every OS it runs on. A product so
        // a package that reads the client's database file (the debug
        // inspector in PrimitiveApp) opens it with the same library: two
        // SQLite builds on one file in one process do not see each other's
        // locks.
        .library(
            name: "JsBaoSQLite",
            targets: ["JsBaoSQLite"]
        ),
        // Build-time codegen tool that turns a TOML schema (same shape
        // `TomlSchemaLoader` accepts) into one Swift file per model. Use
        // standalone, or via the SwiftPM plugin below to run on every
        // `swift build`.
        //
        // THE PRODUCT NAME AND ITS TARGET NAME MUST MATCH, and there must be
        // exactly ONE executable product for the target (#3560). Swift 6.4 /
        // Xcode 27 made `swiftbuild` SwiftPM's default build system, and it
        // resolves a plugin's tool to a path under `Products/<Config>/` named
        // after the PRODUCT while scheduling the build by TARGET. When the two
        // names differed — the target was `SwiftBaoCodegen`, the product
        // `swift-bao-codegen` — swiftbuild looked for
        // `Products/Debug/swift-bao-codegen` and built nothing under any name,
        // so every cross-package consumer (the template, and so every app
        // scaffolded from it) failed with "Build input file cannot be found".
        //
        // A second `.executable` product aliasing the same target used to sit
        // here so an IN-PACKAGE consumer's `dependencies: ["SwiftBaoCodegen"]`
        // could resolve as a product under the `native` build system. Name
        // identity makes it redundant — the bare string now matches both the
        // target and the product — and its presence is what gave swiftbuild
        // two products for one target. Do not reintroduce it: it fixes
        // nothing on `native` and breaks `swiftbuild`.
        //
        // Upstream hit the same wall and resolved it the same way:
        // swiftlang/swift-java#733, fixed in swiftlang/swift-java#740 by
        // renaming the tool target to match its product.
        .executable(
            name: "swift-bao-codegen",
            targets: ["swift-bao-codegen"]
        ),
        // SwiftPM build tool plugin. Consumers add this to their target
        // and SwiftPM runs `swift-bao-codegen` automatically on every
        // build, with `*schema.toml` files in the target as input.
        .plugin(
            name: "JsBaoCodegenPlugin",
            targets: ["JsBaoCodegenPlugin"]
        ),
    ],
    dependencies: [
        // Local fork of yswift with observe_update_v1 support
        .package(url: "https://github.com/Primitive-Labs/yswift-fork.git", branch: "alpha"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        // The SQLite amalgamation, vendored unmodified beside `Sources/` as
        // `yswift-fork` is (`Vendor/JsBaoSQLite/VERSION` names the release and
        // its SHA3-256). `BundledSQLiteHermeticTests` holds its version to
        // `@sqlite.org/sqlite-wasm`'s in packages/js-bao/package.json.
        //
        // SQLite's options are `.define`s. JSON functions are built in since
        // 3.38; the double-quoted-string default is left as SQLite ships it,
        // as the room's engine has it.
        .target(
            name: "JsBaoSQLite",
            path: "Vendor/JsBaoSQLite",
            exclude: ["VERSION"],
            sources: ["sqlite3.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_OMIT_LOAD_EXTENSION"),
                .define("SQLITE_ENABLE_MATH_FUNCTIONS"),
                .define("SQLITE_OMIT_DEPRECATED"),
                // A debug build compiles C at -O0, which makes SQLite's JSON
                // functions about 2.7 times slower than the OS's optimized
                // build (an unindexed `json_extract` scan of 100,000 rows: 92
                // ms against 34 ms), so an app's debug build would read its
                // store far slower than it ships. Optimized in every
                // configuration instead. `unsafeFlags` bars a dependency
                // resolved by version, and this package has none: apps depend
                // on a branch of the mirror or on a path (CHANGELOG.md, "How
                // this package is versioned"), and SwiftPM allows both.
                .unsafeFlags(["-O2"], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "JsBaoClient",
            dependencies: [
                "JsBaoSQLite",
                .product(name: "YSwift", package: "yswift-fork"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Sources/JsBaoClient",
            // No `swiftSettings:` here any more — the whole package is in the
            // Swift 6 language mode via `swiftLanguageModes: [.v6]` at the
            // bottom of this manifest (#2310). This target carried the only
            // per-target opt-in between #1946 and #2310.
            //
            // `scripts/v6-sendable-gate.sh` is still the regression gate for
            // this target: it builds it, reports any `Sendable` error site per
            // file, counts the warning-level strict-concurrency sites, and
            // asserts a budget when given `--max` / `--max-warnings` /
            // `--require-zero`. `run-tests.sh` runs it that way before the
            // suite. Its first check is that the committed mode is still `.v6`
            // — a silent revert would otherwise read as "zero sites".
        ),
        .executableTarget(
            name: "swift-bao-codegen",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Sources/SwiftBaoCodegen"
        ),
        .plugin(
            name: "JsBaoCodegenPlugin",
            capability: .buildTool(),
            // One bare string that is BOTH the target name and the
            // executable product name (#3560), so the tool dep resolves
            // identically in-package (`E2EMiniApp` below) and
            // cross-package (the template), under `native` and under
            // `swiftbuild`. Native resolves an in-package plugin tool dep
            // as a product; swiftbuild paths it by product and schedules it
            // by target. Only name identity satisfies both — see the
            // product declaration above for what each build system did
            // when the names differed.
            dependencies: ["swift-bao-codegen"],
            path: "Plugins/JsBaoCodegenPlugin"
        ),
        .testTarget(
            name: "JsBaoClientTests",
            dependencies: ["JsBaoClient", "JsBaoSQLite"],
            path: "Tests/JsBaoClientTests",
            // The cross-language E2E mini-app lives under this test
            // target's path tree but compiles as its own executable
            // target (`E2EMiniApp`) — exclude here so SwiftPM
            // doesn't pull the same Swift sources into both target
            // compilations. The session-row fixtures (#3802), the bulk-load
            // chunk fixtures (#4475) and the role-compatibility response
            // fixtures (#4727) are JSON the JS and Swift suites both read by
            // path, not bundle resources.
            exclude: [
                "CrossPlatform/E2E",
                "Fixtures/AgentSessionRows",
                "Fixtures/DocumentIngestChunks",
                "Fixtures/RoleCompatResponses",
            ]
        ),
        .testTarget(
            name: "SwiftBaoCodegenTests",
            dependencies: ["swift-bao-codegen"],
            path: "Tests/SwiftBaoCodegenTests"
        ),
        // Cross-language E2E mini-app: a tiny CLI driven by JSON on
        // stdin/stdout that exercises the codegen + runtime path
        // end-to-end against a shared TOML schema. Spawned as a
        // subprocess by `E2EQueryParityTests`, alongside a sibling
        // JS CLI in the same directory's `js/` subfolder. The
        // codegen plugin runs against `Models/schema.toml` so this
        // target exercises the *real* build-time codegen path —
        // not the test-side committed goldens.
        .executableTarget(
            name: "E2EMiniApp",
            dependencies: ["JsBaoClient"],
            path: "Tests/JsBaoClientTests/CrossPlatform/E2E/swift",
            plugins: [.plugin(name: "JsBaoCodegenPlugin")]
        ),
    ],
    // Package-wide: every target compiles in the Swift 6 language mode, so
    // strict concurrency checking is `complete` and its diagnostics are hard
    // errors everywhere in this package.
    //
    // Getting the library here took the whole concurrency-modernization epic:
    // #1910 removed the 231 `unavailable from asynchronous contexts` sites (raw
    // NSLock lock/unlock → scoped `withLock`), then #1988 (A, mechanical
    // fixes), #1991 (B, typed transport spine), #1992 (C, honest
    // model/schema/query `Sendable`), #1993 (D1-D3, actorized async managers)
    // and #1994 (E, AsyncStream events) drove the remaining `Sendable` error
    // sites from 67 to 0, and #1946 (F) flipped the `JsBaoClient` target on its
    // own. #2310 finished the job: `JsBaoClientTests` needed 91 sites cleared
    // (the same classes, plus lock-guarded `static var` test stubs, which are
    // global mutable state under `.v6`), and `SwiftBaoCodegen`,
    // `SwiftBaoCodegenTests` and `E2EMiniApp` were already clean.
    //
    // Because the mode is now the package default, a NEW target added below
    // inherits it — there is no per-target opt-in to remember.
    swiftLanguageModes: [.v6]
)
