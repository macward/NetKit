import Foundation

/// Intercepts network requests and responses for modification or inspection.
public protocol Interceptor: Sendable {
    /// Intercepts and optionally modifies an outgoing request.
    /// - Parameter request: The original request.
    /// - Returns: The modified (or original) request.
    func intercept(request: URLRequest) async throws -> URLRequest

    /// Intercepts and optionally modifies an incoming response.
    /// - Parameters:
    ///   - response: The HTTP response.
    ///   - data: The response body data.
    /// - Returns: The modified (or original) data.
    func intercept(response: HTTPURLResponse, data: Data) async throws -> Data
}

public extension Interceptor {
    func intercept(request: URLRequest) async throws -> URLRequest {
        request
    }

    func intercept(response: HTTPURLResponse, data: Data) async throws -> Data {
        data
    }
}
