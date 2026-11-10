import XCTest
@testable import JsBaoClient

/// #5230 behaviors 23, 25 to 28 and edge case 47 — an `ann` vector index's
/// shared model through the Swift client, live against the dev server's
/// model routes (no fake transport): every model request a client sends and
/// every answer it gets heard through its pass-through observers.
///
/// - 23: the first device trains, uploads under its claim and installs its
///   own bytes; a second fetches and installs; of three opening at once
///   exactly one trains.
/// - 25: the owner's `deleteModel` moves the revision; every device drops its
///   model and answers exactly; one trains revision 2's, which both install
///   under the `GET` answer's generation and revision; a device offline
///   through it installs revision 2's at its next open; a restart keeps the
///   model and mode, requesting nothing.
/// - 26: a drop and re-registration is a new generation.
/// - 27: `fetchModel`, `uploadModel`, `deleteModel` and their refusals; the
///   listing decodes `vector`, `generation`, `revision` and `annModel`.
/// - 28: a model trained elsewhere installs with no training; one whose
///   params do not match the registration, or with a NaN, is refused and not
///   fetched again; a `bq` model installs.
/// - 47: bytes are installed under the identity their `GET` answer names.
final class Db3VectorSharedModelLiveTests: XCTestCase {

    private typealias V = Db3VectorLive

    private var ctx: TestContext!
    private var live: RecordLogLiveApp!

    override func setUp() async throws {
        ctx = TestContext()
        try await ctx.initialize()
        let app = try await ctx.createTestApp(name: "swift-db3-vector-model-5230")
        live = try RecordLogLiveApp(ctx: ctx, app: app)
    }

    override func tearDown() async throws {
        await live?.destroy()
        await ctx?.cleanup()
    }

    func testTheFirstDeviceTrainsAndUploadsTheModelAndASecondFetchesAndInstallsIt() async throws {
        let id = try await V.seeded(live)
        let index = try await V.register(live, id)
        let generation = try XCTUnwrap(index["generation"] as? Int)
        XCTAssertEqual(index["revision"] as? Int, 1)

        let a = try await V.device(live, id, name: "a")
        let trafficA = a.traffic
        // Exact from the first row; ann once its model is installed and filled.
        XCTAssertEqual(try V.nearest(a.client, id, 7).first?["id"]?.stringValue, V.id(7))
        try await eventually(timeout: 120, description: "device A on its own model") { await V.mode(a.client, id) == .ann }
        let listing = try await V.listed(live, id)
        let uploaded = try XCTUnwrap(listing)
        XCTAssertEqual(uploaded["generation"] as? Int, generation)
        XCTAssertEqual(uploaded["revision"] as? Int, 1)
        let annModel = try XCTUnwrap(uploaded["annModel"] as? [String: Any])
        XCTAssertEqual(annModel["revision"] as? Int, 1)
        XCTAssertEqual(annModel["rows"] as? Int, V.rows)
        XCTAssertEqual(annModel["format"] as? String, "pvm1")
        XCTAssertNotNil(annModel["bytes"] as? Int)
        XCTAssertNotNil(annModel["trainedAt"] as? String)
        // The claim (a PUT with no body and the request header) and the upload (a PUT with the bytes and the five headers).
        let puts = trafficA.model().filter { $0.method == .put }
        XCTAssertGreaterThanOrEqual(puts.count, 2, "\(trafficA.methods())")
        XCTAssertEqual(puts.first?.bodyBytes, 0)
        XCTAssertEqual(puts.last?.bodyBytes, annModel["bytes"] as? Int)
        let answered = trafficA.modelAnswers().filter { $0.method == .put }.compactMap(\.status)
        XCTAssertEqual(answered.first, 202, "the claim: \(answered)")
        XCTAssertEqual(a.client.vec1Trainer.runs, 1)
        let near = try V.nearest(a.client, id, 7)
        XCTAssertEqual(near.first?["id"]?.stringValue, V.id(7))
        XCTAssertEqual(near.count, 10)
        XCTAssertTrue(near.allSatisfy { $0["_distance"]?.numberValue != nil })
        let status = try await V.local(a.client, id)?.status
        XCTAssertEqual(status, .built)

        // A second device fetches the model, and claims and uploads nothing.
        let b = try await V.device(live, id, name: "b")
        let trafficB = b.traffic
        try await eventually(timeout: 120, description: "device B on the shared model") { await V.mode(b.client, id) == .ann }
        XCTAssertEqual(trafficB.methods(), ["GET"])
        XCTAssertEqual(b.client.vec1Trainer.runs, 0)
        let fetchedAnswer = try XCTUnwrap(trafficB.modelAnswers().first)
        XCTAssertEqual(fetchedAnswer.status, 200)
        XCTAssertEqual(fetchedAnswer.headers.first { $0.key.lowercased() == "x-index-model-generation" }?.value, String(generation))
        XCTAssertEqual(fetchedAnswer.headers.first { $0.key.lowercased() == "x-index-model-revision" }?.value, "1")
        XCTAssertEqual(try V.nearest(b.client, id, 300).first?["id"]?.stringValue, V.id(300))
        a.subscription.dispose()
        b.subscription.dispose()
    }

    private func header(_ answer: Db3ModelTraffic.Answer?, _ name: String) -> String? {
        answer?.headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    func testOfThreeDevicesOpeningAtOnceExactlyOneTrainsAndTheOthersFetch() async throws {
        let id = try await V.seeded(live)
        try await V.register(live, id)
        // Three clients subscribe before any is ready: they open at once.
        var clients: [(JsBaoClient, Db3ModelTraffic)] = []
        for name in ["one", "two", "three"] {
            let client = try await live.client(name, models: [V.note])
            clients.append((client, Db3ModelTraffic(client)))
        }
        let subscriptions = try clients.map { try $0.0.db3.subscribe(id) }
        for subscription in subscriptions { try await subscription.ready() }
        let devices = zip(clients, subscriptions).map { (client: $0.0.0, subscription: $0.1, traffic: $0.0.1) }
        for device in devices {
            try await eventually(timeout: 120, description: "every device on the shared model") { await V.mode(device.client, id) == .ann }
        }
        XCTAssertEqual(devices.map(\.client.vec1Trainer.runs).reduce(0, +), 1, "exactly one trained")
        let trainer = try XCTUnwrap(devices.first { $0.client.vec1Trainer.runs == 1 })
        for device in devices where device.client !== trainer.client {
            // Refused the claim (the trainer held it), or the model was listed first: no upload, one fetch.
            XCTAssertFalse(device.traffic.model().contains { $0.method == .put && $0.bodyBytes > 0 }, "\(device.traffic.methods())")
            XCTAssertEqual(device.traffic.methods().filter { $0 == "GET" }.count, 1, "\(device.traffic.methods())")
        }
        for device in devices { device.subscription.dispose() }
    }

    func testTheOwnersDeleteMovesTheRevisionAndOneDeviceTrainsTheNextModel() async throws {
        let id = try await V.seeded(live)
        let index = try await V.register(live, id)
        let generation = try XCTUnwrap(index["generation"] as? Int)
        let a = try await V.device(live, id, name: "a", file: live.file("a"))
        let b = try await V.device(live, id, name: "b")
        let c = try await V.device(live, id, name: "c", file: live.file("c"))
        for device in [a, b, c] {
            try await eventually(timeout: 120, description: "every device on the first model") { await V.mode(device.client, id) == .ann }
        }
        let firstListing = try await V.listed(live, id)
        let first = try XCTUnwrap(firstListing?["annModel"] as? [String: Any])
        // C goes away before the delete: it opens again after the new model is up.
        c.subscription.dispose()
        await c.client.destroy()

        let marks = (a: a.traffic.requests.count, b: b.traffic.requests.count)
        let deleted = try await a.client.db3.indexes.deleteModel(id, name: V.name)
        XCTAssertEqual(deleted, Db3IndexModelDeletion(ok: true, name: V.name, revision: 2))
        // Every device's next list drops its model: exact, with nothing built.
        try await eventually(timeout: 60, description: "both devices to drop the model") {
            let modes = [await V.mode(a.client, id), await V.mode(b.client, id)]
            let relisted = try await V.listed(self.live, id)?["annModel"] != nil
            return modes == [.exact, .exact] || relisted
        }
        // One trains revision 2's model; both install it, under the GET answer's generation and revision.
        try await eventually(timeout: 120, description: "revision 2's model to be uploaded") {
            ((try await V.listed(self.live, id))?["annModel"] as? [String: Any])?["revision"] as? Int == 2
        }
        try await eventually(timeout: 120, description: "both devices on revision 2's model") {
            let (modeA, modeB) = (await V.mode(a.client, id), await V.mode(b.client, id))
            return modeA == .ann && modeB == .ann
        }
        let secondListing = try await V.listed(live, id)
        let second = try XCTUnwrap(secondListing?["annModel"] as? [String: Any])
        XCTAssertNotEqual(second["trainedAt"] as? String, first["trainedAt"] as? String)
        XCTAssertEqual(a.client.vec1Trainer.runs + b.client.vec1Trainer.runs, 2, "the first model and revision 2's: one training each")
        // Revision 2's trainer is the device that uploaded a body after the delete; the other fetched it.
        func uploaded(_ traffic: Db3ModelTraffic, from mark: Int) -> Bool {
            traffic.model(from: mark).contains { $0.method == .put && $0.bodyBytes > 0 }
        }
        let (aUploaded, bUploaded) = (uploaded(a.traffic, from: marks.a), uploaded(b.traffic, from: marks.b))
        XCTAssertNotEqual(aUploaded, bUploaded, "exactly one device uploads revision 2's model")
        let fetcher = aUploaded ? b : a
        let fetched = fetcher.traffic.modelAnswers().filter { $0.method == .get && $0.status == 200 }.last
        XCTAssertEqual(header(fetched, "X-Index-Model-Generation"), String(generation))
        XCTAssertEqual(header(fetched, "X-Index-Model-Revision"), "2")
        let model = try await a.client.db3.indexes.fetchModel(id, name: V.name)
        XCTAssertEqual(model.revision, 2)
        for device in [a, b] { XCTAssertEqual(try V.nearest(device.client, id, 42).first?["id"]?.stringValue, V.id(42)) }

        // C, offline through the delete and the new upload, installs revision 2's at its next open.
        let reopened = try await V.device(live, id, name: "c2", file: live.file("c"))
        try await eventually(timeout: 120, description: "C on revision 2's model") { await V.mode(reopened.client, id) == .ann }
        XCTAssertEqual(reopened.client.vec1Trainer.runs, 0)
        XCTAssertEqual(header(reopened.traffic.modelAnswers().first { $0.method == .get }, "X-Index-Model-Revision"), "2")

        // A restart over A's file keeps the model and mode, training and fetching nothing.
        a.subscription.dispose()
        await a.client.destroy()
        let restarted = try await V.device(live, id, name: "a2", file: live.file("a"))
        let mode = await V.mode(restarted.client, id)
        XCTAssertEqual(mode, .ann)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(restarted.traffic.methods(), [], "no model request after a restart")
        XCTAssertEqual(restarted.client.vec1Trainer.runs, 0)
        XCTAssertEqual(try V.nearest(restarted.client, id, 99).first?["id"]?.stringValue, V.id(99))
        for device in [b, reopened, restarted] { device.subscription.dispose() }
    }

    func testADropAndReRegistrationIsANewGenerationAndNoDeviceInstallsTheOldModel() async throws {
        let id = try await V.seeded(live)
        let first = try await V.register(live, id)
        let firstGeneration = try XCTUnwrap(first["generation"] as? Int)
        let a = try await V.device(live, id, name: "a")
        try await eventually(timeout: 120, description: "the first generation's model") { await V.mode(a.client, id) == .ann }
        let old = try await a.client.db3.indexes.fetchModel(id, name: V.name)

        _ = try await ctx.appRequest(method: "DELETE", appId: live.app.appId, path: "/db3/\(id)/indexes/\(V.name)", body: nil, jwt: live.app.ownerJWT)
        try await eventually(timeout: 30, description: "the device to drop the index") { (try? await V.local(a.client, id)) == nil }
        let again = try await V.register(live, id)
        let generation = try XCTUnwrap(again["generation"] as? Int)
        XCTAssertGreaterThan(generation, firstGeneration)
        XCTAssertEqual(again["revision"] as? Int, 1)
        // The old generation's bytes are refused by the room under the old generation, and installed by no device.
        do {
            _ = try await a.client.db3.indexes.uploadModel(id, name: V.name, bytes: old.bytes, upload: Db3IndexModelUpload(
                generation: firstGeneration, revision: 1, rows: old.rows, trainedAt: old.trainedAt
            ))
            XCTFail("an upload naming the old generation was taken")
        } catch let error as HttpError {
            XCTAssertEqual(error.serverCode, JsBaoErrorCode.db3IndexGenerationStale.rawValue)
            XCTAssertEqual(JsBaoErrorCode(rawValue: error.serverCode ?? ""), .db3IndexGenerationStale)
        }
        let staleInstall = try live.binding(a.client, id).store.installVectorModel(
            V.name, generation: firstGeneration, revision: 1, bytes: old.bytes, source: "shared"
        )
        XCTAssertEqual(staleInstall.outcome, .stale)
        try await eventually(timeout: 120, description: "the new generation's model, trained and listed") {
            let listedModel = try await V.listed(self.live, id)?["annModel"] != nil
            let mode = await V.mode(a.client, id)
            return listedModel && mode == .ann
        }
        let model = try await a.client.db3.indexes.fetchModel(id, name: V.name)
        XCTAssertEqual(model.generation, generation)
        XCTAssertEqual(try V.nearest(a.client, id, 99).first?["id"]?.stringValue, V.id(99))
        a.subscription.dispose()
    }

    func testThePublicModelApiAndItsRefusals() async throws {
        let id = try await V.seeded(live)
        let index = try await V.register(live, id)
        let generation = try XCTUnwrap(index["generation"] as? Int)
        let owner = try await live.client("owner", models: [V.note])
        // No model yet.
        do {
            _ = try await owner.db3.indexes.deleteModel(id, name: V.name)
            XCTFail("a delete with no model was taken")
        } catch let error as HttpError {
            XCTAssertEqual(JsBaoErrorCode(rawValue: error.serverCode ?? ""), .db3IndexModelNotFound)
        }
        do {
            _ = try await owner.db3.indexes.fetchModel(id, name: V.name)
            XCTFail("a fetch with no model was taken")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 404)
        }
        // An empty body, and one over 64 MiB.
        let trainedAt = Date(timeIntervalSince1970: 1_793_000_000.123)
        let upload = Db3IndexModelUpload(generation: generation, revision: 1, rows: V.rows, trainedAt: trainedAt)
        for (bytes, code) in [(Data(), JsBaoErrorCode.db3IndexModelInvalid), (Data(count: 64 * 1024 * 1024 + 1), .db3IndexModelTooLarge)] {
            do {
                _ = try await owner.db3.indexes.uploadModel(id, name: V.name, bytes: bytes, upload: upload)
                XCTFail("\(code) was taken")
            } catch let error as HttpError {
                XCTAssertEqual(JsBaoErrorCode(rawValue: error.serverCode ?? ""), code, error.body ?? "")
            }
        }
        // An upload of the app's own: the listing answers its annModel.
        let bytes = try V.trainedElsewhere()
        let listed = try await owner.db3.indexes.uploadModel(id, name: V.name, bytes: bytes, upload: upload)
        XCTAssertEqual(listed.annModel?.revision, 1)
        XCTAssertEqual(listed.annModel?.bytes, bytes.count)
        XCTAssertEqual(listed.annModel?.rows, V.rows)
        XCTAssertEqual(listed.annModel?.format, "pvm1")
        XCTAssertEqual(listed.annModel.map { abs($0.trainedAt.timeIntervalSince(trainedAt)) < 0.001 }, true)
        XCTAssertEqual(listed.generation, generation)
        XCTAssertEqual(listed.revision, 1)
        XCTAssertEqual(listed.vector, Db3VectorIndex(distance: .cos, index: .ann(), dims: V.dims, element: .f32))
        // The same bytes again; another generation.
        for (upload, code) in [
            (upload, JsBaoErrorCode.db3IndexModelExists),
            (Db3IndexModelUpload(generation: generation + 99, revision: 1, rows: V.rows, trainedAt: trainedAt), .db3IndexGenerationStale),
        ] {
            do {
                _ = try await owner.db3.indexes.uploadModel(id, name: V.name, bytes: bytes, upload: upload)
                XCTFail("\(code) was taken")
            } catch let error as HttpError {
                XCTAssertEqual(JsBaoErrorCode(rawValue: error.serverCode ?? ""), code, error.body ?? "")
            }
        }
        // fetchModel answers the bytes and the metadata the GET answer's headers carry.
        let fetched = try await owner.db3.indexes.fetchModel(id, name: V.name)
        XCTAssertEqual(fetched.bytes, bytes)
        XCTAssertEqual(fetched.generation, generation)
        XCTAssertEqual(fetched.revision, 1)
        XCTAssertEqual(fetched.rows, V.rows)
        XCTAssertEqual(fetched.format, "pvm1")
        XCTAssertEqual(fetched.trainedAt, listed.annModel?.trainedAt)
        let raw = try await V.modelRoute(live, id, method: "GET")
        XCTAssertEqual(raw.headers.first { $0.key.lowercased() == "content-length" }?.value, String(bytes.count))
        // list decodes every vector field; local lists mode.
        let all = try await owner.db3.indexes.list(id)
        let entry = try XCTUnwrap(all.first { $0.name == V.name })
        XCTAssertEqual(entry.annModel, listed.annModel)
        XCTAssertEqual(entry.vector, listed.vector)
        let subscription = try owner.db3.subscribe(id)
        try await subscription.ready()
        try await eventually(timeout: 60, description: "the owner's device on the app's model") { await V.mode(owner, id) == .ann }
        // A reader may not delete.
        let reader = try await ctx.createTestUser(appId: live.app.appId)
        _ = try await ctx.appRequest(
            method: "PUT", appId: live.app.appId, path: "/documents/\(id)/permissions", body: ["userId": reader.userId, "permission": "reader"],
            jwt: live.app.ownerJWT
        )
        let readerClient = try await live.client("reader", models: [V.note], token: reader.jwt)
        do {
            _ = try await readerClient.db3.indexes.deleteModel(id, name: V.name)
            XCTFail("a reader's delete was taken")
        } catch let error as HttpError {
            XCTAssertEqual(error.status, 403)
        }
        let readerFetch = try await readerClient.db3.indexes.fetchModel(id, name: V.name)
        XCTAssertEqual(readerFetch.bytes, bytes)
        // A local-only db3: all three are its own.
        let local = try await owner.db3.create(title: "Local", localOnly: true)
        for call in ["fetch", "upload", "delete"] {
            do {
                switch call {
                case "fetch": _ = try await owner.db3.indexes.fetchModel(local.id, name: V.name)
                case "upload": _ = try await owner.db3.indexes.uploadModel(local.id, name: V.name, bytes: bytes, upload: upload)
                default: _ = try await owner.db3.indexes.deleteModel(local.id, name: V.name)
                }
                XCTFail("\(call) on a local-only db3 was taken")
            } catch let error as JsBaoError {
                XCTAssertEqual(error.code, .db3LocalOnly, call)
            }
        }
        subscription.dispose()
    }

    func testAModelTrainedElsewhereInstallsAndOneThatDoesNotMatchIsRefusedOnce() async throws {
        let id = try await V.seeded(live)
        let index = try await V.register(live, id, [
            "model": V.model, "field": "embedding", "kind": "vector", "on": "device",
            "vector": ["distance": "cos", "index": ["mode": "ann", "nbucket": 30]],
        ])
        let generation = try XCTUnwrap(index["generation"] as? Int)
        let owner = try await live.client("owner", models: [])
        let upload = { (revision: Int) in Db3IndexModelUpload(generation: generation, revision: revision, rows: V.rows, trainedAt: Date()) }
        // Another nbucket than the registration states: stored by the server, refused by the device.
        _ = try await owner.db3.indexes.uploadModel(id, name: V.name, bytes: try V.trainedElsewhere(nbucket: 24), upload: upload(1))
        let a = try await V.device(live, id, name: "a")
        try await eventually(timeout: 60, description: "the device to refuse the model") {
            RecordLogIndexes.optionsOf(try XCTUnwrap(try self.live.binding(a.client, id).store.readView {
                try RecordLogIndexes.cachedVectorRows($0, documentId: id).first
            }))["refused"] != nil
        }
        let refusedMode = await V.mode(a.client, id)
        XCTAssertEqual(refusedMode, .exact)
        XCTAssertEqual(a.client.vec1Trainer.runs, 0)
        XCTAssertEqual(a.traffic.methods(), ["GET"])
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(a.traffic.methods(), ["GET"], "not fetched again at that revision")
        XCTAssertEqual(try V.nearest(a.client, id, 3).first?["id"]?.stringValue, V.id(3))
        // A NaN coefficient: refused likewise.
        _ = try await owner.db3.indexes.deleteModel(id, name: V.name)
        var nan = try V.trainedElsewhere(nbucket: 30)
        nan.replaceSubrange((nan.count - 4)..<nan.count, with: [0x00, 0x00, 0xc0, 0x7f])
        // The device trains revision 2's own model unless one is listed first: the app uploads before it can.
        _ = try? await owner.db3.indexes.uploadModel(id, name: V.name, bytes: nan, upload: upload(2))
        try await eventually(timeout: 120, description: "the NaN model refused, or the device's own model in place") {
            let options = RecordLogIndexes.optionsOf(try XCTUnwrap(try self.live.binding(a.client, id).store.readView {
                try RecordLogIndexes.cachedVectorRows($0, documentId: id).first
            }))
            return (options["refused"]?["revision"] == 2 && options["refused"]?["reason"]?.stringValue?.contains("not finite") == true)
                || options["ann"]?["revision"] == 2
        }
        // A genuine model of the registration's params installs with no training.
        _ = try await owner.db3.indexes.deleteModel(id, name: V.name)
        _ = try? await owner.db3.indexes.uploadModel(id, name: V.name, bytes: try V.trainedElsewhere(nbucket: 30), upload: upload(3))
        try await eventually(timeout: 120, description: "the device on revision 3's model") {
            let mode = await V.mode(a.client, id)
            let revision = (try await V.listed(self.live, id)?["annModel"] as? [String: Any])?["revision"] as? Int
            return mode == .ann && revision == 3
        }
        a.subscription.dispose()
    }

    func testABqModelUploadedElsewhereInstalls() async throws {
        let id = try await V.seeded(live)
        let index = try await V.register(live, id, [
            "model": V.model, "field": "embedding", "kind": "vector", "on": "device",
            "vector": ["distance": "cos", "index": ["mode": "ann", "quantizer": "bq"]],
        ])
        let generation = try XCTUnwrap(index["generation"] as? Int)
        let owner = try await live.client("owner", models: [])
        _ = try await owner.db3.indexes.uploadModel(
            id, name: V.name, bytes: try V.trainedElsewhere(nbucket: 35, codesize: RecordLogVectorModelCheck.bqCodesize(dims: V.dims), quantizer: "bq"),
            upload: Db3IndexModelUpload(generation: generation, revision: 1, rows: V.rows, trainedAt: Date())
        )
        let a = try await V.device(live, id, name: "a")
        try await eventually(timeout: 120, description: "the device on the bq model") { await V.mode(a.client, id) == .ann }
        XCTAssertEqual(a.client.vec1Trainer.runs, 0)
        XCTAssertFalse(a.traffic.model().contains { $0.method == .put })
        for at in [5, 600, 1150] { XCTAssertEqual(try V.nearest(a.client, id, at, k: 5).first?["id"]?.stringValue, V.id(at)) }
        a.subscription.dispose()
    }

    func testAListingThatMovesDuringAFetchInstallsTheBytesUnderTheirAnswersIdentity() async throws {
        let id = try await V.seeded(live)
        let index = try await V.register(live, id)
        let generation = try XCTUnwrap(index["generation"] as? Int)
        let owner = try await live.client("owner", models: [])
        let upload = { (revision: Int) in Db3IndexModelUpload(generation: generation, revision: revision, rows: V.rows, trainedAt: Date()) }
        _ = try await owner.db3.indexes.uploadModel(id, name: V.name, bytes: try V.trainedElsewhere(), upload: upload(1))
        // The device caches revision 1's listing and its model; its installed model is then dropped, so it wants revision 1's again.
        let file = live.file("moving")
        let first = try await V.device(live, id, name: "first", file: file)
        try await eventually(timeout: 60, description: "revision 1's model installed") { await V.mode(first.client, id) == .ann }
        try live.binding(first.client, id).store.invalidateVectorModel(V.name)
        first.subscription.dispose()
        await first.client.destroy()
        // Meanwhile the owner deletes it and revision 2's is uploaded.
        _ = try await owner.db3.indexes.deleteModel(id, name: V.name)
        let revision2 = try V.trainedElsewhere(nbucket: 34)
        _ = try await owner.db3.indexes.uploadModel(id, name: V.name, bytes: revision2, upload: upload(2))
        // Reopened with its index-list read held: it fetches from the cached revision 1 listing, and the answer is revision 2's.
        let gate = RecordLogReceiptHarness.Gate()
        let device = try await live.client("moving", models: [V.note], file: file)
        device.db3IndexReadHoldForTest = { _ in await gate.wait() }
        let traffic = Db3ModelTraffic(device)
        let subscription = try device.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(timeout: 60, description: "the fetch's answer") { traffic.modelAnswers().contains { $0.method == .get && $0.status == 200 } }
        let answer = traffic.modelAnswers().first { $0.method == .get && $0.status == 200 }
        XCTAssertEqual(header(answer, "X-Index-Model-Revision"), "2")
        try await eventually(timeout: 30, description: "revision 2's model installed under its answer's identity") {
            RecordLogIndexes.optionsOf(try XCTUnwrap(try self.live.binding(device, id).store.readView {
                try RecordLogIndexes.cachedVectorRows($0, documentId: id).first
            }))["ann"]?["revision"] == 2
        }
        gate.open()
        try await subscription.ready()
        try await eventually(timeout: 30, description: "listed and built ann") { await V.mode(device, id) == .ann }
        XCTAssertEqual(traffic.methods(), ["GET"], "no stale install, no second fetch")

        // A GET answering another generation than the cached entry's installs nothing, and the list is read again.
        subscription.dispose()
        await device.destroy()
        _ = try await ctx.appRequest(method: "DELETE", appId: live.app.appId, path: "/db3/\(id)/indexes/\(V.name)", body: nil, jwt: live.app.ownerJWT)
        let again = try await V.register(live, id)
        let next = try XCTUnwrap(again["generation"] as? Int)
        _ = try await owner.db3.indexes.uploadModel(id, name: V.name, bytes: try V.trainedElsewhere(), upload: Db3IndexModelUpload(
            generation: next, revision: 1, rows: V.rows, trainedAt: Date()
        ))
        // Its store still caches the old generation, its model dropped so a fetch is wanted.
        let plant = try await live.client("plant", models: [V.note], file: file)
        plant.db3IndexReadHoldForTest = { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
        let planted = try plant.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(timeout: 30, description: "the old generation bound") { plant.isRecordLogDocument(id) }
        try live.binding(plant, id).store.invalidateVectorModel(V.name)
        planted.dispose()
        await plant.destroy()
        let held = RecordLogReceiptHarness.Gate()
        let late = try await live.client("late", models: [V.note], file: file)
        let lateTraffic = Db3ModelTraffic(late)
        late.db3IndexReadHoldForTest = { _ in await held.wait() }
        let lateSubscription = try late.db3.subscribe(id, options: Db3SubscribeOptions(readyTimeout: .infinity))
        try await eventually(timeout: 60, description: "the fetch of the old generation's listing") {
            lateTraffic.modelAnswers().contains { $0.method == .get && $0.status == 200 }
        }
        XCTAssertEqual(header(lateTraffic.modelAnswers().first { $0.method == .get }, "X-Index-Model-Generation"), String(next))
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(RecordLogIndexes.optionsOf(try XCTUnwrap(try live.binding(late, id).store.readView {
            try RecordLogIndexes.cachedVectorRows($0, documentId: id).first
        }))["ann"], "nothing installed under the old generation")
        held.open()
        try await lateSubscription.ready()
        try await eventually(timeout: 60, description: "the new generation's model installed after the list is read again") {
            await V.mode(late, id) == .ann
        }
        let generations = lateTraffic.modelAnswers().filter { $0.method == .get }.compactMap { header($0, "X-Index-Model-Generation") }
        XCTAssertEqual(Set(generations), [String(next)])
        lateSubscription.dispose()
    }

}
