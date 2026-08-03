import XCTest
@testable import JsBaoClient
import YSwift

/// Phase C of the concurrency-modernization epic (#1992): the model / schema /
/// query layer conforms to `Sendable` **honestly** — class-plus-lock kept, each
/// unchecked conformance carrying a written safety argument, `PrimitiveRecord`
/// plainly checked, and one shared `Sendable` row bag behind the paginated
/// query surface.
///
/// What each kind of check here is worth:
///
///  - The `requireSendable(_:)` calls **document** the intended conformance
///    set at each call site, and they become a compile error the moment the
///    package flips to Swift 6 language mode (Phase F, #1946). Be clear about
///    what they are worth *today*: this target ships as `swift-tools-version:
///    5.9` with no `-strict-concurrency` flag, so passing a non-`Sendable`
///    type to a `T: Sendable` generic parameter produces **no diagnostic at
///    all** under `.v5` minimal checking (warning with
///    `-strict-concurrency=complete`, error under `.v6`). They are not a gate
///    on their own.
///  - The gate that *can* fail today is `scripts/v6-sendable-gate.sh`, run
///    with `--max` / `--require-zero` from `run-tests.sh`: it builds the
///    target under `.v6` and exits non-zero if any Phase C file regains a
///    Sendable error site. That is what actually enforces this phase's
///    headline invariant while the committed mode is still `.v5`.
///  - The source-text checks assert the *written safety argument* exists and
///    names the actual locks. An `@unchecked Sendable` is only as good as its
///    argument, so a future conformance added without one fails here.
///  - The rest are ordinary behavior tests: the live-handle semantics that
///    must survive (#1156), and read-path parity through the row bag.
final class SendableModelLayerTests: XCTestCase {

    private let schema = PrimitiveSchema(
        name: "sendable_items",
        fields: [
            "id":    FieldDescriptor(type: .id),
            "title": FieldDescriptor(type: .string),
            "score": FieldDescriptor(type: .number),
            "tags":  FieldDescriptor(type: .stringset),
        ]
    )

    private func seeded() throws -> DynamicModel {
        SchemaSync.clearCache()
        let model = DynamicModel(doc: YDocument(), schema: schema)
        for i in 1...3 {
            _ = try model.create(id: "s\(i)", values: [
                "title": .string("title-\(i)"),
                "score": .number(Double(i * 10)),
                "tags":  .stringset(["t\(i)"]),
            ])
        }
        return model
    }

    /// Records the intended `Sendable` conformance at a call site. Generic over
    /// `T: Sendable`, so every use below becomes a compile error once the
    /// package moves to Swift 6 language mode (#1946, Phase F). Under the
    /// committed `.v5` mode with minimal checking it is silent — see the note
    /// on the type; `scripts/v6-sendable-gate.sh` is the check that fails today.
    private func requireSendable<T: Sendable>(_ value: T) -> T { value }

    // MARK: - Behavior 7 — the conformances exist and are checked

    /// `PrimitiveRecord` conforms to **plain** `Sendable` (no `@unchecked`),
    /// and a `PagedQueryResult<PrimitiveRecord>` is `Sendable` through the
    /// conditional conformance on the container.
    func testPrimitiveRecordAndItsPageAreSendable() throws {
        let model = try seeded()
        let record = try XCTUnwrap(model.find(id: "s1"))

        _ = requireSendable(record)

        let page = PagedQueryResult(data: [record], nextCursor: nil, prevCursor: nil, hasMore: false)
        _ = requireSendable(page)
        XCTAssertEqual(page.data.first?.id, "s1")
    }

    /// The same values actually cross a `Task` boundary at runtime, and the
    /// record still reads through to the CRDT on the far side.
    func testPrimitiveRecordCrossesATaskBoundary() async throws {
        let model = try seeded()
        let record = try XCTUnwrap(model.find(id: "s2"))
        let page = PagedQueryResult(
            data: [record], nextCursor: "c", prevCursor: nil, hasMore: true
        )

        let title = await Task { record["title"]?.asString }.value
        XCTAssertEqual(title, "title-2")

        let ids = await Task { page.data.map(\.id) }.value
        XCTAssertEqual(ids, ["s2"])
    }

    /// The untyped paginated surface is `Sendable` too — that is what the row
    /// bag buys: `PagedQueryResult<PrimitiveRow>` from `queryPaged` (and, in
    /// the facade, from `queryPagedShared` / `hasManyThroughShared`) can be
    /// handed to another isolation domain.
    func testPagedRowsAreSendable() throws {
        let model = try seeded()
        let page = try model.queryPaged(nil, options: QueryOptions(sortOrder: [("id", 1)], limit: 2))
        _ = requireSendable(page)
        _ = requireSendable(page.data)
        XCTAssertEqual(page.data.count, 2)
        XCTAssertEqual(page.data.first?["id"] as? String, "s1")
    }

    /// `DynamicModel`, `MultiDocModel` and `BaoModelQueryEngine` are the
    /// unchecked-but-argued conformances; `ConfinedYDocument` is the shared
    /// document holder Phase D adopts, and `OpenDocumentResult` is plainly
    /// `Sendable` now that it holds one.
    func testSyncDomainTypesAreSendable() throws {
        let model = try seeded()
        _ = requireSendable(model)
        _ = requireSendable(model.inspectionQueryEngine)
        _ = requireSendable(MultiDocModel(schema: schema))

        let doc = YDocument()
        _ = requireSendable(ConfinedYDocument(doc))
        _ = requireSendable(OpenDocumentResult(doc: doc, metadata: nil))
    }

    // MARK: - Behavior 11 — the shared YDocument confinement holder

    /// The holder carries the SAME live document across a `Task` boundary —
    /// it confines, it does not copy or snapshot. Phase D (#1993) adopts this
    /// type rather than inventing a second one.
    func testConfinedYDocumentCarriesTheLiveDocument() async throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let model = DynamicModel(doc: doc, schema: schema)
        _ = try model.create(id: "c1", values: ["title": .string("before")])

        let confined = ConfinedYDocument(doc)
        let sameDocument = await Task { confined.document }.value
        XCTAssertTrue(sameDocument === doc, "the holder must carry the live document, not a copy")

        // A write made through the model after the hop is visible through the
        // document the far side received.
        try model.update(id: "c1", values: ["title": .string("after")])
        let readBack = DynamicModel(doc: sameDocument, schema: schema).find(id: "c1")
        XCTAssertEqual(readBack?["title"]?.asString, "after")

        // `OpenDocumentResult.doc` still resolves to the same document.
        XCTAssertTrue(OpenDocumentResult(doc: doc, metadata: nil).doc === doc)
    }

    // MARK: - Behavior 5 — PrimitiveRecord is still a live handle

    /// Two handles to the same record share the CRDT, not a snapshot: a write
    /// through one is visible through the other, in both directions. This is
    /// the regression that would tell us `PrimitiveRecord` had been quietly
    /// converted to a value snapshot (#1156).
    func testPrimitiveRecordStaysALiveHandle() throws {
        let model = try seeded()
        let handleA = try XCTUnwrap(model.find(id: "s1"))
        let handleB = try XCTUnwrap(model.find(id: "s1"))
        XCTAssertFalse(handleA === handleB, "expected two distinct handles to the same record")

        handleA["title"] = .string("written-through-A")
        XCTAssertEqual(handleB["title"]?.asString, "written-through-A")

        handleB["score"] = .number(99)
        XCTAssertEqual(handleA["score"]?.asNumber, 99)

        // And a write made directly on the model is visible through both.
        try model.update(id: "s1", values: ["title": .string("written-on-model")])
        XCTAssertEqual(handleA["title"]?.asString, "written-on-model")
        XCTAssertEqual(handleB["title"]?.asString, "written-on-model")
    }

    /// The handle survives a `Task` hop and still writes through afterwards —
    /// the point of making it `Sendable` in the first place.
    func testPrimitiveRecordWritesThroughAfterATaskHop() async throws {
        let model = try seeded()
        let record = try XCTUnwrap(model.find(id: "s3"))

        await Task { record["title"] = .string("set-off-thread") }.value

        XCTAssertEqual(model.find(id: "s3")?["title"]?.asString, "set-off-thread")
    }

    // MARK: - Behavior 9 — read-path parity through the row bag

    /// Wrapping rows in `PrimitiveRow` changes the container, not the data:
    /// a paged read returns field-for-field what the unpaged read returns.
    func testPagedRowsMatchUnpagedRows() throws {
        let model = try seeded()
        let options = QueryOptions(sortOrder: [("id", 1)])
        let unpaged = try model.query(nil, options: options)
        let paged = try model.queryPaged(nil, options: options)

        XCTAssertEqual(paged.data.count, unpaged.count)
        for (row, dict) in zip(paged.data, unpaged) {
            XCTAssertEqual(Set(row.raw.keys), Set(dict.keys))
            XCTAssertEqual(row["id"] as? String, dict["id"] as? String)
            XCTAssertEqual(row["title"] as? String, dict["title"] as? String)
            XCTAssertEqual(row["score"] as? Double, dict["score"] as? Double)
            XCTAssertEqual(row["tags"] as? [String], dict["tags"] as? [String])
        }
    }

    /// `RelatedRecords` and `PrimitiveRow` are ONE type, not two competing
    /// unchecked dictionary wrappers — the sponsor's "no competing
    /// conventions" decision, checked rather than assumed.
    func testRelatedRecordsIsTheSharedRowBag() {
        XCTAssertTrue(RelatedRecords.self == PrimitiveRow.self)
        let asRelated: RelatedRecords = PrimitiveRow(raw: ["a": 1])
        XCTAssertEqual(asRelated["a"] as? Int, 1)
        XCTAssertTrue(RelatedRecords.empty.raw.isEmpty)
    }

    // MARK: - Edge cases: nested `_related` and the NSNull sentinel

    /// The bag's `Sendable` safety argument claims the nested `_related`
    /// dictionaries and arrays `IncludeResolver` produces stay readable
    /// through the wrapper. Check the round-trip on the paginated path, which
    /// is where rows are wrapped.
    func testNestedRelatedSurvivesTheRowBagRoundTrip() throws {
        SchemaSync.clearCache()
        let doc = YDocument()
        let authors = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "bag_authors",
            fields: ["id": FieldDescriptor(type: .id), "name": FieldDescriptor(type: .string)]
        ))
        let books = DynamicModel(doc: doc, schema: PrimitiveSchema(
            name: "bag_books",
            fields: [
                "id":       FieldDescriptor(type: .id),
                "authorId": FieldDescriptor(type: .string, indexed: true),
                "title":    FieldDescriptor(type: .string),
            ]
        ))
        _ = try authors.create(id: "a1", values: ["name": .string("Ada")])
        _ = try books.create(id: "b1", values: [
            "authorId": .string("a1"), "title": .string("Notes"),
        ])

        // refersTo → a nested [String: Any] under `_related`.
        let page = try books.queryPaged(
            nil, options: QueryOptions(sortOrder: [("id", 1)]),
            include: [Include(type: .refersTo, target: authors,
                              sourceField: "authorId", resultKey: "author")]
        )
        let row = try XCTUnwrap(page.data.first)
        let related = try XCTUnwrap(row["_related"] as? [String: Any])
        let author = try XCTUnwrap(related["author"] as? [String: Any])
        XCTAssertEqual(author["name"] as? String, "Ada")

        // hasMany → a nested [[String: Any]], and it decodes through the
        // bag's typed accessors on the `_related` bag itself.
        let authorPage = try authors.queryPaged(
            nil, options: QueryOptions(sortOrder: [("id", 1)]),
            include: [Include(type: .hasMany, target: books,
                              foreignKey: "authorId", resultKey: "books")]
        )
        let authorRow = try XCTUnwrap(authorPage.data.first)
        let authorRelated = PrimitiveRow(raw: try XCTUnwrap(authorRow["_related"] as? [String: Any]))
        XCTAssertTrue(authorRelated.contains("books"))
        let decoded: [BagBook] = authorRelated.many("books")
        XCTAssertEqual(decoded.map(\.title), ["Notes"])
        XCTAssertNil(authorRelated.one("books", as: BagBook.self),
                     "a hasMany payload is an array, so `one` must not decode it")

        // And the whole page is still Sendable with the nested bag inside.
        _ = requireSendable(authorPage)
    }

    /// An `NSNull` sentinel a caller puts in a row reads back unchanged
    /// through the wrapper. (The query engine omits SQL NULLs rather than
    /// boxing them, so this is about callers, not the engine.)
    func testNullSentinelReadsBackThroughTheBag() {
        let row = PrimitiveRow(raw: ["present": "x", "explicitNull": NSNull()])
        XCTAssertEqual(row["present"] as? String, "x")
        XCTAssertTrue(row.contains("explicitNull"))
        XCTAssertTrue(row["explicitNull"] is NSNull)
        XCTAssertFalse(row.contains("absent"))
        XCTAssertNil(row["absent"])
    }

    // MARK: - Behavior 6 — every unchecked conformance carries its argument

    /// `@unchecked Sendable` is a claim the compiler does not check, so the
    /// acceptance bar for this phase is a written safety argument that names
    /// the specific locks. Assert the argument exists — and names the right
    /// locks — for each of the three sync-domain classes, so a later
    /// conformance can't be added bare.
    func testUncheckedConformancesCarryWrittenSafetyArguments() throws {
        let cases: [(file: String, declaration: String, mustMention: [String])] = [
            (
                "Schema/DynamicModel.swift",
                "public final class DynamicModel: @unchecked Sendable",
                ["observerLock", "listenerLock", "ffiLock", "NSRecursiveLock",
                 "withExclusiveAccess", "transactSync"]
            ),
            (
                "Schema/MultiDocModel.swift",
                "final class MultiDocModel: IncludeTarget, @unchecked Sendable",
                // `listenerLock` is the member's lock, taken while `lock` is
                // still held — naming it is what completes the acquisition
                // order (a two-lock claim would be incomplete, not wrong).
                ["subscribeLock", "activeSubs", "members", "NSLock", "listenerLock"]
            ),
            (
                "Query/BaoModelQueryEngine.swift",
                "public final class BaoModelQueryEngine: @unchecked Sendable",
                ["_rowWriteCount", "registeredJunctions", "stringFieldsByModel",
                 "fieldTypeNamesByModel", "NSLock"]
            ),
            (
                "Types/DocumentTypes.swift",
                "public struct ConfinedYDocument: @unchecked Sendable",
                ["ffiLock", "NSRecursiveLock", "transactSync"]
            ),
            (
                "Schema/PrimitiveModel.swift",
                "public struct PrimitiveRow: @unchecked Sendable",
                ["IncludeResolver", "_related", "copy-on-write"]
            ),
        ]

        for entry in cases {
            let source = try Self.clientSource(entry.file)
            guard let argument = Self.docComment(precedingDeclaration: entry.declaration, in: source) else {
                XCTFail("\(entry.file): expected declaration `\(entry.declaration)`")
                continue
            }
            XCTAssertTrue(
                argument.contains("safety argument"),
                "\(entry.file): `\(entry.declaration)` must be preceded by a written safety argument"
            )
            for token in entry.mustMention {
                XCTAssertTrue(
                    argument.contains(token),
                    "\(entry.file): the safety argument must name `\(token)`"
                )
            }
        }
    }

    /// The safety table says every subscription handle is `observerLock`-
    /// confined outside `deinit`. `testUncheckedConformancesCarryWrittenSafety
    /// Arguments` only proves the token `observerLock` appears somewhere in the
    /// block, which a handle written with no lock at all would still satisfy —
    /// so check the write sites themselves. Every assignment to
    /// `rootSubscription` / `docUpdateSubscription` outside `deinit` must be on
    /// an `observerLock.withLock` line.
    ///
    /// Note the constraint this places on formatting: the check is per-line, so
    /// `observerLock.withLock` has to sit on the *same physical line* as the
    /// assignment. Both write sites are one-liners today. A correct multi-line
    /// `observerLock.withLock { … handle = x … }` would fail this test — that
    /// failure means "reformat the write onto one line (or teach this test to
    /// track `withLock` blocks by brace depth)", not "the confinement broke".
    func testSubscriptionHandleWritesTakeObserverLock() throws {
        let source = try Self.clientSource("Schema/DynamicModel.swift")
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // `deinit` is the documented exception (nothing left to exclude by
        // then, and the handles are dropped under the doc's `ffiLock`
        // instead), so skip its body — tracked by brace depth, not by
        // "everything after", so a write added further down the file is still
        // checked.
        var inDeinit = false
        var depth = 0
        var writes: [String: Int] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inDeinit, trimmed.hasPrefix("deinit {") {
                inDeinit = true
                depth = 0
            }
            if inDeinit {
                depth += line.filter { $0 == "{" }.count
                depth -= line.filter { $0 == "}" }.count
                if depth <= 0 { inDeinit = false }
                continue
            }
            guard !trimmed.hasPrefix("//") else { continue }
            for handle in ["rootSubscription", "docUpdateSubscription"]
            where trimmed.contains("\(handle) =") || trimmed.contains("\(handle)=") {
                writes[handle, default: 0] += 1
                XCTAssertTrue(
                    trimmed.contains("observerLock.withLock"),
                    "`\(handle)` is assigned without `observerLock` at: \(trimmed)"
                )
            }
        }

        for handle in ["rootSubscription", "docUpdateSubscription"] {
            XCTAssertGreaterThan(writes[handle] ?? 0, 0,
                                 "expected at least one write to `\(handle)` outside deinit")
        }
    }

    /// The one check that can actually fail while the target compiles in `.v5`
    /// is the gate script — so make sure it stays wired up as an assertion.
    /// Without `--max` / `--require-zero` it only measures and always exits 0,
    /// which is the state the review flagged.
    func testV6SendableGateIsWiredAsAnAssertion() throws {
        let gate = try ClientSourceText.packageFile("scripts/v6-sendable-gate.sh")
        XCTAssertTrue(gate.contains("--max"), "the gate script must support a failing budget assertion")
        XCTAssertTrue(gate.contains("--require-zero"), "the gate script must support a per-file zero assertion")
        XCTAssertTrue(gate.contains("exit \"$FAILED\""), "the gate script must exit non-zero on a regression")

        let runner = try ClientSourceText.packageFile("run-tests.sh")
        XCTAssertTrue(runner.contains("v6-sendable-gate.sh --max"),
                      "run-tests.sh must invoke the gate in assertion mode")
        for file in ["JsBaoClient.swift", "Schema/DynamicModel.swift", "Schema/MultiDocModel.swift",
                     "Schema/RelationshipResolution.swift", "Query/BaoModelQueryEngine.swift",
                     // #2172 — the new actor boundary. Kept here in lockstep
                     // with run-tests.sh's V6_ZERO_FILES so a half-update fails.
                     "Internal/BlobManager.swift"] {
            XCTAssertTrue(runner.contains("\"\(file)\""),
                          "run-tests.sh must hold \(file) at zero .v6 Sendable sites")
        }
    }

    /// `PrimitiveRecord` is the one type in this layer that must NOT be
    /// unchecked — its conformance is compiler-verified, so it carries no
    /// safety-argument debt.
    func testPrimitiveRecordConformanceIsChecked() throws {
        let source = try Self.clientSource("Schema/PrimitiveRecord.swift")
        XCTAssertTrue(source.contains("public final class PrimitiveRecord: Sendable"))
        XCTAssertTrue(
            Self.uncheckedDeclarations(in: source).isEmpty,
            "PrimitiveRecord's conformance is checked — an @unchecked here would be a regression"
        )
    }

    /// The untyped rows are the ONE unchecked row representation. A second
    /// `@unchecked Sendable` dictionary wrapper would be the competing
    /// convention the sponsor ruled out.
    func testOnlyOneUncheckedRowWrapperExists() throws {
        let source = try Self.clientSource("Schema/PrimitiveModel.swift")
        let declarations = Self.uncheckedDeclarations(in: source)
        XCTAssertEqual(declarations.count, 1,
                       "expected exactly one unchecked row bag in PrimitiveModel.swift, found \(declarations)")
        XCTAssertTrue(declarations.first?.contains("struct PrimitiveRow") == true)
    }

    // MARK: - Helpers

    // The implementations live in `Helpers/ClientSourceText.swift` — the same
    // three helpers were copied into every phase's structural suite, so there
    // is one copy now (consolidated in Phase D4 of #1993). These are the local
    // names the tests above use.

    private static func docComment(precedingDeclaration declaration: String, in source: String) -> String? {
        ClientSourceText.docComment(precedingDeclaration: declaration, in: source)
    }

    private static func uncheckedDeclarations(in source: String) -> [String] {
        ClientSourceText.uncheckedDeclarations(in: source)
    }

    private static func clientSource(_ relativePath: String) throws -> String {
        try ClientSourceText.clientSource(relativePath)
    }
}

/// Minimal row-decodable used to prove the shared bag's typed accessors still
/// work on a nested `_related` payload.
private struct BagBook: PrimitiveRowDecodable, Equatable {
    let id: String
    let title: String

    init?(row: [String: Any]) {
        guard let id = row["id"] as? String, let title = row["title"] as? String else { return nil }
        self.id = id
        self.title = title
    }
}
