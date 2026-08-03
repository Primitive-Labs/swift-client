import Foundation

// MARK: - DatabaseTypeConfigsAPI

/// Mirrors the JS `DatabaseTypeConfigsAPI` — schema-less database type
/// configs that bind a rule set + CEL trigger rules + metadata-access
/// CEL gate to a `databaseType` tag. Five-method CRUD against
/// `/databases/types`.
public final class DatabaseTypeConfigsAPI: @unchecked Sendable {
    private let transport: any Transport

    /// Designated initializer — the typed transport spine.
    public init(transport: any Transport) {
        self.transport = transport
    }

    /// Deprecated: construct with a `Transport` instead. The legacy closure is
    /// wrapped in an adapter so existing call sites keep working for one major
    /// cycle.
    @available(*, deprecated, message: "Use init(transport:) — the untyped makeRequest closure is removed in the next major release.")
    public convenience init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.init(transport: ClosureTransport(makeRequest: makeRequest))
    }

    /// Lists all database type configurations for the current app.
    public func list() async throws -> [DatabaseTypeConfigInfo] {
        try await transport.request(method: .get, path: "/databases/types")
    }

    /// Retrieves the configuration for a specific database type.
    public func get(databaseType: String) async throws -> DatabaseTypeConfigInfo {
        let escaped = URLEncoding.encodeComponent(databaseType)
        return try await transport.request(method: .get, path: "/databases/types/\(escaped)")
    }

    /// Creates a new database type configuration.
    public func create(params: CreateDatabaseTypeConfigParams) async throws -> DatabaseTypeConfigInfo {
        try await transport.request(method: .post, path: "/databases/types", body: params)
    }

    /// Updates an existing database type configuration. Omit a field on
    /// `params` to leave it unchanged; pass `.clear` to null it out.
    public func update(
        databaseType: String,
        params: UpdateDatabaseTypeConfigParams
    ) async throws -> DatabaseTypeConfigInfo {
        let escaped = URLEncoding.encodeComponent(databaseType)
        return try await transport.request(
            method: .patch,
            path: "/databases/types/\(escaped)",
            body: params
        )
    }

    /// Deletes a database type configuration. Resolves to `{ success }`.
    @discardableResult
    public func delete(databaseType: String) async throws -> SuccessResult {
        let escaped = URLEncoding.encodeComponent(databaseType)
        return try await transport.request(
            method: .delete,
            path: "/databases/types/\(escaped)"
        )
    }
}
