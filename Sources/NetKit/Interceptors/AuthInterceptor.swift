import Foundation

/// An interceptor that injects authentication headers into requests.
public struct AuthInterceptor: Interceptor, Sendable {
    /// A closure that provides the authentication token.
    private let tokenProvider: @Sendable () async throws -> String?

    /// A closure called when a 401 response is received, allowing token refresh.
    private let onUnauthorized: (@Sendable () async throws -> Void)?

    /// The header name for the authorization token.
    private let headerName: String

    /// The prefix for the token value (e.g., "Bearer").
    private let tokenPrefix: String?

    /// Creates an auth interceptor with a token provider.
    /// - Parameters:
    ///   - headerName: The header name to use. Defaults to "Authorization".
    ///   - tokenPrefix: Optional prefix for the token (e.g., "Bearer"). Defaults to "Bearer".
    ///   - tokenProvider: A closure that returns the current auth token.
    ///   - onUnauthorized: Optional closure called when a 401 response is received.
    public init(
        headerName: String = "Authorization",
        tokenPrefix: String? = "Bearer",
        tokenProvider: @escaping @Sendable () async throws -> String?,
        onUnauthorized: (@Sendable () async throws -> Void)? = nil
    ) {
        self.headerName = headerName
        self.tokenPrefix = tokenPrefix
        self.tokenProvider = tokenProvider
        self.onUnauthorized = onUnauthorized
    }

    public func intercept(request: URLRequest) async throws -> URLRequest {
        guard let token = try await tokenProvider() else {
            return request
        }

        var modifiedRequest = request
        let headerValue: String
        if let prefix = tokenPrefix {
            headerValue = "\(prefix) \(token)"
        } else {
            headerValue = token
        }
        modifiedRequest.setValue(headerValue, forHTTPHeaderField: headerName)
        return modifiedRequest
    }

    public func intercept(response: HTTPURLResponse, data: Data) async throws -> Data {
        if response.statusCode == 401, let onUnauthorized {
            try await onUnauthorized()
        }
        return data
    }
}
