import Foundation

// MARK: - HTTP Status Codes

private enum HTTPStatusCode {
    static let notModified: Int = 304
}

/// The main network client for executing API requests.
public final class NetworkClient: NetworkClientProtocol, Sendable {
    private let environment: NetworkEnvironment
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
        environment: NetworkEnvironment,
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
        var urlRequest: URLRequest = try URLRequest(
            endpoint: endpoint,
            environment: environment,
            additionalHeaders: additionalHeaders,
            timeoutOverride: timeoutOverride,
            encoder: encoder
        )

        var cachedData: Data?
        var cachedMetadata: CacheMetadata?

        if endpoint.method == .get, let cache {
            switch endpoint.cachePolicy {
            case .noCache:
                break

            case .respectHeaders, .always, .overrideTTL:
                let cacheResult: CacheRetrievalResult = await cache.retrieveWithMetadata(for: urlRequest)

                switch cacheResult {
                case .fresh(let data, _):
                    return try decodeResponse(data, for: endpoint)

                case .stale(let data, let metadata):
                    cachedData = data
                    cachedMetadata = metadata
                    addConditionalHeaders(to: &urlRequest, from: metadata)

                case .needsRevalidation(let data, let metadata):
                    cachedData = data
                    cachedMetadata = metadata
                    addConditionalHeaders(to: &urlRequest, from: metadata)

                case .miss:
                    break
                }
            }
        }

        for interceptor in interceptors {
            urlRequest = try await interceptor.intercept(request: urlRequest)
        }

        var lastError: Error?
        let maxAttempts: Int = (retryPolicy?.maxRetries ?? 0) + 1

        for attempt in 0..<maxAttempts {
            do {
                if attempt > 0, let policy = retryPolicy {
                    let delay: TimeInterval = policy.delay(for: attempt - 1)
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }

                let (data, response): (Data, HTTPURLResponse) = try await performRequest(urlRequest)

                if response.statusCode == HTTPStatusCode.notModified, let cachedData, let cache {
                    await cache.updateAfterRevalidation(for: urlRequest, response: response)
                    return try decodeResponse(cachedData, for: endpoint)
                }

                var responseData: Data = data
                for interceptor in interceptors.reversed() {
                    responseData = try await interceptor.intercept(response: response, data: responseData)
                }

                try validateResponse(response)

                if endpoint.method == .get, let cache {
                    await cacheResponse(
                        data: responseData,
                        request: urlRequest,
                        response: response,
                        endpoint: endpoint,
                        cache: cache
                    )
                }

                return try decodeResponse(responseData, for: endpoint)

            } catch {
                if let networkError = error as? NetworkError,
                   case .serverError = networkError,
                   let cachedData,
                   let cachedMetadata,
                   let staleIfError = cachedMetadata.cacheControl?.staleIfError,
                   cachedMetadata.isStaleButRevalidatable(within: staleIfError) {
                    return try decodeResponse(cachedData, for: endpoint)
                }

                lastError = error

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

    // MARK: - Private Helpers

    /// Adds conditional headers (If-None-Match, If-Modified-Since) to a request.
    private func addConditionalHeaders(to request: inout URLRequest, from metadata: CacheMetadata) {
        if let etag = metadata.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = metadata.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
    }

    /// Caches a response according to endpoint and server cache policies.
    private func cacheResponse<E: Endpoint>(
        data: Data,
        request: URLRequest,
        response: HTTPURLResponse,
        endpoint: E,
        cache: ResponseCache
    ) async {
        switch endpoint.cachePolicy {
        case .noCache:
            return

        case .respectHeaders:
            await cache.store(data: data, for: request, response: response)

        case .always(let ttl):
            await cache.store(data: data, for: request, ttl: ttl)

        case .overrideTTL(let ttl):
            let cacheControl: CacheControlDirective? = CacheControlParser.parse(
                response.value(forHTTPHeaderField: "Cache-Control")
            )
            if let cacheControl, cacheControl.noStore {
                return
            }
            await cache.store(data: data, for: request, ttl: ttl)
        }
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
        case 200..<204, 205..<300:
            return
        case 204:
            throw NetworkError.noContent
        case 401:
            throw NetworkError.unauthorized
        case 403:
            throw NetworkError.forbidden
        case 404:
            throw NetworkError.notFound
        case 408:
            throw NetworkError.timeout
        case 500..<600:
            throw NetworkError.serverError(statusCode: response.statusCode)
        default:
            throw NetworkError.serverError(statusCode: response.statusCode)
        }
    }

    /// Decodes the response data.
    private func decodeResponse<E: Endpoint>(_ data: Data, for endpoint: E) throws -> E.Response {
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
