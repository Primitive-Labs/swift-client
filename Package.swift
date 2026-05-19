// swift-tools-version: 5.9
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
        // Build-time codegen tool that turns a TOML schema (same shape
        // `TomlSchemaLoader` accepts) into one Swift file per model. Use
        // standalone, or via the SwiftPM plugin below to run on every
        // `swift build`.
        .executable(
            name: "swift-bao-codegen",
            targets: ["SwiftBaoCodegen"]
        ),
        // Alias product mirroring the target name. Lets the
        // codegen plugin's `dependencies: ["SwiftBaoCodegen"]`
        // resolve when consumed BY A TARGET IN THE SAME PACKAGE
        // (e.g. the `E2EMiniApp` cross-language test mini-app).
        // Without this alias, in-package consumers fail with
        // "no product named SwiftBaoCodegen". Cross-package
        // consumers (the demo apps) work either way — they
        // resolve the plugin's tool dependency through the
        // package graph by target name.
        .executable(
            name: "SwiftBaoCodegen",
            targets: ["SwiftBaoCodegen"]
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
        .package(url: "https://github.com/Primitive-Labs/yswift-fork.git", branch: "main"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "JsBaoClient",
            dependencies: [
                .product(name: "YSwift", package: "yswift-fork"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Sources/JsBaoClient",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "SwiftBaoCodegen",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Sources/SwiftBaoCodegen"
        ),
        .plugin(
            name: "JsBaoCodegenPlugin",
            capability: .buildTool(),
            // Reference the executable PRODUCT (not the target) so
            // the plugin's tool dep resolves identically whether
            // the plugin is consumed in-package (e.g. `E2EMiniApp`
            // in this Package.swift) or cross-package (the demo
            // app's Package.swift). With `["SwiftBaoCodegen"]` —
            // the target name — SwiftPM rejects in-package
            // consumers with "no product named SwiftBaoCodegen".
            dependencies: ["SwiftBaoCodegen"],
            path: "Plugins/JsBaoCodegenPlugin"
        ),
        .testTarget(
            name: "JsBaoClientTests",
            dependencies: ["JsBaoClient"],
            path: "Tests/JsBaoClientTests",
            // The cross-language E2E mini-app lives under this test
            // target's path tree but compiles as its own executable
            // target (`E2EMiniApp`) — exclude here so SwiftPM
            // doesn't pull the same Swift sources into both target
            // compilations.
            exclude: ["CrossPlatform/E2E"]
        ),
        .testTarget(
            name: "SwiftBaoCodegenTests",
            dependencies: ["SwiftBaoCodegen"],
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
    ]
)
