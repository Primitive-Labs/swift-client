import Foundation

// MARK: - ResourceMetadataAPI

/// Sub-API for reading and writing typed resource metadata
/// (`client.resourceMetadata.*`). Mirrors the JS client's
/// `ResourceMetadataAPI` (`src/client/api/resourceMetadataApi.ts`, issues #1352
/// and #1402) method-for-method over the same REST endpoints.
///
/// Metadata is grouped into named **categories** defined by an app admin (via
/// TOML sync or the admin-gated `metadata-categories` route). This namespace
/// covers **values only** — there is deliberately no client surface for
/// creating or listing category definitions.
///
/// Reads are gated per category by its `readRule` and writes by its
/// `writeRule`, with an app-level owner/admin bypass; a resource-level
/// permission never bypasses. A denial surfaces as an `HttpError` with status
/// 403 on the single read/write calls (`get`/`set`/`list`/`delete`), and as a
/// per-item `ok: false` entry inside the batch. `resolve` is the exception: a
/// denial there is reported as a miss, not a 403 — see its doc below.
///
/// ```swift
/// _ = try await client.resourceMetadata.set(
///     resourceType: "user",
///     resourceId: userId,
///     category: "profile",
///     data: ["tier": "pro", "displayName": "Ada"]
/// )
///
/// let profile = try await client.resourceMetadata.get(
///     resourceType: "user", resourceId: userId, category: "profile"
/// )
/// if profile.exists, case .string(let tier)? = profile.data["tier"] {
///     print(tier)  // "pro"
/// }
/// ```
///
/// Reads are point-in-time: metadata changes are not pushed to clients, so poll
/// on whatever interval the use case's freshness needs. State that must react
/// in real time belongs in a document.
public final class ResourceMetadataAPI: @unchecked Sendable {
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

    // MARK: - Paths

    /// Percent-encodes a free-text path parameter before it is interpolated
    /// into a path, the convention every sub-API follows (#1601 / #2042) — the
    /// transport assembles the path from segments and does not escape them
    /// (`HttpClient.buildURLRequest` sets `.percentEncodedPath`, which passes
    /// its input through verbatim).
    ///
    /// Routes through the shared `URLEncoding.encodeComponent` (#2076), which
    /// escapes everything outside the `encodeURIComponent` unreserved set — the
    /// same bytes the JS client's `encodeURIComponent` puts on the wire
    /// (`src/client/api/resourceMetadataApi.ts`). In particular a `/` inside a
    /// `resourceType` / `resourceId` / `category` is sent as `%2F` rather than
    /// splitting into extra path segments and routing to a different endpoint.
    private func escape(_ segment: String) -> String {
        URLEncoding.encodeComponent(segment)
    }

    private func resourcePath(_ resourceType: String, _ resourceId: String) -> String {
        "/resources/\(escape(resourceType))/\(escape(resourceId))"
    }

    private func categoryPath(
        _ resourceType: String,
        _ resourceId: String,
        _ category: String
    ) -> String {
        "\(resourcePath(resourceType, resourceId))/metadata/\(escape(category))"
    }

    // MARK: - Single read / write

    /// Read one resource's metadata for one category.
    ///
    /// Succeeds with `exists == false` and empty `data` when nothing has been
    /// written yet. Throws `HttpError` with status 404 when the category is not
    /// defined for the resource type, and 403 when the category's `readRule`
    /// denies the caller.
    public func get(
        resourceType: String,
        resourceId: String,
        category: String
    ) async throws -> ResourceMetadataReadResult {
        try await transport.request(
            method: .get,
            path: categoryPath(resourceType, resourceId, category)
        )
    }

    /// Write (full replace) one resource's metadata for one category.
    ///
    /// This is a replace, not a merge: keys absent from `data` are removed. The
    /// data is validated against the category's schema, and the category's
    /// `writeRule` gates the write (403 on denial).
    public func set(
        resourceType: String,
        resourceId: String,
        category: String,
        data: [String: JSONValue]
    ) async throws -> ResourceMetadataWriteResult {
        try await transport.request(
            method: .put,
            path: categoryPath(resourceType, resourceId, category),
            body: ResourceMetadataWriteRequest(data: data)
        )
    }

    // MARK: - Batch read

    /// Read metadata for many resources in one call — the fan-out a listing
    /// view would otherwise do one request per row.
    ///
    /// Bounded at 50 resources and 200 resource/category pairs per call;
    /// exceeding either limit fails the whole call with 400 `BATCH_TOO_LARGE`.
    /// Otherwise this is a partial-success call: per-item 403/404 problems come
    /// back as structured `ok: false` entries and do **not** throw.
    public func getBatch(
        requests: [ResourceMetadataBatchRequestItem]
    ) async throws -> ResourceMetadataBatchResult {
        try await transport.request(
            method: .post,
            path: "/resources/metadata/batch",
            body: ResourceMetadataBatchRequest(requests: requests)
        )
    }

    // MARK: - Reverse resolve

    /// Look a resource up by the value of a category's unique field — the
    /// reverse of a metadata read. Useful for mapping an external identifier (a
    /// payment provider's customer ID, an SSO subject, an imported record key)
    /// back onto the resource that owns it.
    ///
    /// A value no readable resource owns comes back with `resourceId == nil` —
    /// a miss is a success, not an error. The category's `readRule` is applied
    /// to the resolved resource, and a denied read returns that same miss
    /// shape, so the response body never reveals whether a value you may not
    /// read exists. Only the body is indistinguishable: a denied resolve does
    /// the rule evaluation a miss skips, so it is not constant-time.
    ///
    /// Throws `HttpError` with status 400 and `serverCode == "NOT_UNIQUE_FIELD"`
    /// when `key` is not the category's active unique field — a configuration
    /// error, deliberately distinct from a miss — and 404 when the category is
    /// not defined for the resource type.
    ///
    /// ```swift
    /// let hit = try await client.resourceMetadata.resolve(
    ///     resourceType: "user",
    ///     category: "billing",
    ///     key: "stripeCustomerId",
    ///     value: "cus_ABC"
    /// )
    /// if let owner = hit.resolved {
    ///     print(owner.resourceId)  // the user that owns the value
    /// }
    /// ```
    public func resolve(
        resourceType: String,
        category: String,
        key: String,
        value: String
    ) async throws -> ResourceMetadataResolveResult {
        try await transport.request(
            method: .post,
            path: "/metadata/resolve",
            body: ResourceMetadataResolveRequest(
                resourceType: resourceType,
                category: category,
                key: key,
                value: value
            )
        )
    }

    // MARK: - List / delete

    /// List every stored metadata category on one resource.
    ///
    /// Only categories the caller may read are returned (each gated by its
    /// `readRule`, with the app-level owner/admin bypass); a resource with no
    /// metadata comes back with an empty `categories` array rather than an
    /// error.
    public func list(
        resourceType: String,
        resourceId: String
    ) async throws -> ResourceMetadataListResult {
        try await transport.request(
            method: .get,
            path: "\(resourcePath(resourceType, resourceId))/metadata"
        )
    }

    /// Delete one resource's metadata for one category.
    ///
    /// The category's `writeRule` gates the delete (403 on denial). Idempotent:
    /// deleting an item that does not exist succeeds with `deleted == false`
    /// rather than failing with 404.
    public func delete(
        resourceType: String,
        resourceId: String,
        category: String
    ) async throws -> ResourceMetadataDeleteResult {
        try await transport.request(
            method: .delete,
            path: categoryPath(resourceType, resourceId, category)
        )
    }
}
