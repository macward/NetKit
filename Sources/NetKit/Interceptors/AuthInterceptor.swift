import Foundation

/// An actor that coordinates token refresh operations to prevent multiple concurrent refreshes.
///
/// When multiple concurrent requests receive 401 responses, this coordinator ensures that
/// only one token refresh operation is performed. All subsequent 401 handlers wait for the
/// ongoing refresh to complete and receive its result.
public actor TokenRefreshCoordinator {
    /// The closure that performs the actual token refresh.
    private let refreshHandler: @Sendable () async throws -> Void

    /// Tracks whether a refresh is currently in progress.
    private var isRefreshing: Bool = false

    /// Continuations waiting for the current refresh to complete.
    private var waiters: [CheckedContinuation<Void, Error>] = []

    /// Creates a new token refresh coordinator.
    /// - Parameter refreshHandler: The closure that performs the actual token refresh.
    public init(refreshHandler: @escaping @Sendable () async throws -> Void) {
        self.refreshHandler = refreshHandler
    }

    /// Performs a token refresh, coordinating with other concurrent requests.
    ///
    /// If a refresh is already in progress, this method waits for it to complete
    /// rather than starting a new refresh. If no refresh is in progress, this method
    /// starts one and notifies all waiters when it completes.
    ///
    /// - Throws: Any error from the refresh handler, propagated to all waiters.
    public func refreshIfNeeded() async throws {
        if isRefreshing {
            // A refresh is already in progress, wait for it to complete
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(continuation)
            }
            return
        }

        // Start the refresh
        isRefreshing = true

        do {
            try await refreshHandler()
            // Notify all waiters of success
            let currentWaiters = waiters
            waiters = []
            isRefreshing = false
            for waiter in currentWaiters {
                waiter.resume()
            }
        } catch {
            // Notify all waiters of failure
            let currentWaiters = waiters
            waiters = []
            isRefreshing = false
            for waiter in currentWaiters {
                waiter.resume(throwing: error)
            }
            throw error
        }
    }
}

/// An interceptor that injects authentication headers into requests.
public struct AuthInterceptor: Interceptor, Sendable {
    /// A closure that provides the authentication token.
    private let tokenProvider: @Sendable () async throws -> String?

    /// A closure called when a 401 response is received, allowing token refresh.
    private let onUnauthorized: (@Sendable () async throws -> Void)?

    /// Optional coordinator for managing concurrent token refreshes.
    private let refreshCoordinator: TokenRefreshCoordinator?

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
        self.refreshCoordinator = nil
    }

    /// Creates an auth interceptor with coordinated token refresh.
    ///
    /// This initializer enables coordination of concurrent 401 responses, ensuring that
    /// multiple simultaneous 401s trigger only ONE token refresh operation. All waiting
    /// requests receive the result of that single refresh.
    ///
    /// - Parameters:
    ///   - headerName: The header name to use. Defaults to "Authorization".
    ///   - tokenPrefix: Optional prefix for the token (e.g., "Bearer"). Defaults to "Bearer".
    ///   - tokenProvider: A closure that returns the current auth token.
    ///   - refreshCoordinator: A coordinator that manages concurrent token refresh operations.
    public init(
        headerName: String = "Authorization",
        tokenPrefix: String? = "Bearer",
        tokenProvider: @escaping @Sendable () async throws -> String?,
        refreshCoordinator: TokenRefreshCoordinator
    ) {
        self.headerName = headerName
        self.tokenPrefix = tokenPrefix
        self.tokenProvider = tokenProvider
        self.onUnauthorized = nil
        self.refreshCoordinator = refreshCoordinator
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
        if response.statusCode == 401 {
            if let coordinator = refreshCoordinator {
                // Use coordinated refresh
                try await coordinator.refreshIfNeeded()
            } else if let onUnauthorized {
                // Use legacy uncoordinated refresh
                try await onUnauthorized()
            }
        }
        return data
    }
}
