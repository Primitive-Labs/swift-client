import Foundation

/// What the model loop needs of the client (#5230), js-bao's `Db3VectorModelsDeps`.
struct Db3VectorModelsDeps: Sendable {
    /// What a bound db3's `ann` vector entries want; `nil` when it is not bound.
    var wants: @Sendable (String) async throws -> [RecordLogVectorWant]?
    /// The sample a training run reads; `nil` when the db3 is not bound or another run's mark holds.
    var sample: @Sendable (String, String) async throws -> RecordLogVectorSample?
    /// A training run ended without a model.
    var releaseTraining: @Sendable (String, String) async throws -> Void
    /// Install a model in the db3's store: name, generation, revision, bytes, source.
    var install: @Sendable (String, String, Int?, Int?, Data, String) async throws -> RecordLogVectorInstall?
    /// What trains a model off the store's queue.
    var trainer: RecordLogVec1Trainer
    /// The model routes, as each request reaches them.
    var http: @Sendable () -> Db3IndexModelHttp
    /// Whether the db3 lives only on this device.
    var localOnly: @Sendable (String) -> Bool
    /// Whether the db3's session is live.
    var live: @Sendable (String) -> Bool
    /// Whether the client is online with its socket open.
    var online: @Sendable () -> Bool
    /// Ask for the db3's index list again: what it lists decides the next want.
    var refreshList: @Sendable (String) -> Void
    var setTimer: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> any RecordLogIndexTimer = { delay, fire in
        RecordLogIndexTaskTimer(after: delay, fire)
    }
    var logger: Logger?
}

/// The client's work on its db3s' shared ANN models (#5230), the Swift port
/// of the JS client's `db3VectorModels.ts`: for each `ann` vector index a
/// bound db3's store wants a model for, fetch the one its room lists, or
/// train one, once per index at a time.
///
/// - `fetch`: `GET …/model`, then the store checks the envelope and installs
///   it under the generation and revision the answer's headers name (its ANN
///   table fills in the background; `$near` answers exactly meanwhile). A
///   body that ends early installs nothing and is fetched again.
/// - `train` on a synced db3: the upload is claimed first, so one device of
///   the db3 trains per revision; a claim another device holds is waited out
///   (its expiry, + 250 ms, runs the loop); a model already listed, or a
///   revision moved on, reads the list again. The claimant reads the store's
///   sample, trains it off the store's queue (renewing its claim every five
///   minutes while it trains), uploads the model under its claim and
///   installs its own bytes. A training that fails gives the claim back;
///   bytes whose upload did not reach the server are kept and uploaded when
///   the loop runs again (its retry timer, the db3 going live, or networking
///   allowed again), or dropped when the server refuses them or the room
///   lists a model.
/// - `train` on a db3 that lives only on this device: trained and installed
///   here, with no request.
///
/// A failure the server did not answer, a 5xx, a timeout or a rate limit is
/// tried again after 1 s, doubling to 10 s. The loop runs for a synced db3
/// only while it is live and the client online.
///
/// A job holds the ``Ticket`` it began under. ``forget(_:)`` (its db3
/// unbound), ``forgetAll()`` (the user changed) and ``destroy()`` end every
/// ticket they cover: a job whose ticket ended sends no request, runs no
/// store command and keeps no bytes from then on, so nothing one user or
/// binding began reaches another's credentials or store. Its claim and its
/// training mark lapse on their own (a claim's 15 minutes; the store wakes its
/// wants at the mark's lapse).
///
/// `@unchecked Sendable`: every mutable property is read and written under
/// `lock`, which is never held across a call out of this class.
final class Db3VectorModels: @unchecked Sendable {

    /// Bytes a training produced whose upload did not reach the server, kept for the next run.
    struct Retained: Sendable {
        var bytes: Data
        var generation: Int
        var revision: Int
        var token: String
        var rows: Int
        var trainedAt: String
    }

    /// What a job began under: its db3's binding and the client's user, as
    /// they stood. A job asks ``current(_:)`` after every wait before it
    /// sends, writes or keeps anything.
    struct Ticket: Sendable {
        var documentId: String
        var epoch: Int
        var binding: Int
    }

    private struct Retry {
        var timer: (any RecordLogIndexTimer)?
        var delay: TimeInterval
        var want: RecordLogVectorWant.Kind
    }

    private let deps: Db3VectorModelsDeps
    private let lock = NSLock()
    private var jobs: [String: UUID] = [:]
    private var retries: [String: Retry] = [:]
    /// Claims another device holds, by index: the loop runs again at their expiry.
    private var waits: [String: any RecordLogIndexTimer] = [:]
    private var retained: [String: Retained] = [:]
    /// db3s whose wants were heard while one of their jobs ran: the loop runs again for them when it ends.
    private var heardWhileBusy = Set<String>()
    private var destroyed = false
    /// Moved on by ``forgetAll()`` and ``destroy()``: every ticket before it ended.
    private var epoch = 0
    /// Moved on by ``forget(_:)``, by db3: its tickets before it ended.
    private var bindings: [String: Int] = [:]

    init(deps: Db3VectorModelsDeps) {
        self.deps = deps
    }

    private static func key(_ documentId: String, _ name: String) -> String { "\(documentId)\u{0}\(name)" }

    /// Whether a job of `documentId`'s `name` is under way (a test's view).
    func busy(_ documentId: String, _ name: String) -> Bool { lock.withLock { jobs[Self.key(documentId, name)] != nil } }

    /// The bytes kept for `documentId`'s `name` (a test's view).
    func retainedBytes(_ documentId: String, _ name: String) -> Data? { lock.withLock { retained[Self.key(documentId, name)]?.bytes } }

    /// A ticket for a job of `documentId` beginning now.
    func ticket(_ documentId: String) -> Ticket {
        lock.withLock { Ticket(documentId: documentId, epoch: epoch, binding: bindings[documentId] ?? 0) }
    }

    /// Whether `ticket`'s job may still send, write or keep anything: the
    /// client not destroyed, its user and its db3's binding the ones it began under.
    func current(_ ticket: Ticket) -> Bool {
        lock.withLock { holds(ticket) }
    }

    /// What `documentId`'s store wants may have changed: start a job for each want with none under way.
    func run(_ documentId: String) async {
        if lock.withLock({ destroyed }) { return }
        let ticket = ticket(documentId)
        let localOnly = deps.localOnly(documentId)
        if !localOnly && (!deps.live(documentId) || !deps.online()) { return }
        let wants: [RecordLogVectorWant]
        do {
            guard let read = try await deps.wants(documentId) else { return }
            wants = read
        } catch {
            deps.logger?.debug("[db3] \(documentId): the vector indexes' wants were not read: \(RecordLogIndexes.message(error))")
            return
        }
        // Unbound, signed out or destroyed while the wants were read: they are another binding's now.
        guard current(ticket) else { return }
        for want in wants {
            let key = Self.key(documentId, want.name)
            enum Step { case skip, busy, start }
            let (step, cancelled) = lock.withLock { () -> (Step, [any RecordLogIndexTimer]) in
                var cancelled: [any RecordLogIndexTimer] = []
                // The room lists a model now: bytes kept for an upload are not wanted.
                if want.want == .fetch { retained[key] = nil }
                // A wait on another device's claim, or a retry, is for the want it was armed for: a new want ends it.
                if want.want != .train, let wait = waits.removeValue(forKey: key) { cancelled.append(wait) }
                if let retry = retries[key], retry.want != want.want {
                    if let timer = retry.timer { cancelled.append(timer) }
                    retries[key] = nil
                }
                if jobs[key] != nil {
                    // What the store wants may have moved past what the job does: asked again once it ends.
                    heardWhileBusy.insert(documentId)
                    return (.busy, cancelled)
                }
                if waits[key] != nil || retries[key]?.timer != nil { return (.skip, cancelled) }
                return (.start, cancelled)
            }
            for timer in cancelled { timer.cancel() }
            guard step == .start else { continue }
            track(key, ticket) {
                switch want.want {
                case .fetch: await self.fetch(ticket, want)
                case .train where localOnly: await self.trainLocal(ticket, want)
                case .train: await self.trainShared(ticket, want)
                }
            }
        }
        // Kept bytes are uploaded again whatever the store wants: it wants nothing of an index while its training is marked.
        let kept = lock.withLock { retained.filter { $0.key.hasPrefix("\(documentId)\u{0}") && jobs[$0.key] == nil && retries[$0.key]?.timer == nil } }
        for (key, bytes) in kept {
            let name = String(key.dropFirst(documentId.count + 1))
            if wants.contains(where: { $0.name == name }) { continue }
            track(key, ticket) { _ = await self.upload(ticket, name, bytes) }
        }
    }

    /// Run `body` as `key`'s job under `ticket`; once it ends, the loop runs
    /// again for its db3 when its wants were heard meanwhile and the ticket still holds.
    private func track(_ key: String, _ ticket: Ticket, _ body: @escaping @Sendable () async -> Void) {
        let token = UUID()
        let documentId = ticket.documentId
        lock.withLock { jobs[key] = token }
        Task { [weak self] in
            await body()
            guard let self else { return }
            let mine = self.current(ticket)
            let again = self.lock.withLock { () -> Bool in
                if self.jobs[key] == token { self.jobs[key] = nil }
                return mine && self.heardWhileBusy.remove(documentId) != nil && !self.destroyed
            }
            if again { await self.run(documentId) }
        }
    }

    /// Every job ends where it stands, and no timer runs.
    func destroy() {
        let timers = lock.withLock { () -> [any RecordLogIndexTimer] in
            destroyed = true
            epoch += 1
            defer {
                retries = [:]
                waits = [:]
                retained = [:]
                jobs = [:]
                heardWhileBusy = []
            }
            return retries.values.compactMap(\.timer) + Array(waits.values)
        }
        for timer in timers { timer.cancel() }
    }

    /// Every db3 was unbound (the user changed): every job ends where it
    /// stands, and every wait, retry and kept bytes go.
    func forgetAll() {
        let timers = lock.withLock { () -> [any RecordLogIndexTimer] in
            epoch += 1
            defer {
                retries = [:]
                waits = [:]
                retained = [:]
                jobs = [:]
                heardWhileBusy = []
            }
            return retries.values.compactMap(\.timer) + Array(waits.values)
        }
        for timer in timers { timer.cancel() }
    }

    /// A db3 was unbound: its jobs end where they stand, and its waits,
    /// retries and kept bytes go.
    func forget(_ documentId: String) {
        let prefix = "\(documentId)\u{0}"
        let timers = lock.withLock { () -> [any RecordLogIndexTimer] in
            bindings[documentId, default: 0] += 1
            heardWhileBusy.remove(documentId)
            for key in jobs.keys where key.hasPrefix(prefix) { jobs[key] = nil }
            var out: [any RecordLogIndexTimer] = []
            for key in retries.keys where key.hasPrefix(prefix) { if let timer = retries.removeValue(forKey: key)?.timer { out.append(timer) } }
            for key in waits.keys where key.hasPrefix(prefix) { if let timer = waits.removeValue(forKey: key) { out.append(timer) } }
            for key in retained.keys where key.hasPrefix(prefix) { retained[key] = nil }
            return out
        }
        for timer in timers { timer.cancel() }
    }

    /// Whether `ticket` still holds; asked under `lock`.
    private func holds(_ ticket: Ticket) -> Bool {
        !destroyed && epoch == ticket.epoch && (bindings[ticket.documentId] ?? 0) == ticket.binding
    }

    private func retry(_ ticket: Ticket, _ name: String, _ want: RecordLogVectorWant.Kind) {
        let documentId = ticket.documentId
        let key = Self.key(documentId, name)
        let delay = lock.withLock { () -> TimeInterval? in
            guard holds(ticket) else { return nil }
            var retry = retries[key] ?? Retry(timer: nil, delay: RecordLogIndexRefresher.retryInitial, want: want)
            guard retry.timer == nil else { return nil }
            let delay = retry.delay
            retry.delay = min(retry.delay * 2, RecordLogIndexRefresher.retryMax)
            retries[key] = retry
            return delay
        }
        guard let delay else { return }
        deps.logger?.debug("[db3] \(documentId): \(name)'s model work is tried again in \(delay) s")
        let timer = deps.setTimer(delay) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.retries[key]?.timer = nil }
            Task { await self.run(documentId) }
        }
        lock.withLock {
            if retries[key] != nil && holds(ticket) { retries[key]?.timer = timer } else { timer.cancel() }
        }
    }

    private func succeeded(_ ticket: Ticket, _ name: String) {
        let timer = lock.withLock { holds(ticket) ? retries.removeValue(forKey: Self.key(ticket.documentId, name))?.timer : nil }
        timer?.cancel()
    }

    /// Run the loop again once another device's claim lapses.
    private func waitFor(_ ticket: Ticket, _ name: String, expiresAt: Int64) {
        let documentId = ticket.documentId
        let key = Self.key(documentId, name)
        let delay = max(1, (Double(expiresAt) - Date().timeIntervalSince1970 * 1000 + 250) / 1000)
        let timer = deps.setTimer(delay) { [weak self] in
            guard let self else { return }
            self.lock.withLock { _ = self.waits.removeValue(forKey: key) }
            Task { await self.run(documentId) }
        }
        let (prior, armed) = lock.withLock { () -> ((any RecordLogIndexTimer)?, Bool) in
            guard holds(ticket) else { return (nil, false) }
            defer { waits[key] = timer }
            return (waits[key], true)
        }
        prior?.cancel()
        if !armed { timer.cancel() }
    }

    /// Ask for `ticket`'s db3's list again, while the ticket holds.
    private func refreshList(_ ticket: Ticket) {
        if current(ticket) { deps.refreshList(ticket.documentId) }
    }

    private func fetch(_ ticket: Ticket, _ want: RecordLogVectorWant) async {
        let documentId = ticket.documentId
        let model: Db3IndexModelHttp.Fetched
        do {
            model = try await deps.http().fetch(documentId, want.name)
        } catch {
            guard current(ticket) else { return }
            if (error as? HttpError)?.status == 404 {
                // Listed and gone: the list says what is wanted now.
                refreshList(ticket)
                return
            }
            deps.logger?.debug("[db3] \(documentId): the model of \(want.name) was not fetched: \(RecordLogIndexes.message(error))")
            if Db3IndexModelHttp.retryable(error) { retry(ticket, want.name, .fetch) }
            return
        }
        // Unbound, signed out or destroyed while the bytes came: they are installed in no other binding.
        guard current(ticket) else { return }
        // Another generation's bytes (the index dropped and registered again meanwhile): the list says what is wanted now.
        if model.generation != want.generation {
            refreshList(ticket)
            return
        }
        let installed: RecordLogVectorInstall?
        do {
            installed = try await deps.install(documentId, want.name, model.generation, model.revision, model.bytes, "shared")
        } catch {
            deps.logger?.debug("[db3] \(documentId): the model of \(want.name) was not installed: \(RecordLogIndexes.message(error))")
            return
        }
        guard current(ticket) else { return }
        switch installed?.outcome {
        case .stale?:
            // The entry moved on while the model came: what it wants now is asked once this job ends.
            lock.withLock { _ = heardWhileBusy.insert(documentId) }
        case .failed?:
            // The device's storage failed the install (a full disk): fetched and installed again on the backoff.
            retry(ticket, want.name, .fetch)
        default:
            succeeded(ticket, want.name)
            if installed?.outcome == .building {
                deps.logger?.log("[db3] \(documentId): installing the shared model of \(want.name) (revision \(model.revision))")
            }
        }
    }

    private func trainLocal(_ ticket: Ticket, _ want: RecordLogVectorWant) async {
        guard let trained = await trained(ticket, want.name), current(ticket) else { return }
        let installed = try? await deps.install(ticket.documentId, want.name, nil, nil, trained.bytes, "local")
        guard current(ticket) else { return }
        // The device's storage failed the install: its training mark went, and it trains again on the backoff.
        if installed?.outcome == .failed { return retry(ticket, want.name, .train) }
        succeeded(ticket, want.name)
    }

    /// Read the sample and train it; `nil` (and the training released) when
    /// it could not, or `nil` alone once `ticket` no longer holds.
    private func trained(_ ticket: Ticket, _ name: String) async -> (bytes: Data, rows: Int, trainedAt: String)? {
        let documentId = ticket.documentId
        guard current(ticket) else { return nil }
        let sample: RecordLogVectorSample?
        do {
            sample = try await deps.sample(documentId, name)
        } catch {
            guard current(ticket) else { return nil }
            deps.logger?.debug("[db3] \(documentId): \(name)'s training sample was not read: \(RecordLogIndexes.message(error))")
            retry(ticket, name, .train)
            return nil
        }
        guard let sample, current(ticket) else { return nil }
        let started = Date()
        do {
            // Waits its turn behind another index's training; trains nothing once the ticket ended.
            let result = try await deps.trainer.train(sample) { [weak self] in self?.current(ticket) ?? false }
            guard current(ticket) else { return nil }
            let trainedAt = Db3IndexesAPI.isoDate(Date())
            let params = RecordLogVectorModelParams(
                vec1: result.vec1, dims: sample.dims, distance: sample.distance, nbucket: sample.params.nbucket, codesize: sample.params.codesize,
                quantizer: sample.params.quantizer, rows: sample.rows, trainedAt: trainedAt
            )
            deps.logger?.log(
                "[db3] \(documentId): trained \(name)'s model over \(sample.count) of \(sample.rows) rows in \(Int(Date().timeIntervalSince(started) * 1000)) ms"
            )
            return (RecordLogVectorModelCheck.encode(params, model: result.model), sample.rows, trainedAt)
        } catch {
            guard current(ticket) else { return nil }
            deps.logger?.warn(
                "[db3] \(documentId): training \(name)'s model failed: \(RecordLogIndexes.message(error)); $near on it answers exactly, and it is tried again later"
            )
            try? await deps.releaseTraining(documentId, name)
            retry(ticket, name, .train)
            return nil
        }
    }

    private func trainShared(_ ticket: Ticket, _ want: RecordLogVectorWant) async {
        let documentId = ticket.documentId
        let name = want.name
        guard let generation = want.generation, let revision = want.revision else { return }
        let key = Self.key(documentId, name)
        let kept = lock.withLock { () -> Retained? in
            if let kept = retained[key], kept.generation != generation {
                retained[key] = nil
                return nil
            }
            return retained[key]
        }
        if let kept {
            // Uploaded (or refused for good), or kept again after another dropped connection.
            _ = await upload(ticket, name, kept)
            return
        }
        guard current(ticket) else { return }
        let claim: Db3IndexModelHttp.Claim
        do {
            claim = try await deps.http().claim(documentId, name, generation: generation, revision: revision).claim
        } catch {
            guard current(ticket) else { return }
            let code = Db3IndexModelHttp.code(error)
            let details = Db3IndexModelHttp.details(error)
            if code == JsBaoErrorCode.db3IndexModelExists.rawValue, details["pending"] == true, let expiresAt = details["expiresAt"]?.numberValue {
                deps.logger?.debug("[db3] \(documentId): another device trains \(name)'s model; this one answers exactly meanwhile")
                waitFor(ticket, name, expiresAt: Int64(expiresAt))
                return
            }
            if [JsBaoErrorCode.db3IndexModelExists, .db3IndexModelStale, .db3IndexGenerationStale].map(\.rawValue).contains(code) {
                refreshList(ticket)
                return
            }
            deps.logger?.debug("[db3] \(documentId): \(name)'s model was not claimed: \(RecordLogIndexes.message(error))")
            // A refusal of the user (a reader's 403) is not asked again until the list or the session changes.
            if Db3IndexModelHttp.retryable(error) { retry(ticket, name, .train) }
            return
        }
        // Renewed while the training runs, so no other device takes it over; never once the ticket ended.
        let renewal = Task { [weak self, deps] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(RecordLogVectorIndex.renewSeconds * 1_000_000_000))
                if Task.isCancelled || self?.current(ticket) != true { return }
                do {
                    _ = try await deps.http().claim(documentId, name, generation: generation, revision: claim.revision, token: claim.token)
                } catch {
                    deps.logger?.debug("[db3] \(documentId): \(name)'s claim was not renewed: \(RecordLogIndexes.message(error))")
                }
            }
        }
        let trained = await trained(ticket, name)
        renewal.cancel()
        // Signed out, unbound or destroyed meanwhile: the claim lapses on its own, under no other user's credentials.
        guard current(ticket) else { return }
        guard let trained else {
            try? await deps.http().release(documentId, name, token: claim.token)
            return
        }
        _ = await upload(ticket, name, Retained(
            bytes: trained.bytes, generation: generation, revision: claim.revision, token: claim.token, rows: trained.rows, trainedAt: trained.trainedAt
        ))
    }

    /// Upload trained bytes under their claim and install them; `true` once that is settled either way but a dropped connection.
    private func upload(_ ticket: Ticket, _ name: String, _ kept: Retained) async -> Bool {
        let documentId = ticket.documentId
        let key = Self.key(documentId, name)
        guard current(ticket) else { return true }
        do {
            _ = try await deps.http().upload(documentId, name, bytes: kept.bytes, Db3IndexModelHttp.Metadata(
                generation: kept.generation, revision: kept.revision, rows: kept.rows, trainedAt: kept.trainedAt, format: RecordLogVectorModelCheck.format
            ), token: kept.token)
        } catch {
            if Db3IndexModelHttp.isOffline(error) || Db3IndexModelHttp.retryable(error) {
                // Kept for this binding only: bytes the ticket outlived are handed to no other.
                guard lock.withLock({ () -> Bool in
                    guard holds(ticket) else { return false }
                    retained[key] = kept
                    return true
                }) else { return true }
                deps.logger?.debug("[db3] \(documentId): \(name)'s model was not uploaded (\(RecordLogIndexes.message(error))); it is kept and uploaded again")
                // Offline, the loop runs again when networking is allowed; else on the backoff.
                if !Db3IndexModelHttp.isOffline(error) { retry(ticket, name, .train) }
                return false
            }
            guard current(ticket) else { return true }
            // Refused: the claim lapsed, the model was deleted or another's was listed meanwhile.
            lock.withLock { retained[key] = nil }
            deps.logger?.log(
                "[db3] \(documentId): \(name)'s trained model was refused (\(Db3IndexModelHttp.code(error) ?? String((error as? HttpError)?.status ?? 0))); the list is read again"
            )
            try? await deps.releaseTraining(documentId, name)
            refreshList(ticket)
            return true
        }
        guard current(ticket) else { return true }
        lock.withLock { retained[key] = nil }
        let installed = try? await deps.install(documentId, name, kept.generation, kept.revision, kept.bytes, "shared")
        guard current(ticket) else { return true }
        if installed?.outcome == .failed {
            // Uploaded, and the device's storage failed the install: the room lists the model now, so it is fetched on the backoff.
            retry(ticket, name, .fetch)
            return true
        }
        succeeded(ticket, name)
        deps.logger?.log("[db3] \(documentId): uploaded \(name)'s model (revision \(kept.revision)) and installed it")
        return true
    }
}
