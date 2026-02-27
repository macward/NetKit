import Foundation

/// A sendable wrapper for deduplication keys.
///
/// This struct wraps a hashable value to ensure it can be safely passed across
/// actor boundaries while maintaining its identity for deduplication purposes.
public struct SendableRequestKey: Hashable, Sendable {
    private let hashValue_: Int
    private let isEqual: @Sendable (SendableRequestKey) -> Bool

    /// Creates a sendable key from any hashable and sendable value.
    public init<T: Hashable & Sendable>(_ value: T) {
        self.hashValue_ = value.hashValue
        self.isEqual = { other in
            // We can only compare if the underlying types match
            // Since we store hashValue, equal hashValues are considered equal
            other.hashValue_ == value.hashValue
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(hashValue_)
    }

    public static func == (lhs: SendableRequestKey, rhs: SendableRequestKey) -> Bool {
        lhs.hashValue_ == rhs.hashValue_
    }
}

/// A strategy for generating deduplication keys from network requests.
///
/// Request deduplication uses keys to determine if two requests are "identical"
/// and can share a single network call. The default strategy uses URL, HTTP method,
/// and body content, but you can customize this to include headers that affect
/// the response content.
///
/// Example - including Accept-Language for localized responses:
/// ```swift
/// let strategy = HeaderAwareRequestKeyStrategy(headers: ["Accept-Language"])
/// let client = NetworkClient(
///     environment: env,
///     requestKeyStrategy: strategy
/// )
/// ```
public protocol RequestKeyStrategy: Sendable {
    /// Generates a deduplication key for the given request.
    /// - Parameter request: The URLRequest to generate a key for.
    /// - Returns: A sendable hashable key that uniquely identifies the request for deduplication.
    func key(for request: URLRequest) -> SendableRequestKey
}

// MARK: - Default Strategy

/// The default request key strategy using URL, HTTP method, and body hash.
///
/// This strategy is suitable for most APIs where headers don't affect response content.
/// Headers are intentionally excluded to avoid edge cases with transient headers
/// like request IDs, timestamps, or authentication tokens.
public struct DefaultRequestKeyStrategy: RequestKeyStrategy {
    public init() {}

    public func key(for request: URLRequest) -> SendableRequestKey {
        SendableRequestKey(RequestKey(from: request))
    }
}

// MARK: - Header-Aware Strategy

/// A request key strategy that includes specific headers in the deduplication key.
///
/// Use this strategy when your API returns different content based on headers like:
/// - `Accept-Language`: Localized responses
/// - `Accept`: Different response formats
/// - `X-API-Version`: Versioned APIs
///
/// Example:
/// ```swift
/// let strategy = HeaderAwareRequestKeyStrategy(headers: ["Accept-Language", "Accept"])
/// ```
///
/// - Note: Do NOT include `Authorization` in deduplication keys. Auth tokens change
///   frequently and would prevent effective deduplication. For auth-aware caching,
///   use the cache key strategy instead.
public struct HeaderAwareRequestKeyStrategy: RequestKeyStrategy {
    /// The headers to include in the deduplication key.
    public let headers: [String]

    /// Creates a header-aware strategy.
    /// - Parameter headers: The header names to include in the key (case-insensitive).
    public init(headers: [String]) {
        self.headers = headers
    }

    public func key(for request: URLRequest) -> SendableRequestKey {
        SendableRequestKey(HeaderAwareRequestKey(from: request, headers: headers))
    }
}

// MARK: - Header-Aware Request Key

/// A request key that includes specific header values.
internal struct HeaderAwareRequestKey: Hashable, Sendable {
    let url: URL
    let method: String
    let bodyHash: Int?
    let headerValues: [String: String]

    init(from request: URLRequest, headers: [String]) {
        self.url = request.url ?? URL(string: "about:invalid")!
        self.method = request.httpMethod ?? "GET"
        self.bodyHash = request.httpBody?.hashValue

        var values: [String: String] = [:]
        for header in headers {
            if let value = request.value(forHTTPHeaderField: header) {
                values[header.lowercased()] = value
            }
        }
        self.headerValues = values
    }
}
