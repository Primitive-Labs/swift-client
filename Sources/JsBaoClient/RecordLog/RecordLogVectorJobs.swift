import Foundation

/// A db3 binding's background work on its device vector indexes (#5230), the
/// Swift port of js-bao's `VectorJobs`: the fill of an ANN table a slice at a
/// time, each slice a store command on a task of its own so the store
/// answers its queries between slices, and what each `ann` entry wants,
/// evaluated again after every store operation that may change it and told
/// to the client when it changed.
///
/// Two bindings of one file (two clients in a process) may both fill a
/// table: a slice copies only the rows the ANN table lacks, so the fills
/// converge.
///
/// `@unchecked Sendable`: every mutable property is read and written under
/// `lock`, which is never held across a call out of this class.
final class RecordLogVectorJobs: @unchecked Sendable {

    /// What a store operation may have changed.
    enum Change: Sendable {
        /// The index list or the device's policy (a sync, a decline or an accept): the entries may be others.
        case list
        /// Rows were written (a commit, a catch-up, a load, a segment): a `train` want's row count.
        case rows
        /// A training mark was taken or dropped.
        case training
        /// A model was installed: its fill begins.
        case install
        /// A model was dropped.
        case invalidate
        /// The binding opened its store: a fill under way goes on, a mark's lapse is armed.
        case open
    }

    /// What the jobs tell the client.
    enum Notice: Sendable {
        /// What the `ann` entries want now.
        case wants([RecordLogVectorWant])
        /// An entry's status changed (a model installed, a fill ended, a model dropped).
        case statuses
    }

    private let store: RecordLogStore
    private let emit: @Sendable (Notice) -> Void
    private let lock = NSLock()
    /// The wants last told, their rows left out; nothing is told while they stay none.
    private var told: [RecordLogVectorWant] = []
    /// Whether the store holds an `ann` entry awaiting a model, read again after a change of the list.
    private var awaited: Bool?
    private var stopped = false
    private var filling = false
    /// The wake armed at the earliest training mark's lapse, and when (epoch ms).
    private var lapse: (at: Int64, task: Task<Void, Never>)?

    init(store: RecordLogStore, emit: @escaping @Sendable (Notice) -> Void) {
        self.store = store
        self.emit = emit
    }

    /// A store operation ran: evaluate the wants again when it may have changed them, and go on with a fill it began or found.
    func after(_ change: Change) {
        guard !lock.withLock({ stopped }) else { return }
        if change == .list || change == .install || change == .invalidate || change == .training { lock.withLock { awaited = nil } }
        if change == .install || change == .invalidate { emit(.statuses) }
        evaluate()
        if change == .install || change == .open || change == .list { fill() }
    }

    /// Stop: no slice runs and nothing is told from now.
    func stop() {
        let wake = lock.withLock { () -> Task<Void, Never>? in
            stopped = true
            defer { lapse = nil }
            return lapse?.task
        }
        wake?.cancel()
    }

    /// What the `ann` entries want now, told when it is not what was told.
    private func evaluate() {
        do {
            let known = lock.withLock { awaited }
            let isAwaited = try known ?? store.vectorModelsAwaited()
            lock.withLock { awaited = isAwaited }
            // With no entry awaiting a model, nothing is read on a write: the wants are none.
            let wants = isAwaited ? try store.vectorModelWants() : []
            armLapse(isAwaited ? try store.vectorTrainingLapse() : nil)
            let identities = wants.map(\.identity)
            let changed = lock.withLock { () -> Bool in
                guard !stopped, identities != told else { return false }
                told = identities
                return true
            }
            if changed { emit(.wants(wants)) }
        } catch {
            store.logger?.debug("[record-log] \(store.documentId): the vector indexes' wants were not evaluated: \(RecordLogIndexes.message(error))")
        }
    }

    /// Evaluate the wants again when a training mark lapses: the run that
    /// took it may have ended with its client, and nothing else may come to
    /// evaluate them.
    private func armLapse(_ at: Int64?) {
        let replaced = lock.withLock { () -> Task<Void, Never>?? in
            if lapse?.at == at { return .none }
            let old = lapse?.task
            lapse = nil
            guard let at, !stopped else { return .some(old) }
            let delay = max(0, Double(at) - Date().timeIntervalSince1970 * 1000) + 1
            let task = Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000))
                guard !Task.isCancelled, let self else { return }
                self.lock.withLock { self.lapse = nil; self.awaited = nil }
                if !self.lock.withLock({ self.stopped }) { self.evaluate() }
            }
            lapse = (at, task)
            return .some(old)
        }
        if case .some(let old) = replaced { old?.cancel() }
    }

    /// Fill the db3's ANN tables, a slice per task, when one is under way and none of this binding's runs.
    private func fill() {
        let pending = (try? store.vectorFillPending()) ?? false
        guard pending else { return }
        let start = lock.withLock { () -> Bool in
            guard !filling, !stopped else { return false }
            filling = true
            return true
        }
        guard start else { return }
        slice()
    }

    private func slice() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard !self.lock.withLock({ self.stopped }) else { return self.lock.withLock { self.filling = false } }
            let building: [String]
            do {
                let slice = try self.store.continueVectorFill()
                if slice.ms > 50 {
                    self.store.logger?.log("[record-log] \(self.store.documentId): a vector index's fill slice took \(String(format: "%.1f", slice.ms)) ms (over 50 ms).")
                }
                building = slice.building
            } catch {
                self.lock.withLock { self.filling = false }
                self.store.logger?.warn("[record-log] \(self.store.documentId): a vector index's fill stopped: \(RecordLogIndexes.message(error))")
                return
            }
            if !building.isEmpty { return self.slice() }
            self.lock.withLock {
                self.filling = false
                self.awaited = nil
            }
            self.emit(.statuses)
            self.evaluate()
        }
    }
}
