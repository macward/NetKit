import Foundation

/// Defines the configuration for a network environment.
public protocol Environment: Sendable {
    /// The base URL for all requests in this environment.
    var baseURL: URL { get }

    /// Default headers to include in all requests.
    var defaultHeaders: [String: String] { get }

    /// The timeout interval for requests in seconds.
    var timeout: TimeInterval { get }
}

public extension Environment {
    var defaultHeaders: [String: String] { [:] }
    var timeout: TimeInterval { 30 }
}
