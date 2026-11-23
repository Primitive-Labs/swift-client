import Foundation

/// The db3 types a build was generated with, as `swift-bao-codegen
/// --known-types-only` writes them into `GeneratedModels.db3Types`, and the
/// local-only declarations of each type that allows local-only db3s.
///
/// Registered on a client (`GeneratedModels.register(on:)` does it), the
/// setting makes the client refuse to create a db3 of a type the build was
/// not generated with, or one archived in it, and to open a db3 of such a
/// type. Registrations accumulate: the known names are their union, and the
/// setting is on once any registration turns it on.
///
/// ```swift
/// GeneratedModels.register(on: client) // registers GeneratedModels.db3Types too
/// ```
public struct PrimitiveDb3Types: Sendable, Equatable {
    /// The declarations a build carries for a db3 type that allows
    /// local-only db3s (`[type] allowLocalOnly = true`), as `swift-bao-codegen`
    /// writes them: the type's models in install shape, as JSON, and their
    /// content hash. A db3 created with `localOnly: true` and the type is
    /// judged by them on this device.
    public struct LocalOnlyDeclarations: Sendable, Equatable {
        /// The content hash of the declarations: the revision hash the
        /// server answers for the same pushed type file.
        public let hash: String
        /// The type's models in install shape, as JSON text.
        public let modelsJSON: String

        public init(hash: String, modelsJSON: String) {
            self.hash = hash
            self.modelsJSON = modelsJSON
        }
    }

    /// One db3 type the build declares.
    public struct DeclaredType: Sendable, Equatable {
        /// The type's name: its `[type] name`, else its file stem.
        public let name: String
        /// Whether its type file says `archived = true`: no new db3 of it is created.
        public let archived: Bool
        /// The type's local-only declarations, when its type file allows
        /// local-only db3s; `nil` otherwise.
        public let localOnly: LocalOnlyDeclarations?

        public init(name: String, archived: Bool = false) {
            self.name = name
            self.archived = archived
            self.localOnly = nil
        }

        /// A type that allows local-only db3s, with the declarations its
        /// build carries.
        ///
        /// ```swift
        /// PrimitiveDb3Types.DeclaredType(name: "journal", localOnly: .init(hash: hash, modelsJSON: models))
        /// ```
        public init(name: String, archived: Bool = false, localOnly: LocalOnlyDeclarations) {
            self.name = name
            self.archived = archived
            self.localOnly = localOnly
        }
    }

    /// Whether the build was generated with `--known-types-only`.
    public let knownTypesOnly: Bool
    /// Every db3 type of the generator's input.
    public let types: [DeclaredType]

    public init(knownTypesOnly: Bool, types: [DeclaredType]) {
        self.knownTypesOnly = knownTypesOnly
        self.types = types
    }
}

/// A client's known-type guard (#6024): the db3 types registered with
/// ``JsBaoClient/registerDb3Types(_:)`` and the db3s let in through
/// `allowUnknownType`.
final class Db3KnownTypeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    private var names: Set<String> = []
    private var archived: Set<String> = []
    private var allowed: Set<String> = []
    /// The local-only declarations registered per type name (#6025), read once.
    private var localOnly: [String: RecordLogLocalType] = [:]

    /// The most names a refusal's `details["knownTypes"]` lists.
    static let listed = 50

    func register(_ types: PrimitiveDb3Types) {
        lock.withLock {
            if types.knownTypesOnly { on = true }
            for type in types.types where !type.name.isEmpty {
                names.insert(type.name)
                if type.archived { archived.insert(type.name) }
                if let declarations = type.localOnly, let parsed = RecordLogLocalType(name: type.name, declarations: declarations) {
                    localOnly[type.name] = parsed
                }
            }
        }
    }

    /// The build's local-only declarations for `type`, or `nil` when it carries none.
    func localOnly(of type: String) -> RecordLogLocalType? {
        lock.withLock { localOnly[type] }
    }

    /// Whether the setting is on.
    var knownTypesOnly: Bool { lock.withLock { on } }

    /// Whether the build knows `type`: always with the setting off.
    func isKnown(_ type: String) -> Bool {
        lock.withLock { !on || names.contains(type) }
    }

    /// Let `db3Id` open whatever its type, for the life of the client.
    func allow(_ db3Id: String) {
        lock.withLock { _ = allowed.insert(db3Id) }
    }

    /// Whether a db3 of `type` opens: the build knows it, or the db3 was let in.
    func opens(_ db3Id: String, type: String) -> Bool {
        lock.withLock { !on || names.contains(type) || allowed.contains(db3Id) }
    }

    /// The refusal of a create naming `type`, or `nil` when it may go ahead.
    func refusal(method: String, type: String?, allowUnknownType: Bool, archivedRefuses: Bool) -> JsBaoError? {
        guard let type, !allowUnknownType else { return nil }
        // Constant-time lookups decide; the creatable names are listed only for a refusal.
        let (refused, known, isArchived) = lock.withLock { () -> (Bool, Bool, Bool) in
            guard on else { return (false, true, false) }
            let known = names.contains(type), isArchived = archived.contains(type)
            return (!(known && !(isArchived && archivedRefuses)), known, isArchived)
        }
        guard refused else { return nil }
        let creatable = lock.withLock { Array(names.subtracting(archived).sorted().prefix(Self.listed)) }
        let why = known ? "is archived in this build" : "is not one this build was generated with"
        var details: [String: JSONValue] = [
            "reason": .string("unknown-type"), "type": .string(type), "knownTypes": .array(creatable.map { .string($0) }),
        ]
        if known && isArchived { details["archived"] = .bool(true) }
        return JsBaoError(
            code: .invalidArgument,
            message: "\(method): type '\(type)' \(why); pass allowUnknownType: true to create it anyway",
            details: details
        )
    }
}

extension JsBaoClient {
    /// Register the db3 types this build was generated with
    /// (`GeneratedModels.db3Types`; `GeneratedModels.register(on:)` calls
    /// it). With `knownTypesOnly`, the client refuses to create a db3 of a
    /// type not listed (or archived here) with `.invalidArgument`, and to
    /// open one with `.db3TypeUnknownToClient`; `allowUnknownType` lets a db3
    /// through. Registrations accumulate.
    ///
    /// ```swift
    /// client.registerDb3Types(GeneratedModels.db3Types)
    /// ```
    /// - Parameter types: The build's db3 types.
    /// - Stability: beta
    public func registerDb3Types(_ types: PrimitiveDb3Types) {
        db3KnownTypes.register(types)
        // A typed local-only copy already bound is reconciled with the declarations now registered.
        if types.types.contains(where: { $0.localOnly != nil }) { reconcileLocalTypes() }
        // A stored copy start-up already bound under a type the build does
        // not know is refused (unbound) now, so it is not readable under it.
        guard types.knownTypesOnly, let lifecycle = _db3Lifecycle else { return }
        Task { await lifecycle.typesRegistered() }
    }
}
