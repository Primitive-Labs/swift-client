import Foundation

// MARK: - GroupTypeConfigsAPI

public final class GroupTypeConfigsAPI: @unchecked Sendable {
    private let makeRequest: (String, String, Any?) async throws -> Any

    public init(makeRequest: @escaping (String, String, Any?) async throws -> Any) {
        self.makeRequest = makeRequest
    }

    /// Percent-encode a `groupType` before interpolating it into the request
    /// path, matching the JS client's `encodeURIComponent` on `get` / `update`
    /// / `delete` (#590).
    private static func encode(_ groupType: String) -> String {
        groupType.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? groupType
    }

    /// Lists all group type configurations for the current app.
    public func list() async throws -> [GroupTypeConfigInfo] {
        let result = try await makeRequest("GET", "/group-type-configs", nil)
        return try JSONCoding.decode([GroupTypeConfigInfo].self, from: result)
    }

    /// Retrieves the configuration for a specific group type.
    public func get(groupType: String) async throws -> GroupTypeConfigInfo {
        let result = try await makeRequest("GET", "/group-type-configs/\(Self.encode(groupType))", nil)
        return try JSONCoding.decode(GroupTypeConfigInfo.self, from: result)
    }

    /// Creates a new group type configuration.
    public func create(params: CreateGroupTypeConfigParams) async throws -> GroupTypeConfigInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("POST", "/group-type-configs", body)
        return try JSONCoding.decode(GroupTypeConfigInfo.self, from: result)
    }

    /// Updates an existing group type configuration's rule set or
    /// auto-add-creator setting.
    public func update(groupType: String, params: UpdateGroupTypeConfigParams) async throws -> GroupTypeConfigInfo {
        let body = try JSONCoding.jsonObject(from: params)
        let result = try await makeRequest("PATCH", "/group-type-configs/\(Self.encode(groupType))", body)
        return try JSONCoding.decode(GroupTypeConfigInfo.self, from: result)
    }

    /// Deletes a group type configuration. Resolves to `{ success }`.
    @discardableResult
    public func delete(groupType: String) async throws -> SuccessResult {
        let result = try await makeRequest("DELETE", "/group-type-configs/\(Self.encode(groupType))", nil)
        return try JSONCoding.decode(SuccessResult.self, from: result)
    }
}
