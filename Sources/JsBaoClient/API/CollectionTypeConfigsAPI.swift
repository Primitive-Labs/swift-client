import Foundation

// MARK: - CollectionTypeConfigsAPI

/// Mirrors the JS `CollectionTypeConfigsAPI` — configure which TOML
/// model types are valid for app-defined collections. Same five-method
/// CRUD shape as `GroupTypeConfigsAPI`, against
/// `/collection-type-configs`.
public final class CollectionTypeConfigsAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    /// Percent-encode a `collectionType` for use as a path segment.
    ///
    /// Routes through the shared `URLEncoding.encodeComponent` (#2076), which
    /// matches JS's `encodeURIComponent` exactly — the parity this method's
    /// `.urlPathAllowed` charset originally aimed for but missed (#596).
    private static func encodePathSegment(_ collectionType: String) -> String {
        URLEncoding.encodeComponent(collectionType)
    }

    /// Lists all collection type configurations for the current app.
    public func list() async throws -> [CollectionTypeConfigInfo] {
        try await transport.request(method: .get, path: "/collection-type-configs")
    }

    /// Retrieves the configuration for a specific collection type.
    public func get(collectionType: String) async throws -> CollectionTypeConfigInfo {
        let escaped = Self.encodePathSegment(collectionType)
        return try await transport.request(
            method: .get,
            path: "/collection-type-configs/\(escaped)"
        )
    }

    /// Creates a new collection type configuration.
    public func create(params: CreateCollectionTypeConfigParams) async throws -> CollectionTypeConfigInfo {
        try await transport.request(method: .post, path: "/collection-type-configs", body: params)
    }

    /// Updates an existing collection type configuration's rule set.
    public func update(
        collectionType: String,
        params: UpdateCollectionTypeConfigParams
    ) async throws -> CollectionTypeConfigInfo {
        let escaped = Self.encodePathSegment(collectionType)
        return try await transport.request(
            method: .patch,
            path: "/collection-type-configs/\(escaped)",
            body: params
        )
    }

    /// Deletes a collection type configuration.
    @discardableResult
    public func delete(collectionType: String) async throws -> SuccessResult {
        let escaped = Self.encodePathSegment(collectionType)
        return try await transport.request(
            method: .delete,
            path: "/collection-type-configs/\(escaped)"
        )
    }
}
