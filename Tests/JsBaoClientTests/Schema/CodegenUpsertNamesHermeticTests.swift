import XCTest
@testable import JsBaoClient

/// #5895 behavior 9 — a generated model's typed upsert names, through the
/// committed `CodegenAcceptance/Generated/CrashTestRecord.swift`.
///
/// `CrashTestRecord.UniqueField` names its unique field `email`, and
/// `CrashTestRecord.UniqueConstraint` the constraints `upsertByUnique`
/// looks up: `crashTest_email_unique` and `name_score_combo`. The typed
/// overloads upsert exactly as the `String` forms do.
final class CodegenUpsertNamesHermeticTests: XCTestCase {

    func testTheEnumsCarryTheModelsNames() {
        XCTAssertEqual(CrashTestRecord.UniqueField.email.rawValue, "email")
        XCTAssertEqual(CrashTestRecord.UniqueConstraint.crashTest_email_unique.rawValue, "crashTest_email_unique")
        XCTAssertEqual(CrashTestRecord.UniqueConstraint.name_score_combo.rawValue, "name_score_combo")
    }

    func testTypedUpsertsMergeOnTheNamedUniqueKey() async throws {
        let client = createTestClient(appId: "t", token: "t", offline: true, storageConfig: .memory)
        JsBaoClient.configureDefault(client)
        defer { JsBaoClient.clearDefault() }
        SchemaSync.clearCache()
        client.registerModels([CrashTestRecord.self])
        let (doc, _) = try await client.createDocumentForTest(options: CreateDocumentOptions(localOnly: true))

        let inserted = try CrashTestRecord(id: "u1", requiredTags: ["a"], email: "x@y.z", boundedName: "first")
            .save(in: doc, upsertOn: .email)
        XCTAssertEqual(inserted.id, "u1")
        let merged = try CrashTestRecord(requiredTags: ["a"], email: "x@y.z", boundedName: "second")
            .save(in: doc, upsertOn: .email)
        XCTAssertEqual(merged.id, "u1")
        XCTAssertEqual(merged.boundedName, "second")

        let byEmail = try CrashTestRecord(requiredTags: ["a"], email: "x@y.z", boundedName: "third")
            .upsertByUnique(.crashTest_email_unique, in: doc)
        XCTAssertEqual(byEmail.id, "u1")
        XCTAssertEqual(byEmail.boundedName, "third")

        let compound = try CrashTestRecord(id: "u2", requiredTags: ["a"], boundedName: "ada", score: 100)
            .upsertByUnique(.name_score_combo, lookupValue: [.string("ada"), .number(100)], in: doc)
        XCTAssertEqual(compound.id, "u2")
        let compoundMerge = try CrashTestRecord(requiredTags: ["a"], boundedName: "ada", score: 100, active: false)
            .upsertByUnique(.name_score_combo, mode: .mustExist, in: doc)
        XCTAssertEqual(compoundMerge.id, "u2")
        XCTAssertEqual(compoundMerge.active, false)
        XCTAssertEqual(try CrashTestRecord.count(), 2)
    }
}
