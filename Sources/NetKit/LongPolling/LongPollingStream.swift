import Foundation

/// An AsyncSequence that yields responses from a long polling endpoint.
///
/// Use this with `for await` to continuously receive updates from the server:
/// ```swift
/// for await messages in client.poll(MessagesEndpoint()) {
///     print("Received: \(messages)")
/// }
/// ```
///
/// The stream automatically:
/// - Reconnects after timeouts or empty responses
/// - Respects the endpoint's `pollingTimeout` and `retryInterval`
/// - Stops when the task is cancelled or `shouldContinuePolling` returns false
public struct LongPollingStream<E: LongPollingEndpoint>: AsyncSequence, Sendable {
    public typealias Element = E.Response

    private let endpoint: E
    private let client: NetworkClient
    private let configuration: LongPollingConfiguration?

    /// Creates a long polling stream.
    /// - Parameters:
    ///   - endpoint: The long polling endpoint.
    ///   - client: The network client to use for requests.
    ///   - configuration: Optional configuration override.
    init(
        endpoint: E,
        client: NetworkClient,
        configuration: LongPollingConfiguration? = nil
    ) {
        self.endpoint = endpoint
        self.client = client
        self.configuration = configuration
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            endpoint: endpoint,
            client: client,
            configuration: configuration
        )
    }

    /// The async iterator that performs the actual polling.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private let endpoint: E
        private let client: NetworkClient
        private let pollingTimeout: TimeInterval
        private let retryInterval: TimeInterval
        private let maxConsecutiveErrors: Int?

        private var consecutiveErrors: Int = 0
        private var shouldContinue: Bool = true

        init(
            endpoint: E,
            client: NetworkClient,
            configuration: LongPollingConfiguration?
        ) {
            self.endpoint = endpoint
            self.client = client
            self.pollingTimeout = configuration?.timeout ?? endpoint.pollingTimeout
            self.retryInterval = configuration?.retryInterval ?? endpoint.retryInterval
            self.maxConsecutiveErrors = configuration?.maxConsecutiveErrors ?? 5
        }

        public mutating func next() async -> E.Response? {
            guard shouldContinue else { return nil }

            // Check for task cancellation
            guard !Task.isCancelled else {
                shouldContinue = false
                return nil
            }

            do {
                // Perform the poll request with extended timeout
                let response = try await performPollRequest()

                // Reset error counter on success
                consecutiveErrors = 0

                // Check if we should continue polling
                if !endpoint.shouldContinuePolling(after: response) {
                    shouldContinue = false
                }

                return response

            } catch let error as NetworkError {
                return await handleError(error)
            } catch {
                return await handleError(.unknown(error))
            }
        }

        /// Performs a single poll request.
        private func performPollRequest() async throws -> E.Response {
            try await client
                .request(endpoint)
                .timeout(pollingTimeout)
                .send()
        }

        /// Handles errors during polling.
        private mutating func handleError(_ error: NetworkError) async -> E.Response? {
            consecutiveErrors += 1

            // Check if we've exceeded max consecutive errors
            if let max = maxConsecutiveErrors, consecutiveErrors >= max {
                shouldContinue = false
                return nil
            }

            // Check for task cancellation before sleeping
            guard !Task.isCancelled else {
                shouldContinue = false
                return nil
            }

            switch error {
            case .timeout:
                // Timeout is expected in long polling - reconnect immediately
                return await continuePolling(delay: 0)

            case .noContent:
                // 204 No Content - no new data, poll again after interval
                return await continuePolling(delay: retryInterval)

            case .noConnection:
                // Wait longer before retrying on connection issues
                return await continuePolling(delay: retryInterval * 2)

            case .serverError(let statusCode):
                if statusCode == 408 {
                    // 408 Request Timeout - reconnect immediately
                    return await continuePolling(delay: 0)
                } else if statusCode >= 500 {
                    // Server errors - wait and retry
                    return await continuePolling(delay: retryInterval)
                } else {
                    // Other errors - stop polling
                    shouldContinue = false
                    return nil
                }

            case .unauthorized, .forbidden, .notFound:
                // Client errors - stop polling
                shouldContinue = false
                return nil

            case .invalidURL, .encodingError, .decodingError:
                // Fatal errors - stop polling
                shouldContinue = false
                return nil

            case .unknown:
                // Unknown errors - wait and retry
                return await continuePolling(delay: retryInterval)
            }
        }

        /// Waits for the specified delay and then continues to the next poll.
        private mutating func continuePolling(delay: TimeInterval) async -> E.Response? {
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    // Task was cancelled during sleep
                    shouldContinue = false
                    return nil
                }
            }

            // Recursively call next() to continue the polling loop
            return await next()
        }
    }
}

// MARK: - NetworkClient Extension

public extension NetworkClient {
    /// Starts long polling on the specified endpoint.
    ///
    /// Returns an AsyncSequence that yields responses as they arrive from the server.
    /// The polling continues until:
    /// - The task is cancelled
    /// - `shouldContinuePolling` returns false
    /// - Too many consecutive errors occur
    ///
    /// Example:
    /// ```swift
    /// for await messages in client.poll(MessagesEndpoint()) {
    ///     print("New messages: \(messages)")
    /// }
    /// ```
    ///
    /// - Parameter endpoint: The long polling endpoint to poll.
    /// - Returns: An AsyncSequence of responses.
    func poll<E: LongPollingEndpoint>(_ endpoint: E) -> LongPollingStream<E> {
        LongPollingStream(endpoint: endpoint, client: self)
    }

    /// Starts long polling with custom configuration.
    ///
    /// - Parameters:
    ///   - endpoint: The long polling endpoint to poll.
    ///   - configuration: Custom polling configuration.
    /// - Returns: An AsyncSequence of responses.
    func poll<E: LongPollingEndpoint>(
        _ endpoint: E,
        configuration: LongPollingConfiguration
    ) -> LongPollingStream<E> {
        LongPollingStream(endpoint: endpoint, client: self, configuration: configuration)
    }
}

// MARK: - Convenience Methods

public extension LongPollingStream {
    /// Creates a stream that stops after receiving a specific number of responses.
    /// - Parameter count: Maximum number of responses to receive.
    /// - Returns: An AsyncSequence limited to the specified count.
    func first(_ count: Int) -> AsyncPrefixSequence<LongPollingStream<E>> {
        self.prefix(count)
    }

    /// Creates a stream that stops when a condition is met.
    /// - Parameter predicate: A closure that returns `true` to continue, `false` to stop.
    /// - Returns: An AsyncSequence that stops when the predicate returns false.
    func `while`(_ predicate: @escaping @Sendable (E.Response) -> Bool) -> AsyncPrefixWhileSequence<LongPollingStream<E>> {
        self.prefix(while: predicate)
    }
}
