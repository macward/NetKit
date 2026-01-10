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
}

public extension Endpoint {
    var headers: [String: String] { [:] }
    var queryParameters: [String: String] { [:] }
    var body: (any Encodable & Sendable)? { nil }
}
