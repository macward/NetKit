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
            // Iterative polling loop - avoids stack accumulation from recursion
            while shouldContinue {
                // Check for task cancellation at start of each iteration
                guard !Task.isCancelled else {
                    shouldContinue = false
                    return nil
                }

                do {
                    // Perform the poll request with extended timeout
                    let response: E.Response = try await performPollRequest()

                    // Reset error counter on success
                    consecutiveErrors = 0

                    // Check if we should continue polling
                    if !endpoint.shouldContinuePolling(after: response) {
                        shouldContinue = false
                    }

                    return response

                } catch let error as NetworkError {
                    let delay: TimeInterval? = delayForError(error)

                    // nil delay means fatal error - stop polling
                    guard let retryDelay = delay else {
                        shouldContinue = false
                        return nil
                    }

                    // Wait before next iteration (if needed)
                    if retryDelay > 0 {
                        let sleepCancelled: Bool = await sleep(for: retryDelay)
                        if sleepCancelled {
                            return nil
                        }
                    }
                    // Continue to next iteration of the while loop

                } catch {
                    let delay: TimeInterval? = delayForError(NetworkError.unknown(underlyingError: error))

                    guard let retryDelay = delay else {
                        shouldContinue = false
                        return nil
                    }

                    if retryDelay > 0 {
                        let sleepCancelled: Bool = await sleep(for: retryDelay)
                        if sleepCancelled {
                            return nil
                        }
                    }
                }
            }

            return nil
        }

        /// Performs a single poll request.
        private func performPollRequest() async throws -> E.Response {
            try await client
                .request(endpoint)
                .timeout(pollingTimeout)
                .send()
        }

        /// Determines the delay before retrying after an error.
        /// Returns nil for fatal errors that should stop polling.
        private mutating func delayForError(_ error: NetworkError) -> TimeInterval? {
            consecutiveErrors += 1

            // Check if we've exceeded max consecutive errors
            if let max = maxConsecutiveErrors, consecutiveErrors >= max {
                return nil
            }

            // Note: Task cancellation is checked by the caller in the main loop
            // before calling this method, so no need to check here.

            switch error.kind {
            case .timeout:
                // Timeout is expected in long polling - reconnect immediately
                return 0

            case .noContent:
                // 204 No Content - no new data, poll again after interval
                return retryInterval

            case .noConnection:
                // Wait longer before retrying on connection issues
                return retryInterval * 2

            case .serverError(let statusCode):
                if statusCode == 408 {
                    // 408 Request Timeout - reconnect immediately
                    return 0
                } else {
                    // Server errors - wait and retry
                    return retryInterval
                }

            case .badGateway, .serviceUnavailable, .gatewayTimeout:
                // Server errors - wait and retry
                return retryInterval

            case .rateLimited:
                // Rate limited - wait longer before retry
                return retryInterval * 3

            case .unauthorized, .forbidden, .notFound:
                // Client errors - stop polling
                return nil

            case .clientError:
                // Other client errors - stop polling
                return nil

            case .invalidURL, .encodingFailed, .decodingFailed:
                // Fatal errors - stop polling
                return nil

            case .unknown:
                // Unknown errors - wait and retry
                return retryInterval
            }
        }

        /// Sleeps for the specified duration.
        /// Returns true if sleep was cancelled, false otherwise.
        private func sleep(for delay: TimeInterval) async -> Bool {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return false
            } catch {
                // Task was cancelled during sleep
                // The caller will check Task.isCancelled and set shouldContinue appropriately
                return true
            }
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
