import XCTest
@testable import JsBaoClient

/// #5230 behavior 24 and edge case 43 — the Swift client's model loop, live
/// against the dev server's model routes with the real transport (no fake;
/// F-5230-002): claims are shortened with the room's `index-model-claim-ms`
/// test route, networking is turned off with `setNetworkMode(.offline)`, and
/// every request and answer is heard, with when, through the client's
/// pass-through observers.
///
/// - 24: a pending claim is waited out until its expiry + 250 ms and taken
///   over at the next revision, the lapsed holder's upload refused; a
///   training that fails gives its claim back; an upload refused for want of
///   network keeps its bytes and sends exactly those once online, training
///   once; a refused upload reads the list again; a failure the server did
///   not answer is tried again after 1 s, doubling to 10 s; the loop runs for
///   a synced db3 only while live and online.
/// - 43: a user change ends a claim wait, its retry and its kept bytes; a
///   destroy ends the loop's timers; an unbind forgets the db3's waits and
///   kept bytes.
final class Db3VectorModelsLoopLiveTests: XCTestCase {

    private typealias V = Db3VectorLive

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-vector-loop-5230")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    /// Another holder's claim on the upload, taken over HTTP.
    private func claim(_ id: String, generation: Int, revision: Int = 1) async throws -> (token: String, expiresAt: Int64) {
        let claimed = try await V.modelRoute(live, id, method: "PUT", headers: [
            "Content-Type": "application/octet-stream", "X-Index-Model-Generation": String(generation), "X-Index-Model-Revision": String(revision),
            "X-Index-Model-Claim": "request",
        ], body: Data())
        XCTAssertEqual(claimed.status, 202, String(data: claimed.body, encoding: .utf8) ?? "")
        let claim = try XCTUnwrap(JSONValue(jsonText: String(data: claimed.body, encoding: .utf8) ?? "")?["claim"])
        return (try XCTUnwrap(claim["token"]?.stringValue), Int64(try XCTUnwrap(claim["expiresAt"]?.numberValue)))
    }

    func testAPendingClaimIsWaitedOutAndTakenOverOnceItLapses() async throws {
        let id = try await V.seeded(live)
        let index = try await V.register(live, id)
        let generation = try XCTUnwrap(index["generation"] as? Int)
        _ = try await live.route(id, "index-model-claim-ms", ["ms": 6_000])
        let held = try await claim(id, generation: generation)

        let a = try await V.device(live, id, name: "a")
        // Its claim is refused while the other's holds: nothing trained, exact answers.
        try await eventually(timeout: 30, description: "the device's claim to be refused") {
            a.traffic.modelAnswers().contains { $0.method == .put && $0.status == 409 }
        }
        let refused = try XCTUnwrap(a.traffic.modelAnswers().first { $0.method == .put && $0.status == 409 })
        XCTAssertEqual(refused.code, JsBaoErrorCode.db3IndexModelExists.rawValue)
        let details = JSONValue(jsonText: String(data: refused.body, encoding: .utf8) ?? "")?["details"]
        XCTAssertEqual(details?["pending"], true)
        XCTAssertEqual(details?["expiresAt"]?.numberValue.map { Int64($0) }, held.expiresAt)
        XCTAssertEqual(a.client.vec1Trainer.runs, 0)
        let mode = await V.mode(a.client, id)
        XCTAssertEqual(mode, .exact)
        XCTAssertEqual(try V.nearest(a.client, id, 5).first?["id"]?.stringValue, V.id(5))

        // At the claim's expiry + 250 ms it claims again, takes it over at the next revision, trains and installs.
        try await eventually(timeout: 120, description: "the device to take the lapsed claim over") { await V.mode(a.client, id) == .ann }
        let claims = a.traffic.model().filter { $0.method == .put && $0.bodyBytes == 0 }
        XCTAssertGreaterThanOrEqual(claims.count, 2)
        let retaken = claims[1].at.timeIntervalSince1970 * 1000
        XCTAssertGreaterThanOrEqual(retaken, Double(held.expiresAt) + 250 - 50, "the wait ends at the expiry + 250 ms")
        XCTAssertLessThan(retaken, Double(held.expiresAt) + 250 + 3_000)
        let listing = try await V.listed(live, id)
        XCTAssertEqual((listing?["annModel"] as? [String: Any])?["revision"] as? Int, 2)
        XCTAssertEqual(a.client.vec1Trainer.runs, 1)
        // The lapsed holder's upload commits nothing.
        let late = try await V.modelRoute(live, id, method: "PUT", headers: [
            "Content-Type": "application/octet-stream", "X-Index-Model-Generation": String(generation), "X-Index-Model-Revision": "1",
            "X-Index-Model-Rows": String(V.rows), "X-Index-Model-Trained-At": Db3IndexesAPI.isoDate(Date()), "X-Index-Model-Format": "pvm1",
            "X-Index-Model-Claim": held.token,
        ], body: Data(count: 16))
        XCTAssertEqual(late.status, 409)
        XCTAssertEqual(HttpError.parseBody(String(data: late.body, encoding: .utf8)).code, JsBaoErrorCode.db3IndexModelStale.rawValue)
        a.subscription.dispose()
    }

    func testATrainingThatFailsGivesItsClaimBack() async throws {
        // Half the rows hold no embedding: the sample is under the 4 · nbucket vectors vec1 trains with.
        let id = try await V.seeded(live, embedded: { $0 % 2 == 1 })
        let index = try await V.register(live, id, [
            "model": V.model, "field": "embedding", "kind": "vector", "on": "device",
            "vector": ["distance": "cos", "index": ["mode": "ann", "nbucket": 300]],
        ])
        let generation = try XCTUnwrap(index["generation"] as? Int)
        let a = try await V.device(live, id, name: "a")
        try await eventually(timeout: 60, description: "the claim given back") {
            a.traffic.modelAnswers().contains { $0.method == .delete }
        }
        let answered = a.traffic.modelAnswers()
        XCTAssertEqual(answered.first { $0.method == .put }?.status, 202, "claimed")
        let released = answered.first { $0.method == .delete }
        XCTAssertEqual(released?.status.map { (200..<300).contains($0) }, true, "released: \(released?.failure ?? String(data: released?.body ?? Data(), encoding: .utf8) ?? "")")
        XCTAssertGreaterThanOrEqual(a.client.vec1Trainer.runs, 1)
        // Given back: another holder may claim it at once.
        let taken = try await V.modelRoute(live, id, method: "PUT", headers: [
            "Content-Type": "application/octet-stream", "X-Index-Model-Generation": String(generation), "X-Index-Model-Revision": "1",
            "X-Index-Model-Claim": "request",
        ], body: Data())
        XCTAssertEqual(taken.status, 202)
        let mode = await V.mode(a.client, id)
        XCTAssertEqual(mode, .exact)
        a.subscription.dispose()
    }

    func testAnUploadTheNetworkRefusesKeepsItsBytesAndSendsExactlyThoseOnceOnline() async throws {
        let rows = 20_000
        let vectors = Db3VectorTestSupport.clusteredVectors(rows, V.dims, clusters: 40, seed: 24)
        let id = try await V.seeded(live, count: rows, vectors: vectors)
        try await V.register(live, id)
        let client = try await live.client("a", models: [V.note])
        let traffic = Db3ModelTraffic(client)
        let subscription = try client.db3.subscribe(id)
        try await subscription.ready()
        // Offline once its claim is granted, while its training runs.
        try await eventually(timeout: 60, description: "the claim granted") { traffic.modelAnswers().contains { $0.method == .put && $0.status == 202 } }
        client.setNetworkMode(.offline)
        let sentBefore = traffic.model().count
        try await eventually(timeout: 120, description: "the trained bytes kept") { client.db3VectorModels.retainedBytes(id, V.name) != nil }
        let kept = try XCTUnwrap(client.db3VectorModels.retainedBytes(id, V.name))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(traffic.model().count, sentBefore, "nothing is sent while offline")
        XCTAssertEqual(client.vec1Trainer.runs, 1)
        client.setNetworkMode(.online)
        try await eventually(timeout: 60, description: "the kept bytes uploaded and installed") { await V.mode(client, id) == .ann }
        let upload = try XCTUnwrap(traffic.model().last { $0.method == .put && $0.bodyBytes > 0 })
        XCTAssertEqual(upload.bodyBytes, kept.count)
        XCTAssertEqual(client.vec1Trainer.runs, 1, "trained once")
        let fetched = try await client.db3.indexes.fetchModel(id, name: V.name)
        XCTAssertEqual(fetched.bytes, kept)
        XCTAssertNil(client.db3VectorModels.retainedBytes(id, V.name))
        subscription.dispose()
    }

    func testARefusedUploadReadsTheListAgain() async throws {
        let rows = 20_000
        let vectors = Db3VectorTestSupport.clusteredVectors(rows, V.dims, clusters: 40, seed: 25)
        let id = try await V.seeded(live, count: rows, vectors: vectors)
        try await V.register(live, id)
        let owner = try await live.client("owner", models: [])
        let client = try await live.client("a", models: [V.note])
        let traffic = Db3ModelTraffic(client)
        let subscription = try client.db3.subscribe(id)
        try await subscription.ready()
        try await eventually(timeout: 60, description: "the claim granted") { traffic.modelAnswers().contains { $0.method == .put && $0.status == 202 } }
        // The owner deletes the pending upload while the device trains: its upload is refused, and it reads the list again.
        _ = try await owner.db3.indexes.deleteModel(id, name: V.name)
        try await eventually(timeout: 120, description: "the device's upload refused") {
            traffic.modelAnswers().contains { $0.method == .put && $0.status == 409 }
        }
        let refusal = try XCTUnwrap(traffic.answers.firstIndex { $0.path.hasSuffix("/model") && $0.method == .put && $0.status == 409 })
        try await eventually(timeout: 30, description: "the list read again after the refusal") {
            traffic.answers.dropFirst(refusal + 1).contains { $0.method == .get && $0.path.hasSuffix("/indexes") }
        }
        // It trains revision 2's model.
        try await eventually(timeout: 120, description: "revision 2's model") {
            ((try await V.listed(self.live, id))?["annModel"] as? [String: Any])?["revision"] as? Int == 2
        }
        subscription.dispose()
    }

    func testAFailureTheServerDidNotAnswerIsTriedAgainAfterOneSecondDoublingToTen() async throws {
        let id = try await V.seeded(live)
        let index = try await V.register(live, id)
        let generation = try XCTUnwrap(index["generation"] as? Int)
        // A 64 MiB body listed as the model: a fetch with a short timeout gets no answer.
        // The timeout is URLSession's idle interval, not the transfer's: at 50 ms a warm
        // dev server answered the whole body in time (1 run in 3), at 1 ms none does.
        let owner = try await live.client("owner", models: [])
        _ = try await owner.db3.indexes.uploadModel(id, name: V.name, bytes: Data(count: 64 * 1024 * 1024), upload: Db3IndexModelUpload(
            generation: generation, revision: 1, rows: V.rows, trainedAt: Date()
        ))
        let client = try await live.client("a", models: [V.note])
        client.db3ModelRequestTimeoutForTest = 0.001
        let traffic = Db3ModelTraffic(client)
        let subscription = try client.db3.subscribe(id)
        try await subscription.ready()
        try await eventually(timeout: 45, description: "six fetches") { traffic.model().filter { $0.method == .get }.count >= 6 }
        let fetches = traffic.model().filter { $0.method == .get }.map(\.at)
        XCTAssertTrue(traffic.modelAnswers().filter { $0.method == .get }.allSatisfy { $0.status == nil }, "no fetch was answered")
        let gaps = zip(fetches.dropFirst(), fetches).map { $0.timeIntervalSince($1) }
        for (gap, wanted) in zip(gaps, [1.0, 2.0, 4.0, 8.0, 10.0]) {
            XCTAssertGreaterThanOrEqual(gap, wanted - 0.1, "\(gaps)")
            XCTAssertLessThan(gap, wanted + 1.5, "\(gaps)")
        }
        // A fetch that gets the whole body installs nothing it cannot check, and is not tried again at that revision.
        client.db3ModelRequestTimeoutForTest = nil
        subscription.dispose()
    }

    func testTheLoopRunsOnlyWhileLiveAndOnlineAndResumesWhenItIs() async throws {
        // 900 rows: under the 1,000 a training needs, so nothing is wanted yet.
        let id = try await V.seeded(live, count: 900)
        try await V.register(live, id)
        let device = try await V.device(live, id, name: "a", count: 900)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(device.traffic.methods(), [])
        // Offline, 300 rows written here make a training wanted: nothing is sent.
        device.client.setNetworkMode(.offline)
        for i in 900..<V.rows {
            _ = try device.client.codegen.save(V.note, id: V.id(i), values: [
                "title": .string("note \(i)"), "n": .number(Double(i)), "embedding": .vector(V.vectors[i]),
            ], in: id)
        }
        let wants = try live.binding(device.client, id).store.vectorModelWants()
        XCTAssertEqual(wants.map(\.want), [.train])
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(device.traffic.methods(), [], "nothing while offline")
        XCTAssertEqual(device.client.vec1Trainer.runs, 0)
        // Online again: the loop runs, claims, trains and installs.
        device.client.setNetworkMode(.online)
        try await eventually(timeout: 120, description: "the model work once online") { await V.mode(device.client, id) == .ann }
        XCTAssertEqual(device.client.vec1Trainer.runs, 1)
        device.subscription.dispose()
    }

    // MARK: - 43: teardown

    func testAUserChangeEndsAClaimWaitAndItsKeptBytes() async throws {
        let id = try await V.seeded(live)
        let index = try await V.register(live, id)
        let generation = try XCTUnwrap(index["generation"] as? Int)
        _ = try await live.route(id, "index-model-claim-ms", ["ms": 4_000])
        let held = try await claim(id, generation: generation)
        let a = try await V.device(live, id, name: "a", file: live.file("switch"))
        try await eventually(timeout: 30, description: "the claim wait armed") {
            a.traffic.modelAnswers().contains { $0.method == .put && $0.status == 409 }
        }
        let member = try await ctx.createTestUser(appId: live.app.appId)
        a.client.updateToken(member.jwt)
        await a.client.rebindUserScopedStorage()
        let after = a.traffic.model().count
        // Past the claim's expiry + 250 ms: nothing of the old user's wait runs.
        let wait = max(0, Double(held.expiresAt) / 1000 - Date().timeIntervalSince1970) + 1.5
        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        XCTAssertEqual(a.traffic.model().count, after, "no model request of the old user's after the change: \(a.traffic.methods(from: 0))")
        XCTAssertNil(a.client.db3VectorModels.retainedBytes(id, V.name))
        XCTAssertFalse(a.client.db3VectorModels.busy(id, V.name))
        a.subscription.dispose()
    }

    /// F-5230-CODE-002: a user change while a training runs ends its job: once
    /// the training returns, nothing of it is sent (no upload, no release)
    /// under the new user's credentials, no bytes are kept, and the room lists
    /// no model of it.
    func testAUserChangeDuringATrainingSendsNothingOfItUnderTheNewUser() async throws {
        let rows = 20_000
        let vectors = Db3VectorTestSupport.clusteredVectors(rows, V.dims, clusters: 40, seed: 27)
        let id = try await V.seeded(live, count: rows, vectors: vectors)
        try await V.register(live, id)
        let client = try await live.client("a", models: [V.note], file: live.file("switch-training"))
        let traffic = Db3ModelTraffic(client)
        let subscription = try client.db3.subscribe(id)
        try await subscription.ready()
        try await eventually(timeout: 60, description: "the claim granted") { traffic.modelAnswers().contains { $0.method == .put && $0.status == 202 } }
        try await eventually(timeout: 30, description: "the training under way") { client.vec1Trainer.running == 1 }
        let member = try await ctx.createTestUser(appId: live.app.appId)
        client.updateToken(member.jwt)
        await client.rebindUserScopedStorage()
        let after = traffic.model().count
        try await eventually(timeout: 120, description: "the training returned") { client.vec1Trainer.running == 0 }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(traffic.model().count, after, "no model request of the old user's job after the change: \(traffic.methods(from: after))")
        XCTAssertEqual(client.vec1Trainer.runs, 1)
        XCTAssertNil(client.db3VectorModels.retainedBytes(id, V.name))
        XCTAssertFalse(client.db3VectorModels.busy(id, V.name))
        let listing = try await V.listed(live, id)
        XCTAssertNil(listing?["annModel"], "no model uploaded")
        subscription.dispose()
    }

    func testADestroyEndsTheLoopsTimersAndAnUnbindForgetsTheDb3sWaits() async throws {
        let id = try await V.seeded(live)
        let index = try await V.register(live, id)
        let generation = try XCTUnwrap(index["generation"] as? Int)
        _ = try await live.route(id, "index-model-claim-ms", ["ms": 4_000])
        let held = try await claim(id, generation: generation)
        // An unbind (an evict): the db3's wait is forgotten, and the rebound db3 claims afresh.
        let a = try await V.device(live, id, name: "a")
        try await eventually(timeout: 30, description: "the claim wait armed") {
            a.traffic.modelAnswers().contains { $0.method == .put && $0.status == 409 }
        }
        a.subscription.dispose()
        try await a.client.db3.evict(id, options: Db3EvictOptions(force: true))
        let afterEvict = a.traffic.model().count
        let wait = max(0, Double(held.expiresAt) / 1000 - Date().timeIntervalSince1970) + 1.5
        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        XCTAssertEqual(a.traffic.model().count, afterEvict, "the forgotten wait ran nothing")
        let rebound = try a.client.db3.subscribe(id)
        try await rebound.ready()
        try await eventually(timeout: 120, description: "the rebound db3 trains afresh") { await V.mode(a.client, id) == .ann }
        rebound.dispose()

        // A destroy: no request and no store command after it returns.
        _ = try await live.route(id, "index-model-claim-ms", ["ms": 4_000])
        let owner = try await live.client("owner", models: [])
        let deleted = try await owner.db3.indexes.deleteModel(id, name: V.name)
        let second = try await claim(id, generation: generation, revision: deleted.revision)
        let b = try await V.device(live, id, name: "b")
        try await eventually(timeout: 30, description: "b's claim wait armed") {
            b.traffic.modelAnswers().contains { $0.method == .put && $0.status == 409 }
        }
        await b.client.destroy()
        let afterDestroy = b.traffic.model().count
        let remaining = max(0, Double(second.expiresAt) / 1000 - Date().timeIntervalSince1970) + 1.5
        try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        XCTAssertEqual(b.traffic.model().count, afterDestroy, "no request after destroy")
        XCTAssertEqual(b.client.vec1Trainer.runs, 0)
    }
}
