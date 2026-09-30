import Foundation

/// Whether this device can hold this document, decided before the first chunk
/// is fetched (#3437, behaviors 32, 33 and 34).
///
/// A cold load streams a base snapshot straight into the local record store,
/// chunk by chunk, and on the documents this epic exists for that is minutes
/// of writing. The failure this module prevents is the quiet one: without it
/// the load starts, writes for minutes, and throws on the chunk that crosses
/// the device's capacity — leaving a `records` table holding SOME of the
/// document, which the client will nonetheless answer `find` and `query` from,
/// because on format 2 the merged view IS the document. A partial merged view
/// is not a slower document, it is a wrong one.
///
/// The intent's Swift rule is that the check CAPS rather than refuses: it is
/// what replaces the waived iPadOS quota check, and a device that can hold the
/// models the app named is more useful than one that holds nothing. The
/// refusal is for the case where not even those fit — never a partial load
/// reported as a whole one.
///
/// Every number here is js-bao's, and the parity suite compares the two over
/// the same inputs.
public enum Format2StorageCapability {

    /// How much local space a chunk's UNCOMPRESSED ndjson takes once it is
    /// rows in SQLite.
    ///
    /// Above one because the rows land with their indexes. Two is deliberately
    /// pessimistic: over-estimating costs a device a model it could have held,
    /// under-estimating costs it the mid-load failure this exists to prevent.
    public static let snapshotStorageExpansion = 2

    /// What a chunk's STORED bytes are assumed to inflate to when its manifest
    /// does not record the uncompressed length.
    ///
    /// High on purpose. Gzipped ndjson of repetitive JSON records routinely
    /// compresses by an order of magnitude, and treating the compressed size
    /// as a proxy for the materialized one is exactly how a device approves a
    /// document it cannot hold.
    public static let snapshotCompressedExpansion = 8

    /// What one chunk is expected to cost in the local store once materialized.
    public static func estimateMaterializedBytes(_ chunk: SnapshotChunkEntry) -> Int {
        let raw = chunk.rawBytes ?? (chunk.bytes * snapshotCompressedExpansion)
        return raw * snapshotStorageExpansion
    }

    /// Materialized cost per model, in the order the manifest lists them.
    ///
    /// A chunk this device has already committed costs nothing more: its rows
    /// are in the store, so they are already part of what the volume reports
    /// as used. Counting them again would refuse a resumed load the closer it
    /// got to finishing (edge E8).
    private static func costByModel(
        _ manifest: SnapshotManifest, completed: Set<Int>
    ) -> (order: [String], costs: [String: Int]) {
        var order: [String] = []
        var costs: [String: Int] = [:]
        for (index, chunk) in manifest.chunks.enumerated() {
            let ordinal = chunk.ordinal ?? index
            let cost = completed.contains(ordinal) ? 0 : estimateMaterializedBytes(chunk)
            if costs[chunk.model] == nil {
                order.append(chunk.model)
                costs[chunk.model] = 0
            }
            costs[chunk.model, default: 0] += cost
        }
        return (order, costs)
    }

    /// Decide what to hydrate before the load starts.
    ///
    /// - Parameters:
    ///   - models: the models to keep when the whole document will not fit —
    ///     the app's statement of what is worth the room it has. Ignored when
    ///     everything fits: this is a fallback for a device that cannot take
    ///     the document, not a permanent narrowing of it.
    ///   - completedChunks: manifest ordinals a previous attempt already
    ///     committed (`_snapshot_load`), which the device has made room for
    ///     once already.
    /// - Throws: ``Format2Storage/unavailable(reason:documentId:)``'s error
    ///   with `requiredBytes`, `availableBytes` and `models` in its details,
    ///   before a single chunk has been asked for.
    public static func planSnapshotHydration(
        manifest: SnapshotManifest,
        capability: StorageCapability,
        models: [String] = [],
        completedChunks: Set<Int> = []
    ) throws -> HydrationPlan {
        let (order, costs) = costByModel(manifest, completed: completedChunks)
        let whole = order.reduce(0) { $0 + (costs[$1] ?? 0) }

        // A store that does not persist cannot be the document, whatever its
        // size: a view that evaporates when the app closes is not an
        // authoritative copy of anything.
        guard capability.persistent else {
            throw refusal(
                reason: .notPersistent, requiredBytes: whole,
                availableBytes: capability.quotaBytes, models: []
            )
        }

        let available = capability.quotaBytes.map {
            max(0, $0 - (capability.usedBytes ?? 0))
        }

        // No quota reported, or room for everything: take the document whole.
        // Refusing on ignorance would take large documents away from every
        // platform without a capacity API, and those are the ones with room.
        guard let available, whole > available else {
            return HydrationPlan(kind: .full, models: order, skipped: [], bytes: whole)
        }

        // Only the configured models this snapshot actually carries: one the
        // app renamed, or has not written yet, costs nothing and skips nothing.
        let configured = order.filter { models.contains($0) }
        let capped = configured.reduce(0) { $0 + (costs[$1] ?? 0) }
        guard !configured.isEmpty, capped <= available else {
            throw refusal(
                reason: .overQuota,
                requiredBytes: configured.isEmpty ? whole : capped,
                availableBytes: available,
                models: configured
            )
        }
        return HydrationPlan(
            kind: .capped,
            models: configured,
            skipped: order.filter { !configured.contains($0) },
            bytes: capped
        )
    }

    private static func refusal(
        reason: Format2Storage.Reason,
        requiredBytes: Int,
        availableBytes: Int?,
        models: [String]
    ) -> JsBaoError {
        let base = Format2Storage.unavailable(reason: reason)
        var details = base.details ?? [:]
        details["requiredBytes"] = .number(Double(requiredBytes))
        details["availableBytes"] = availableBytes.map { .number(Double($0)) } ?? .null
        details["models"] = .array(models.map(JSONValue.string))
        let message: String
        switch reason {
        case .notPersistent:
            message = base.message
        case .overQuota:
            message = "This large document needs \(requiredBytes) bytes on this "
                + "device but only \(availableBytes ?? 0) are available"
                + (models.isEmpty ? "" : ", even limited to \(models.joined(separator: ", "))")
                + "."
        }
        return JsBaoError(
            code: .format2StorageUnavailable, message: message, details: details
        )
    }

    // MARK: - The probe

    /// What the volume under `directory` will let this document keep
    /// (behavior 33).
    ///
    /// `volumeAvailableCapacityForImportantUsage` rather than the raw free
    /// space: it is what the system is willing to give data the app would be
    /// broken without, which is exactly what a large document's merged view
    /// is. It also accounts for purgeable space, so a device whose disk is
    /// full of caches is not refused a document it could hold.
    ///
    /// A key that cannot be read is an UNKNOWN capacity, never zero — zero
    /// would refuse the document on every platform that does not answer.
    /// `usedBytes` is zero because the capacity reported is already what is
    /// FREE.
    public static func probe(directory: String) -> StorageCapability {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let capacity = values?.volumeAvailableCapacityForImportantUsage else {
            return StorageCapability(persistent: true, quotaBytes: nil, probed: true)
        }
        return StorageCapability(
            persistent: true,
            quotaBytes: Int(capacity),
            usedBytes: 0,
            probed: true
        )
    }
}

/// What the platform says about the store a merged view would live in.
public struct StorageCapability: Equatable, Sendable {

    /// Whether what is written survives the app going away.
    public let persistent: Bool
    /// Bytes this device may keep, or `nil` when the platform will not say.
    public let quotaBytes: Int?
    /// Bytes already held that come out of `quotaBytes`. Zero when the quota
    /// reported is already what is free, which is what the volume probe gives.
    public let usedBytes: Int?
    /// Whether a platform API answered, as opposed to there having been none
    /// to ask. An app that configured the capability itself did not probe.
    public let probed: Bool

    public init(
        persistent: Bool,
        quotaBytes: Int?,
        usedBytes: Int? = 0,
        probed: Bool = false
    ) {
        self.persistent = persistent
        self.quotaBytes = quotaBytes
        self.usedBytes = usedBytes
        self.probed = probed
    }
}

/// Which models a load should hydrate on this device.
public struct HydrationPlan: Equatable, Sendable {

    public enum Kind: String, Equatable, Sendable {
        /// The whole snapshot.
        case full
        /// Models were left behind, and ``HydrationPlan/skipped`` names them.
        case capped
    }

    public let kind: Kind
    /// Models to hydrate, in the manifest's order.
    public let models: [String]
    /// Models the snapshot carries that this device is not taking.
    public let skipped: [String]
    /// Materialized bytes the plan is expected to cost.
    public let bytes: Int
}

/// What an app configures about the room it will give a large document.
public struct LargeDocumentStorageOptions: Sendable {

    /// Override the volume probe — a host that knows better than the
    /// filesystem does, and what a test drives the cap with.
    public let capability: StorageCapability?
    /// The models worth keeping when the whole document will not fit. With
    /// none configured, a device that cannot take the document is refused
    /// rather than capped: there is nothing to cap it to.
    public let models: [String]?

    public init(capability: StorageCapability? = nil, models: [String]? = nil) {
        self.capability = capability
        self.models = models
    }
}
