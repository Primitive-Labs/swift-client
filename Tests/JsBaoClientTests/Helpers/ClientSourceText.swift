import Foundation
import XCTest

/// Shared source-text reading for the structural tests.
///
/// A recurring shape in the concurrency epic (#1910, #1992, #1993, #1994) is a
/// test that asserts something about the *source* rather than the behavior:
/// "this decision region contains no `await`", "this `@unchecked Sendable`
/// carries a written safety argument", "this file reaches for no
/// `JSONSerialization`". Those properties are real invariants that the compiler
/// does not check, and they are only checkable by reading the code.
///
/// Each phase grew its own private copy of the same four helpers. This is the
/// one copy. Two conventions it encodes, both load-bearing:
///
///  - **Structural checks read comment-stripped source** (`code(_:)`), so a
///    phrase quoted in a doc comment can never decide whether an invariant
///    holds. Checks about the *documentation* — a safety argument, say — read
///    the raw source instead (`clientSource(_:)`).
///  - **Anchored slices fail loudly** (`slice(_:from:to:)`). A region check that
///    silently matched an empty string when its anchors moved would pass
///    forever; this throws instead.
///
/// Paths resolve from this file's `#filePath`, so every helper works regardless
/// of the caller's directory or how deep in `Tests/` the calling suite sits.
enum ClientSourceText {

    /// The `swift-client` package root.
    static var packageRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        // .../Tests/JsBaoClientTests/Helpers/<this file>
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root
    }

    /// A file under `Sources/JsBaoClient`, verbatim.
    static func clientSource(_ relativePath: String) throws -> String {
        let url = packageRoot
            .appendingPathComponent("Sources/JsBaoClient")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// A file under `Sources/JsBaoClient` with its comments removed.
    static func code(_ relativePath: String) throws -> String {
        stripComments(try clientSource(relativePath))
    }

    /// A file relative to the package root (`scripts/…`, `run-tests.sh`, …).
    static func packageFile(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// A file relative to the repository root, one level above the package.
    static func repoFile(_ relativePath: String) throws -> String {
        var repo = packageRoot
        repo.deleteLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Every `.swift` file under `Sources/JsBaoClient`, verbatim.
    static func allClientSources() throws -> [String] {
        let root = packageRoot.appendingPathComponent("Sources/JsBaoClient")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var sources: [String] = []
        for case let path as String in walker where path.hasSuffix(".swift") {
            sources.append(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
        }
        return sources
    }

    /// Drops `//` line comments. Block comments are not used in these files.
    static func stripComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// The text between two anchors, so a region check fails loudly when the
    /// anchors move rather than silently passing on an empty slice.
    static func slice(_ source: String, from: String, to: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: from), "missing anchor: \(from)")
        let end = try XCTUnwrap(
            source.range(of: to, range: start.upperBound..<source.endIndex),
            "missing anchor: \(to)"
        )
        return String(source[start.upperBound..<end.lowerBound])
    }

    /// The contiguous `///` doc-comment block immediately above `declaration`.
    /// Scoped this way (rather than "anything earlier in the file") so a token
    /// that happens to appear in some other type's comment can't satisfy the
    /// check. Returns `nil` when the declaration isn't in the source at all.
    static func docComment(precedingDeclaration declaration: String, in source: String) -> String? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let declIndex = lines.firstIndex(where: { $0.hasPrefix(declaration) }) else { return nil }
        var block: [String] = []
        var i = declIndex - 1
        while i >= 0, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("///") {
            block.append(lines[i])
            i -= 1
        }
        return block.reversed().joined(separator: "\n")
    }

    /// Every `@unchecked Sendable` **declaration** line in a source file —
    /// doc comments that merely discuss the attribute are skipped, so a
    /// safety argument mentioning `@unchecked Sendable` doesn't count as one.
    static func uncheckedDeclarations(in source: String) -> [String] {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") && !$0.hasPrefix("*") }
            .filter { $0.contains("@unchecked Sendable") }
    }
}
