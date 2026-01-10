import Foundation

/// A builder for configuring and executing network requests with per-request overrides.
public struct RequestBuilder<E: Endpoint>: Sendable {
    /// The endpoint to execute.
    public let endpoint: E

    /// Custom timeout override.
    public private(set) var timeoutOverride: TimeInterval?

    /// Additional headers to merge with endpoint headers.
    public private(set) var additionalHeaders: [String: String]

    /// The execution closure provided by the client.
    private let executor: @Sendable (E, TimeInterval?, [String: String]) async throws -> E.Response

    /// Creates a request builder.
    /// - Parameters:
    ///   - endpoint: The endpoint to execute.
    ///   - executor: A closure that executes the request with the given overrides.
    public init(
        endpoint: E,
        executor: @escaping @Sendable (E, TimeInterval?, [String: String]) async throws -> E.Response
    ) {
        self.endpoint = endpoint
        self.timeoutOverride = nil
        self.additionalHeaders = [:]
        self.executor = executor
    }

    /// Sets a custom timeout for this request.
    /// - Parameter seconds: The timeout in seconds.
    /// - Returns: A new builder with the timeout override.
    public func timeout(_ seconds: TimeInterval) -> RequestBuilder<E> {
        var copy = self
        copy.timeoutOverride = seconds
        return copy
    }

    /// Adds a header to this request.
    /// - Parameters:
    ///   - key: The header name.
    ///   - value: The header value.
    /// - Returns: A new builder with the additional header.
    public func header(_ key: String, _ value: String) -> RequestBuilder<E> {
        var copy = self
        copy.additionalHeaders[key] = value
        return copy
    }

    /// Adds multiple headers to this request.
    /// - Parameter headers: A dictionary of headers to add.
    /// - Returns: A new builder with the additional headers.
    public func headers(_ headers: [String: String]) -> RequestBuilder<E> {
        var copy = self
        copy.additionalHeaders.merge(headers) { _, new in new }
        return copy
    }

    /// Executes the request with all configured overrides.
    /// - Returns: The decoded response.
    public func send() async throws -> E.Response {
        try await executor(endpoint, timeoutOverride, additionalHeaders)
    }
}
