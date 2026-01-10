import Foundation

/// The main network client for executing API requests.
public final class NetworkClient: NetworkClientProtocol, Sendable {
    private let environment: Environment
    private let interceptors: [any Interceptor]
    private let retryPolicy: RetryPolicy?
    private let cache: ResponseCache?
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// Creates a network client.
    /// - Parameters:
    ///   - environment: The environment configuration.
    ///   - interceptors: Request/response interceptors to apply.
    ///   - retryPolicy: Optional retry policy for failed requests.
    ///   - cache: Optional response cache.
    ///   - session: The URLSession to use. Defaults to `.shared`.
    ///   - decoder: The JSON decoder for responses. Defaults to `JSONDecoder()`.
    ///   - encoder: The JSON encoder for request bodies. Defaults to `JSONEncoder()`.
    public init(
        environment: Environment,
        interceptors: [any Interceptor] = [],
        retryPolicy: RetryPolicy? = nil,
        cache: ResponseCache? = nil,
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder()
    ) {
        self.environment = environment
        self.interceptors = interceptors
        self.retryPolicy = retryPolicy
        self.cache = cache
        self.session = session
        self.decoder = decoder
        self.encoder = encoder
    }

    /// Executes a request for the given endpoint.
    /// - Parameter endpoint: The endpoint to request.
    /// - Returns: The decoded response.
    public func request<E: Endpoint>(_ endpoint: E) async throws -> E.Response {
        try await execute(endpoint: endpoint, additionalHeaders: [:], timeoutOverride: nil)
    }

    /// Creates a request builder for fluent configuration.
    /// - Parameter endpoint: The endpoint to configure.
    /// - Returns: A request builder for chaining options.
    public func request<E: Endpoint>(_ endpoint: E) -> RequestBuilder<E> {
        RequestBuilder(endpoint: endpoint) { [self] endpoint, timeout, headers in
            try await execute(endpoint: endpoint, additionalHeaders: headers, timeoutOverride: timeout)
        }
    }

    /// Executes the request with all configuration applied.
    private func execute<E: Endpoint>(
        endpoint: E,
        additionalHeaders: [String: String],
        timeoutOverride: TimeInterval?
    ) async throws -> E.Response {
        // Build the initial request
        var urlRequest = try URLRequest(
            endpoint: endpoint,
            environment: environment,
            additionalHeaders: additionalHeaders,
            timeoutOverride: timeoutOverride,
            encoder: encoder
        )

        // Check cache for GET requests
        if endpoint.method == .get, let cache {
            if let cachedData = await cache.retrieve(for: urlRequest) {
                return try decodeResponse(cachedData, for: endpoint)
            }
        }

        // Apply request interceptors (in order)
        for interceptor in interceptors {
            urlRequest = try await interceptor.intercept(request: urlRequest)
        }

        // Execute with retry logic
        var lastError: Error?
        let maxAttempts = (retryPolicy?.maxRetries ?? 0) + 1

        for attempt in 0..<maxAttempts {
            do {
                // Wait for retry delay (skip first attempt)
                if attempt > 0, let policy = retryPolicy {
                    let delay = policy.delay(for: attempt - 1)
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }

                let (data, response) = try await performRequest(urlRequest)

                // Apply response interceptors (in reverse order)
                var responseData = data
                for interceptor in interceptors.reversed() {
                    responseData = try await interceptor.intercept(response: response, data: responseData)
                }

                // Map status code to error if needed
                try validateResponse(response)

                // Cache successful GET responses
                if endpoint.method == .get, let cache {
                    await cache.store(data: responseData, for: urlRequest, ttl: 300)
                }

                // Decode and return
                return try decodeResponse(responseData, for: endpoint)

            } catch {
                lastError = error

                // Check if we should retry
                if let policy = retryPolicy,
                   let networkError = error as? NetworkError,
                   policy.shouldRetry(error: networkError, attempt: attempt) {
                    continue
                }

                throw error
            }
        }

        throw lastError ?? NetworkError.unknown(NSError(domain: "NetKit", code: -1))
    }

    /// Performs the actual network request.
    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)

        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw mapURLError(urlError)
        } catch {
            throw NetworkError.unknown(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.unknown(NSError(domain: "NetKit", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid response type"
            ]))
        }

        return (data, httpResponse)
    }

    /// Validates the HTTP response status code.
    private func validateResponse(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw NetworkError.unauthorized
        case 403:
            throw NetworkError.forbidden
        case 404:
            throw NetworkError.notFound
        case 500..<600:
            throw NetworkError.serverError(statusCode: response.statusCode)
        default:
            throw NetworkError.serverError(statusCode: response.statusCode)
        }
    }

    /// Decodes the response data.
    private func decodeResponse<E: Endpoint>(_ data: Data, for endpoint: E) throws -> E.Response {
        // Handle EmptyResponse specially
        if E.Response.self == EmptyResponse.self {
            return EmptyResponse() as! E.Response
        }

        do {
            return try decoder.decode(E.Response.self, from: data)
        } catch {
            throw NetworkError.decodingError(error)
        }
    }

    /// Maps URLError to NetworkError.
    private func mapURLError(_ error: URLError) -> NetworkError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .noConnection
        case .timedOut:
            return .timeout
        case .badURL, .unsupportedURL:
            return .invalidURL
        default:
            return .unknown(error)
        }
    }
}
