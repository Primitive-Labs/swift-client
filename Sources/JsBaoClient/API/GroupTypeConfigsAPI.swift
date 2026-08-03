import Foundation

// MARK: - GroupTypeConfigsAPI

public final class GroupTypeConfigsAPI: @unchecked Sendable {
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

    /// Percent-encode a `groupType` before interpolating it into the request
    /// path, matching the JS client's `encodeURIComponent` on `get` / `update`
    /// / `delete` (#590).
    private static func encode(_ groupType: String) -> String {
        URLEncoding.encodeComponent(groupType)
    }

    /// Lists all group type configurations for the current app.
    public func list() async throws -> [GroupTypeConfigInfo] {
        try await transport.request(method: .get, path: "/group-type-configs")
    }

    /// Retrieves the configuration for a specific group type.
    public func get(groupType: String) async throws -> GroupTypeConfigInfo {
        try await transport.request(method: .get, path: "/group-type-configs/\(Self.encode(groupType))")
    }

    /// Creates a new group type configuration.
    public func create(params: CreateGroupTypeConfigParams) async throws -> GroupTypeConfigInfo {
        try await transport.request(method: .post, path: "/group-type-configs", body: params)
    }

    /// Updates an existing group type configuration's rule set or
    /// auto-add-creator setting.
    public func update(groupType: String, params: UpdateGroupTypeConfigParams) async throws -> GroupTypeConfigInfo {
        try await transport.request(
            method: .patch,
            path: "/group-type-configs/\(Self.encode(groupType))",
            body: params
        )
    }

    /// Deletes a group type configuration. Resolves to `{ success }`.
    @discardableResult
    public func delete(groupType: String) async throws -> SuccessResult {
        try await transport.request(method: .delete, path: "/group-type-configs/\(Self.encode(groupType))")
    }
}
