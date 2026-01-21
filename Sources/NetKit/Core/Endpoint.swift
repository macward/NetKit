import Foundation

/// Defines an API endpoint with its path, method, and expected response type.
public protocol Endpoint: Sendable {
    /// The response type expected from this endpoint.
    associatedtype Response: Decodable & Sendable

    /// The path component of the URL (e.g., "/users/123").
    var path: String { get }

    /// The HTTP method for this endpoint.
    var method: HTTPMethod { get }

    /// Additional headers specific to this endpoint.
    var headers: [String: String] { get }

    /// Query parameters to append to the URL.
    var queryParameters: [String: String] { get }

    /// The request body, if any.
    var body: (any Encodable & Sendable)? { get }

    /// Custom cache TTL for this endpoint. When set, overrides server cache headers.
    /// Use `nil` to respect server headers, `0` to disable caching for this endpoint.
    var cacheTTL: TimeInterval? { get }

    /// Cache policy for this endpoint. Defaults to respecting HTTP cache headers.
    var cachePolicy: EndpointCachePolicy { get }

    /// Deduplication policy for this endpoint. Controls whether identical concurrent requests
    /// are deduplicated (sharing a single network call). Defaults to `.automatic`.
    var deduplicationPolicy: DeduplicationPolicy { get }
}

public extension Endpoint {
    var headers: [String: String] { [:] }
    var queryParameters: [String: String] { [:] }
    var body: (any Encodable & Sendable)? { nil }
    var cacheTTL: TimeInterval? { nil }
    var cachePolicy: EndpointCachePolicy { .respectHeaders }
    var deduplicationPolicy: DeduplicationPolicy { .automatic }
}

// MARK: - Endpoint Cache Policy

/// Cache behavior options for individual endpoints.
///
/// Use these policies to control how responses for specific endpoints are cached:
/// - `.respectHeaders`: Default behavior, follows server's Cache-Control directives
/// - `.noCache`: Completely disable caching for this endpoint
/// - `.always(ttl:)`: Cache all responses with a fixed TTL, ignoring server headers entirely
/// - `.overrideTTL(_:)`: Cache only if server allows (no `no-store`), but use your TTL instead of server's
public enum EndpointCachePolicy: Sendable {
    /// Respect HTTP cache headers from the server response.
    /// This is the default behavior and follows RFC 7234 semantics.
    case respectHeaders

    /// Never cache responses for this endpoint.
    /// Use this for sensitive data or rapidly changing content.
    case noCache

    /// Always cache with the specified TTL, ignoring server headers entirely.
    /// Use this when you know better than the server how long content should be cached.
    case always(ttl: TimeInterval)

    /// Cache only if server allows (respects `no-store`), but override the TTL.
    /// Use this when server caching is acceptable but the duration needs adjustment.
    case overrideTTL(TimeInterval)
}
