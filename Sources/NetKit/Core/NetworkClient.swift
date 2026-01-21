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
                    let requestSnapshot: RequestSnapshot = RequestSnapshot(request: urlRequest)
                    return try decodeResponse(data, for: endpoint, request: requestSnapshot, response: nil)

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

        let requestSnapshot: RequestSnapshot = RequestSnapshot(request: urlRequest)
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
                let responseSnapshot: ResponseSnapshot = ResponseSnapshot(response: response, data: data)

                if response.statusCode == HTTPStatusCode.notModified, let cachedData, let cache {
                    await cache.updateAfterRevalidation(for: urlRequest, response: response)
                    return try decodeResponse(
                        cachedData,
                        for: endpoint,
                        request: requestSnapshot,
                        response: responseSnapshot
                    )
                }

                var responseData: Data = data
                for interceptor in interceptors.reversed() {
                    responseData = try await interceptor.intercept(response: response, data: responseData)
                }

                try validateResponse(response, request: requestSnapshot, data: responseData)

                if endpoint.method == .get, let cache {
                    await cacheResponse(
                        data: responseData,
                        request: urlRequest,
                        response: response,
                        endpoint: endpoint,
                        cache: cache
                    )
                }

                return try decodeResponse(
                    responseData,
                    for: endpoint,
                    request: requestSnapshot,
                    response: responseSnapshot
                )

            } catch {
                if let networkError = error as? NetworkError,
                   networkError.kind.isServerError,
                   let cachedData,
                   let cachedMetadata,
                   let staleIfError = cachedMetadata.cacheControl?.staleIfError,
                   cachedMetadata.isStaleButRevalidatable(within: staleIfError) {
                    return try decodeResponse(
                        cachedData,
                        for: endpoint,
                        request: requestSnapshot,
                        response: nil
                    )
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

        throw lastError ?? NetworkError.unknown(
            request: requestSnapshot,
            underlyingError: NSError(domain: "NetKit", code: -1)
        )
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
        let requestSnapshot: RequestSnapshot = RequestSnapshot(request: request)

        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw mapURLError(urlError, request: requestSnapshot)
        } catch {
            throw NetworkError.unknown(request: requestSnapshot, underlyingError: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.unknown(
                request: requestSnapshot,
                underlyingError: NSError(domain: "NetKit", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid response type"
                ])
            )
        }

        return (data, httpResponse)
    }

    /// Validates the HTTP response status code.
    private func validateResponse(
        _ response: HTTPURLResponse,
        request: RequestSnapshot,
        data: Data?
    ) throws {
        switch response.statusCode {
        case 200..<204, 205..<300:
            return
        case 204:
            throw NetworkError.noContent(
                request: request,
                response: ResponseSnapshot(response: response, data: data)
            )
        default:
            throw NetworkError.fromStatusCode(
                response.statusCode,
                request: request,
                response: ResponseSnapshot(response: response, data: data)
            )
        }
    }

    /// Decodes the response data.
    private func decodeResponse<E: Endpoint>(
        _ data: Data,
        for endpoint: E,
        request: RequestSnapshot,
        response: ResponseSnapshot?
    ) throws -> E.Response {
        if E.Response.self == EmptyResponse.self,
           let emptyResponse = EmptyResponse() as? E.Response {
            return emptyResponse
        }

        do {
            return try decoder.decode(E.Response.self, from: data)
        } catch {
            throw NetworkError.decodingFailed(
                request: request,
                response: response,
                underlyingError: error
            )
        }
    }

    /// Maps URLError to NetworkError.
    private func mapURLError(_ error: URLError, request: RequestSnapshot) -> NetworkError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .noConnection(request: request, underlyingError: error)
        case .timedOut:
            return .timeout(request: request, underlyingError: error)
        case .badURL, .unsupportedURL:
            return .invalidURL(request: request, underlyingError: error)
        default:
            return .unknown(request: request, underlyingError: error)
        }
    }
}

// MARK: - Upload & Download

extension NetworkClient {
    /// Uploads a file to the specified endpoint with progress tracking.
    /// - Parameters:
    ///   - file: The URL of the file to upload.
    ///   - endpoint: The endpoint to upload to.
    /// - Returns: An `UploadResult` containing progress stream and response task.
    public func upload<E: Endpoint>(file: URL, to endpoint: E) -> UploadResult<E.Response> {
        let (stream, continuation) = AsyncStream<TransferProgress>.makeStream()

        let responseTask: Task<E.Response, Error> = Task {
            try await performUpload(
                endpoint: endpoint,
                fileURL: file,
                formData: nil,
                continuation: continuation
            )
        }

        return UploadResult(
            progress: TransferProgressStream(stream: stream),
            response: responseTask
        )
    }

    /// Uploads multipart form data to the specified endpoint with progress tracking.
    /// - Parameters:
    ///   - formData: The multipart form data to upload.
    ///   - endpoint: The endpoint to upload to.
    /// - Returns: An `UploadResult` containing progress stream and response task.
    public func upload<E: Endpoint>(formData: MultipartFormData, to endpoint: E) -> UploadResult<E.Response> {
        let encodedFormData: EncodedMultipartFormData = EncodedMultipartFormData(from: formData)
        let (stream, continuation) = AsyncStream<TransferProgress>.makeStream()

        let responseTask: Task<E.Response, Error> = Task {
            try await performUpload(
                endpoint: endpoint,
                fileURL: nil,
                formData: encodedFormData,
                continuation: continuation
            )
        }

        return UploadResult(
            progress: TransferProgressStream(stream: stream),
            response: responseTask
        )
    }

    /// Downloads a file from the specified endpoint with progress tracking.
    ///
    /// - Note: Downloads do not support automatic retry. If a download fails, you must
    ///   initiate a new download request. This is because download tasks write directly
    ///   to disk and partial downloads cannot be safely resumed with the current implementation.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint to download from.
    ///   - destination: The URL where the file should be saved.
    /// - Returns: A `DownloadResult` containing progress stream and response task.
    public func download<E: Endpoint>(from endpoint: E, to destination: URL) -> DownloadResult {
        let (stream, continuation) = AsyncStream<TransferProgress>.makeStream()

        let responseTask: Task<URL, Error> = Task {
            try await performDownload(
                endpoint: endpoint,
                destination: destination,
                continuation: continuation
            )
        }

        return DownloadResult(
            progress: TransferProgressStream(stream: stream),
            response: responseTask
        )
    }

    // MARK: - Private Upload Implementation

    private func performUpload<E: Endpoint>(
        endpoint: E,
        fileURL: URL?,
        formData: EncodedMultipartFormData?,
        continuation: AsyncStream<TransferProgress>.Continuation
    ) async throws -> E.Response {
        // Validate file exists before attempting upload
        if let fileURL {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                continuation.finish()
                throw NetworkError.invalidURL(
                    request: nil,
                    underlyingError: NSError(
                        domain: "NetKit",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "File does not exist at path: \(fileURL.path)"]
                    )
                )
            }
        }

        var urlRequest: URLRequest = try URLRequest(
            endpoint: endpoint,
            environment: environment,
            additionalHeaders: [:],
            timeoutOverride: nil,
            encoder: encoder
        )

        for interceptor in interceptors {
            urlRequest = try await interceptor.intercept(request: urlRequest)
        }

        if let formData {
            urlRequest.setValue(formData.contentType, forHTTPHeaderField: "Content-Type")
        }

        let requestSnapshot: RequestSnapshot = RequestSnapshot(request: urlRequest)
        let delegate: UploadProgressDelegate = UploadProgressDelegate(continuation: continuation)
        let uploadSession: URLSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )

        defer {
            uploadSession.finishTasksAndInvalidate()
        }

        var lastError: Error?
        let maxAttempts: Int = (retryPolicy?.maxRetries ?? 0) + 1

        for attempt in 0..<maxAttempts {
            do {
                if attempt > 0 {
                    delegate.reset()

                    if let policy = retryPolicy {
                        let delay: TimeInterval = policy.delay(for: attempt - 1)
                        if delay > 0 {
                            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        }
                    }
                }

                let (data, response): (Data, URLResponse)

                if let fileURL {
                    (data, response) = try await uploadSession.upload(for: urlRequest, fromFile: fileURL)
                } else if let formData {
                    (data, response) = try await uploadSession.upload(for: urlRequest, from: formData.data)
                } else {
                    throw NetworkError.unknown(
                        request: requestSnapshot,
                        underlyingError: NSError(
                            domain: "NetKit",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "No upload data provided"]
                        )
                    )
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.unknown(
                        request: requestSnapshot,
                        underlyingError: NSError(
                            domain: "NetKit",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Invalid response type"]
                        )
                    )
                }

                let responseSnapshot: ResponseSnapshot = ResponseSnapshot(response: httpResponse, data: data)

                var responseData: Data = data
                for interceptor in interceptors.reversed() {
                    responseData = try await interceptor.intercept(response: httpResponse, data: responseData)
                }

                try validateResponse(httpResponse, request: requestSnapshot, data: responseData)

                return try decodeResponse(responseData, for: endpoint, request: requestSnapshot, response: responseSnapshot)

            } catch let urlError as URLError {
                let networkError: NetworkError = mapURLError(urlError, request: requestSnapshot)
                lastError = networkError

                if let policy = retryPolicy, policy.shouldRetry(error: networkError, attempt: attempt) {
                    continue
                }
                throw networkError

            } catch let networkError as NetworkError {
                lastError = networkError

                if let policy = retryPolicy, policy.shouldRetry(error: networkError, attempt: attempt) {
                    continue
                }
                throw networkError

            } catch {
                lastError = error
                throw NetworkError.unknown(request: requestSnapshot, underlyingError: error)
            }
        }

        throw lastError ?? NetworkError.unknown(
            request: requestSnapshot,
            underlyingError: NSError(domain: "NetKit", code: -1)
        )
    }

    // MARK: - Private Download Implementation

    private func performDownload<E: Endpoint>(
        endpoint: E,
        destination: URL,
        continuation: AsyncStream<TransferProgress>.Continuation
    ) async throws -> URL {
        var urlRequest: URLRequest = try URLRequest(
            endpoint: endpoint,
            environment: environment,
            additionalHeaders: [:],
            timeoutOverride: nil,
            encoder: encoder
        )

        for interceptor in interceptors {
            urlRequest = try await interceptor.intercept(request: urlRequest)
        }

        let requestSnapshot: RequestSnapshot = RequestSnapshot(request: urlRequest)

        return try await withCheckedThrowingContinuation { checkedContinuation in
            let delegate: DownloadProgressDelegate = DownloadProgressDelegate(
                destination: destination,
                continuation: continuation
            ) { result in
                switch result {
                case .success(let url):
                    checkedContinuation.resume(returning: url)
                case .failure(let error):
                    if let urlError = error as? URLError {
                        let networkError: NetworkError = self.mapURLError(urlError, request: requestSnapshot)
                        checkedContinuation.resume(throwing: networkError)
                    } else if let networkError = error as? NetworkError {
                        checkedContinuation.resume(throwing: networkError)
                    } else {
                        checkedContinuation.resume(throwing: NetworkError.unknown(
                            request: requestSnapshot,
                            underlyingError: error
                        ))
                    }
                }
            }

            let downloadSession: URLSession = URLSession(
                configuration: session.configuration,
                delegate: delegate,
                delegateQueue: nil
            )
            delegate.setSession(downloadSession)

            let task: URLSessionDownloadTask = downloadSession.downloadTask(with: urlRequest)
            task.resume()
        }
    }
}
