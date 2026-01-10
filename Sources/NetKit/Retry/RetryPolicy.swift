import Foundation

/// Defines the delay strategy between retry attempts.
public enum RetryDelay: Sendable {
    /// No delay between retries.
    case immediate
    /// Fixed delay between retries.
    case fixed(TimeInterval)
    /// Exponential backoff with optional jitter.
    /// - Parameters:
    ///   - base: The initial delay duration.
    ///   - multiplier: The multiplier applied for each subsequent attempt.
    ///   - jitter: Random variation factor (0.0 to 1.0). Defaults to 0.
    case exponential(base: TimeInterval, multiplier: Double, jitter: Double = 0)

    /// Calculates the delay for a given attempt number.
    /// - Parameter attempt: The attempt number (0-based).
    /// - Returns: The delay in seconds.
    public func delay(for attempt: Int) -> TimeInterval {
        switch self {
        case .immediate:
            return 0
        case .fixed(let interval):
            return interval
        case .exponential(let base, let multiplier, let jitter):
            let exponentialDelay = base * pow(multiplier, Double(attempt))
            if jitter > 0 {
                let jitterRange = exponentialDelay * jitter
                let randomJitter = Double.random(in: -jitterRange...jitterRange)
                return max(0, exponentialDelay + randomJitter)
            }
            return exponentialDelay
        }
    }
}

/// Configures automatic retry behavior for failed requests.
public struct RetryPolicy: Sendable {
    /// Maximum number of retry attempts.
    public let maxRetries: Int

    /// The delay strategy between retries.
    public let delay: RetryDelay

    /// A closure that determines if an error should trigger a retry.
    private let shouldRetryError: @Sendable (NetworkError) -> Bool

    /// Creates a retry policy with custom configuration.
    /// - Parameters:
    ///   - maxRetries: Maximum number of retry attempts. Defaults to 3.
    ///   - delay: The delay strategy. Defaults to exponential backoff.
    ///   - shouldRetry: A closure that determines if an error is retryable.
    public init(
        maxRetries: Int = 3,
        delay: RetryDelay = .exponential(base: 1.0, multiplier: 2.0, jitter: 0.1),
        shouldRetry: @escaping @Sendable (NetworkError) -> Bool
    ) {
        self.maxRetries = maxRetries
        self.delay = delay
        self.shouldRetryError = shouldRetry
    }

    /// Creates a retry policy with default retryable errors.
    /// - Parameters:
    ///   - maxRetries: Maximum number of retry attempts. Defaults to 3.
    ///   - delay: The delay strategy. Defaults to exponential backoff.
    public init(
        maxRetries: Int = 3,
        delay: RetryDelay = .exponential(base: 1.0, multiplier: 2.0, jitter: 0.1)
    ) {
        self.maxRetries = maxRetries
        self.delay = delay
        self.shouldRetryError = Self.defaultShouldRetry
    }

    /// Determines if a request should be retried.
    /// - Parameters:
    ///   - error: The error that occurred.
    ///   - attempt: The current attempt number (0-based).
    /// - Returns: `true` if the request should be retried.
    public func shouldRetry(error: NetworkError, attempt: Int) -> Bool {
        guard attempt < maxRetries else { return false }
        return shouldRetryError(error)
    }

    /// Calculates the delay before the next retry attempt.
    /// - Parameter attempt: The current attempt number (0-based).
    /// - Returns: The delay in seconds.
    public func delay(for attempt: Int) -> TimeInterval {
        delay.delay(for: attempt)
    }

    /// Default retry logic: retry on connection issues, timeouts, and server errors.
    private static let defaultShouldRetry: @Sendable (NetworkError) -> Bool = { error in
        switch error {
        case .noConnection, .timeout:
            return true
        case .serverError(let statusCode):
            return statusCode >= 500
        default:
            return false
        }
    }
}
