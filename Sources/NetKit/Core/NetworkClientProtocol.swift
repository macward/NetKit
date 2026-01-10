import Foundation

/// A protocol for network clients, enabling dependency injection and testing.
public protocol NetworkClientProtocol: Sendable {
    /// Executes a request for the given endpoint.
    /// - Parameter endpoint: The endpoint to request.
    /// - Returns: The decoded response.
    /// - Throws: `NetworkError` if the request fails.
    func request<E: Endpoint>(_ endpoint: E) async throws -> E.Response
}
