import Foundation

/// An actor that coordinates token refresh operations to prevent multiple concurrent refreshes.
///
/// When multiple concurrent requests receive 401 responses, this coordinator ensures that
/// only one token refresh operation is performed. All subsequent 401 handlers wait for the
/// ongoing refresh to complete and receive its result.
///
/// Example:
/// ```swift
/// let coordinator = TokenRefreshCoordinator {
///     try await authService.refreshToken()
/// }
///
/// let interceptor = AuthInterceptor(
///     tokenProvider: { try await authService.getToken() },
///     refreshCoordinator: coordinator
/// )
/// ```
public actor TokenRefreshCoordinator {
    /// The closure that performs the actual token refresh.
    private let refreshHandler: @Sendable () async throws -> Void

    /// Tracks whether a refresh is currently in progress.
    private var isRefreshing: Bool = false

    /// Waiter entry with a unique identifier for cancellation support.
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Continuations waiting for the current refresh to complete.
    private var waiters: [Waiter] = []

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
    ///           Also throws `CancellationError` if the task is cancelled while waiting.
    public func refreshIfNeeded() async throws {
        if isRefreshing {
            // A refresh is already in progress, wait for it to complete
            let waiterId = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append(Waiter(id: waiterId, continuation: continuation))
                }
            } onCancel: {
                Task { await self.cancelWaiter(id: waiterId) }
            }
            return
        }

        // Start the refresh
        isRefreshing = true

        do {
            try await refreshHandler()
            completeWaiters(with: .success(()))
        } catch {
            completeWaiters(with: .failure(error))
            throw error
        }
    }

    /// Cancels a waiter by its ID, resuming with CancellationError.
    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    /// Completes all pending waiters with the given result.
    private func completeWaiters(with result: Result<Void, Error>) {
        let currentWaiters = waiters
        waiters = []
        isRefreshing = false

        for waiter in currentWaiters {
            switch result {
            case .success:
                waiter.continuation.resume()
            case .failure(let error):
                waiter.continuation.resume(throwing: error)
            }
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
