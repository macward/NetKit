import Foundation

/// Defines an endpoint that supports long polling behavior.
///
/// Long polling keeps a connection open until the server has data to send
/// or a timeout occurs. This protocol extends `Endpoint` with polling-specific
/// configuration.
///
/// Example:
/// ```swift
/// struct MessagesEndpoint: LongPollingEndpoint {
///     var path: String { "/messages/poll" }
///     var method: HTTPMethod { .get }
///     var pollingTimeout: TimeInterval { 30 }
///     typealias Response = [Message]
/// }
/// ```
public protocol LongPollingEndpoint: Endpoint {
    /// The timeout for each polling request in seconds.
    /// This is how long the server will hold the connection open waiting for data.
    /// Defaults to 30 seconds.
    var pollingTimeout: TimeInterval { get }

    /// The delay between polling attempts after receiving an empty response.
    /// Defaults to 1 second.
    var retryInterval: TimeInterval { get }

    /// Determines whether polling should continue after receiving a response.
    /// Return `false` to stop the polling loop.
    /// Defaults to always continue (`true`).
    /// - Parameter response: The response received from the server.
    /// - Returns: `true` to continue polling, `false` to stop.
    func shouldContinuePolling(after response: Response) -> Bool
}

// MARK: - Default Implementations

public extension LongPollingEndpoint {
    var pollingTimeout: TimeInterval { 30 }
    var retryInterval: TimeInterval { 1 }

    func shouldContinuePolling(after response: Response) -> Bool {
        true
    }
}

// MARK: - Configuration Presets

/// Reusable configuration presets for long polling behavior.
public struct LongPollingConfiguration: Sendable, Equatable {
    /// The timeout for each polling request.
    public let timeout: TimeInterval

    /// The delay between polling attempts.
    public let retryInterval: TimeInterval

    /// Maximum number of consecutive errors before stopping. `nil` means unlimited.
    public let maxConsecutiveErrors: Int?

    /// Creates a custom long polling configuration.
    /// - Parameters:
    ///   - timeout: The timeout for each polling request. Defaults to 30 seconds.
    ///   - retryInterval: The delay between polling attempts. Defaults to 1 second.
    ///   - maxConsecutiveErrors: Maximum consecutive errors before stopping. Defaults to 5.
    public init(
        timeout: TimeInterval = 30,
        retryInterval: TimeInterval = 1,
        maxConsecutiveErrors: Int? = 5
    ) {
        self.timeout = timeout
        self.retryInterval = retryInterval
        self.maxConsecutiveErrors = maxConsecutiveErrors
    }
}

// MARK: - Preset Configurations

public extension LongPollingConfiguration {
    /// Short polling with 10 second timeout.
    /// Suitable for real-time updates where low latency is critical.
    static let short = LongPollingConfiguration(
        timeout: 10,
        retryInterval: 0.5,
        maxConsecutiveErrors: 10
    )

    /// Standard polling with 30 second timeout.
    /// Balanced between responsiveness and server load.
    static let standard = LongPollingConfiguration(
        timeout: 30,
        retryInterval: 1,
        maxConsecutiveErrors: 5
    )

    /// Long polling with 60 second timeout.
    /// Reduces server load for less time-sensitive updates.
    static let long = LongPollingConfiguration(
        timeout: 60,
        retryInterval: 2,
        maxConsecutiveErrors: 3
    )

    /// Aggressive polling with minimal delays.
    /// Use sparingly, suitable for critical real-time applications.
    static let realtime = LongPollingConfiguration(
        timeout: 15,
        retryInterval: 0.1,
        maxConsecutiveErrors: 20
    )
}

// MARK: - Polling State

/// Represents the current state of a long polling operation.
public enum LongPollingState: Sendable, Equatable {
    /// Polling has not started yet.
    case idle
    /// Currently waiting for a response from the server.
    case polling
    /// Waiting before the next poll attempt.
    case waiting(retryIn: TimeInterval)
    /// Polling was cancelled.
    case cancelled
    /// Polling stopped due to an error.
    case failed(NetworkError)
    /// Polling stopped because `shouldContinuePolling` returned false.
    case completed
}
