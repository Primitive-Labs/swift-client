import Foundation

// MARK: - CollectionTypeConfigsAPI

/// Mirrors the JS `CollectionTypeConfigsAPI` — configure which TOML
/// model types are valid for app-defined collections. Same five-method
/// CRUD shape as `GroupTypeConfigsAPI`, against
/// `/collection-type-configs`.
public final class CollectionTypeConfigsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    /// Percent-encode a `collectionType` for use as a path segment.
    ///
    /// Throws `invalidArgument` instead of silently falling back to the raw,
    /// unescaped value — the previous `?? collectionType` fallback could emit a
    /// request path divergent from JS's `encodeURIComponent` for unusual tags
    /// (#596). `.urlPathAllowed` is the consistent spec across all three path
    /// builders here.
    private static func encodePathSegment(_ collectionType: String) throws -> String {
        guard let escaped = collectionType.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) else {
            throw JsBaoError(
                code: .invalidArgument,
                message: "collectionType could not be percent-encoded for the request path: \(collectionType)"
            )
        }
        return escaped
    }

    /// Lists all collection type configurations for the current app.
    public func list() async throws -> [CollectionTypeConfigInfo] {
        let result = try await makeRequest("GET", "/collection-type-configs", nil)
        return try JSONCoding.decode([CollectionTypeConfigInfo].self, from: result)
    }

    /// Retrieves the configuration for a specific collection type.
    public func get(collectionType: String) async throws -> CollectionTypeConfigInfo {
        let escaped = try Self.encodePathSegment(collectionType)
        let result = try await makeRequest(
            "GET", "/collection-type-configs/\(escaped)", nil
        )
        return try JSONCoding.decode(CollectionTypeConfigInfo.self, from: result)
    }

    /// Creates a new collection type configuration.
    public func create(params: CreateCollectionTypeConfigParams) async throws -> CollectionTypeConfigInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("POST", "/collection-type-configs", body)
        return try JSONCoding.decode(CollectionTypeConfigInfo.self, from: result)
    }

    /// Updates an existing collection type configuration's rule set.
    public func update(
        collectionType: String,
        params: UpdateCollectionTypeConfigParams
    ) async throws -> CollectionTypeConfigInfo {
        let escaped = try Self.encodePathSegment(collectionType)
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest(
            "PATCH", "/collection-type-configs/\(escaped)", body
        )
        return try JSONCoding.decode(CollectionTypeConfigInfo.self, from: result)
    }

    /// Deletes a collection type configuration.
    @discardableResult
    public func delete(collectionType: String) async throws -> SuccessResult {
        let escaped = try Self.encodePathSegment(collectionType)
        let result = try await makeRequest(
            "DELETE", "/collection-type-configs/\(escaped)", nil
        )
        return try JSONCoding.decode(SuccessResult.self, from: result)
    }
}
