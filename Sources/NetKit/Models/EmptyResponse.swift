import Foundation

/// A type representing an empty response body.
/// Use this as the Response type for endpoints that don't return data (e.g., DELETE requests).
public struct EmptyResponse: Decodable, Equatable, Sendable {
    public init() {}
}
