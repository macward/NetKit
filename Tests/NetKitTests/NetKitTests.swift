import Testing
import Foundation
@testable import NetKit

// MARK: - Test Helpers

struct TestEnvironment: NetworkEnvironment {
    var baseURL: URL
    var defaultHeaders: [String: String]
    var timeout: TimeInterval

    init(
        baseURL: URL = URL(string: "https://api.example.com")!,
        defaultHeaders: [String: String] = [:],
        timeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.defaultHeaders = defaultHeaders
        self.timeout = timeout
    }
}

struct GetUserEndpoint: Endpoint {
    let id: String

    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .get }

    typealias Response = User
}

struct CreateUserEndpoint: Endpoint {
    let name: String
    let email: String

    var path: String { "/users" }
    var method: HTTPMethod { .post }
    var body: (any Encodable & Sendable)? {
        ["name": name, "email": email]
    }

    typealias Response = User
}

struct DeleteUserEndpoint: Endpoint {
    let id: String

    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .delete }

    typealias Response = EmptyResponse
}

struct User: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let email: String
}

// MARK: - HTTPMethod Tests

@Suite("HTTPMethod Tests")
struct HTTPMethodTests {
    @Test("Raw values match HTTP standard")
    func rawValues() {
        #expect(HTTPMethod.get.rawValue == "GET")
        #expect(HTTPMethod.post.rawValue == "POST")
        #expect(HTTPMethod.put.rawValue == "PUT")
        #expect(HTTPMethod.patch.rawValue == "PATCH")
        #expect(HTTPMethod.delete.rawValue == "DELETE")
    }
}

// MARK: - NetworkError Tests

@Suite("NetworkError Tests")
struct NetworkErrorTests {
    @Test("Error cases are equatable")
    func equality() {
        #expect(NetworkError.invalidURL() == NetworkError.invalidURL())
        #expect(NetworkError.noConnection() == NetworkError.noConnection())
        #expect(NetworkError.timeout() == NetworkError.timeout())
        #expect(NetworkError.unauthorized() == NetworkError.unauthorized())
        #expect(NetworkError.forbidden() == NetworkError.forbidden())
        #expect(NetworkError.notFound() == NetworkError.notFound())
        #expect(NetworkError(kind: .serverError(statusCode: 500)) == NetworkError(kind: .serverError(statusCode: 500)))
        #expect(NetworkError(kind: .serverError(statusCode: 500)) != NetworkError(kind: .serverError(statusCode: 502)))
    }

    @Test("Different error types are not equal")
    func inequality() {
        #expect(NetworkError.invalidURL() != NetworkError.noConnection())
        #expect(NetworkError.timeout() != NetworkError.unauthorized())
    }

    @Test("Error kind is accessible")
    func errorKindAccessible() {
        let timeoutError = NetworkError.timeout()
        #expect(timeoutError.kind == .timeout)

        let serverError = NetworkError(kind: .serverError(statusCode: 503))
        if case .serverError(let code) = serverError.kind {
            #expect(code == 503)
        } else {
            Issue.record("Expected serverError kind")
        }
    }

    @Test("Error includes request context")
    func requestContext() {
        let snapshot = RequestSnapshot(
            url: URL(string: "https://api.example.com/test"),
            method: "GET"
        )
        let error = NetworkError.timeout(request: snapshot)

        #expect(error.request?.url?.absoluteString == "https://api.example.com/test")
        #expect(error.request?.method == "GET")
    }

    @Test("Error includes response context")
    func responseContext() {
        let responseSnapshot = ResponseSnapshot(statusCode: 500, bodyPreview: "Error occurred")
        let error = NetworkError(kind: .serverError(statusCode: 500), response: responseSnapshot)

        #expect(error.response?.statusCode == 500)
        #expect(error.response?.bodyPreview == "Error occurred")
    }

    @Test("Headers are sanitized")
    func headersSanitized() {
        let snapshot = RequestSnapshot(
            url: URL(string: "https://api.example.com"),
            method: "GET",
            headers: ["Authorization": "Bearer secret", "Content-Type": "application/json"]
        )

        #expect(snapshot.headers["Authorization"] == "[REDACTED]")
        #expect(snapshot.headers["Content-Type"] == "application/json")
    }
}

// MARK: - EmptyResponse Tests

@Suite("EmptyResponse Tests")
struct EmptyResponseTests {
    @Test("Can be initialized")
    func initialization() {
        let response = EmptyResponse()
        #expect(response == EmptyResponse())
    }

    @Test("Is equatable")
    func equatable() {
        let a = EmptyResponse()
        let b = EmptyResponse()
        #expect(a == b)
    }
}

// MARK: - Environment Tests

@Suite("Environment Tests")
struct EnvironmentTests {
    @Test("Default values are applied")
    func defaults() {
        struct MinimalEnvironment: NetworkEnvironment {
            var baseURL: URL { URL(string: "https://api.test.com")! }
        }

        let env = MinimalEnvironment()
        #expect(env.defaultHeaders.isEmpty)
        #expect(env.timeout == 30)
    }

    @Test("Custom values override defaults")
    func customValues() {
        let env = TestEnvironment(
            baseURL: URL(string: "https://custom.com")!,
            defaultHeaders: ["X-Custom": "value"],
            timeout: 60
        )

        #expect(env.baseURL.absoluteString == "https://custom.com")
        #expect(env.defaultHeaders["X-Custom"] == "value")
        #expect(env.timeout == 60)
    }
}

// MARK: - Endpoint Tests

@Suite("Endpoint Tests")
struct EndpointTests {
    @Test("Default values are applied")
    func defaults() {
        let endpoint = GetUserEndpoint(id: "123")

        #expect(endpoint.path == "/users/123")
        #expect(endpoint.method == .get)
        #expect(endpoint.headers.isEmpty)
        #expect(endpoint.queryParameters.isEmpty)
        #expect(endpoint.body == nil)
    }

    @Test("POST endpoint with body")
    func postWithBody() {
        let endpoint = CreateUserEndpoint(name: "John", email: "john@example.com")

        #expect(endpoint.path == "/users")
        #expect(endpoint.method == .post)
        #expect(endpoint.body != nil)
    }
}

// MARK: - RetryPolicy Tests

@Suite("RetryPolicy Tests")
struct RetryPolicyTests {
    @Test("Should retry on retryable errors")
    func shouldRetryOnRetryableErrors() {
        let policy = RetryPolicy(maxRetries: 3)

        #expect(policy.shouldRetry(error: .noConnection(), attempt: 0) == true)
        #expect(policy.shouldRetry(error: .timeout(), attempt: 0) == true)
        #expect(policy.shouldRetry(error: NetworkError(kind: .serverError(statusCode: 500)), attempt: 0) == true)
        #expect(policy.shouldRetry(error: NetworkError(kind: .serviceUnavailable), attempt: 0) == true)
    }

    @Test("Should not retry on non-retryable errors")
    func shouldNotRetryOnNonRetryableErrors() {
        let policy = RetryPolicy(maxRetries: 3)

        #expect(policy.shouldRetry(error: .unauthorized(), attempt: 0) == false)
        #expect(policy.shouldRetry(error: .forbidden(), attempt: 0) == false)
        #expect(policy.shouldRetry(error: .notFound(), attempt: 0) == false)
        #expect(policy.shouldRetry(error: .invalidURL(), attempt: 0) == false)
    }

    @Test("Should respect max retries")
    func respectsMaxRetries() {
        let policy = RetryPolicy(maxRetries: 2)

        #expect(policy.shouldRetry(error: .timeout(), attempt: 0) == true)
        #expect(policy.shouldRetry(error: .timeout(), attempt: 1) == true)
        #expect(policy.shouldRetry(error: .timeout(), attempt: 2) == false)
        #expect(policy.shouldRetry(error: .timeout(), attempt: 3) == false)
    }

    @Test("Immediate delay returns zero")
    func immediateDelay() {
        let policy = RetryPolicy(maxRetries: 3, delay: .immediate)

        #expect(policy.delay(for: 0) == 0)
        #expect(policy.delay(for: 1) == 0)
        #expect(policy.delay(for: 2) == 0)
    }

    @Test("Fixed delay returns constant value")
    func fixedDelay() {
        let policy = RetryPolicy(maxRetries: 3, delay: .fixed(2.0))

        #expect(policy.delay(for: 0) == 2.0)
        #expect(policy.delay(for: 1) == 2.0)
        #expect(policy.delay(for: 2) == 2.0)
    }

    @Test("Exponential delay increases")
    func exponentialDelay() {
        let policy = RetryPolicy(maxRetries: 3, delay: .exponential(base: 1.0, multiplier: 2.0, jitter: 0, maxDelay: 1000))

        #expect(policy.delay(for: 0) == 1.0)
        #expect(policy.delay(for: 1) == 2.0)
        #expect(policy.delay(for: 2) == 4.0)
    }

    @Test("Exponential delay is capped at maxDelay")
    func exponentialDelayCapped() {
        let policy = RetryPolicy(maxRetries: 10, delay: .exponential(base: 1.0, multiplier: 2.0, jitter: 0, maxDelay: 10))

        #expect(policy.delay(for: 0) == 1.0)   // 1 * 2^0 = 1 (below cap)
        #expect(policy.delay(for: 1) == 2.0)   // 1 * 2^1 = 2 (below cap)
        #expect(policy.delay(for: 2) == 4.0)   // 1 * 2^2 = 4 (below cap)
        #expect(policy.delay(for: 3) == 8.0)   // 1 * 2^3 = 8 (below cap)
        #expect(policy.delay(for: 4) == 10.0)  // 1 * 2^4 = 16 -> capped to 10
        #expect(policy.delay(for: 5) == 10.0)  // 1 * 2^5 = 32 -> capped to 10
        #expect(policy.delay(for: 10) == 10.0) // 1 * 2^10 = 1024 -> capped to 10
    }

    @Test("Large attempt numbers are capped and do not overflow")
    func largeAttemptNumbersCapped() {
        let policy = RetryPolicy(maxRetries: 100, delay: .exponential(base: 1.0, multiplier: 2.0, jitter: 0, maxDelay: 60))

        // Attempt 30 would be 1 * 2^30 = ~1 billion seconds without cap
        let delay30: TimeInterval = policy.delay(for: 30)
        #expect(delay30 == 60.0)

        // Attempt 50 would overflow without cap
        let delay50: TimeInterval = policy.delay(for: 50)
        #expect(delay50 == 60.0)
    }

    @Test("Default maxDelay is 60 seconds")
    func defaultMaxDelay() {
        let policy = RetryPolicy(maxRetries: 20)

        // Attempt 10 would be 1024 seconds without cap
        let delay: TimeInterval = policy.delay(for: 10)
        #expect(delay <= 60.0)
    }

    @Test("Jitter does not exceed maxDelay")
    func jitterDoesNotExceedMaxDelay() {
        let maxDelay: TimeInterval = 10.0
        let policy = RetryPolicy(maxRetries: 20, delay: .exponential(base: 1.0, multiplier: 2.0, jitter: 0.5, maxDelay: maxDelay))

        // Run multiple times to test jitter randomness
        for _ in 0..<100 {
            let delay: TimeInterval = policy.delay(for: 10)
            #expect(delay <= maxDelay, "Delay with jitter should never exceed maxDelay")
            #expect(delay >= 0, "Delay should never be negative")
        }
    }
}

// MARK: - ResponseCache Tests

@Suite("ResponseCache Tests")
struct ResponseCacheTests {
    @Test("Store and retrieve data")
    func storeAndRetrieve() async {
        let cache = ResponseCache()
        let request = URLRequest(url: URL(string: "https://api.example.com/test")!)
        let data = "test data".data(using: .utf8)!

        await cache.store(data: data, for: request, ttl: 60)
        let retrieved = await cache.retrieve(for: request)

        #expect(retrieved == data)
    }

    @Test("Returns nil for non-existent entry")
    func nonExistent() async {
        let cache = ResponseCache()
        let request = URLRequest(url: URL(string: "https://api.example.com/missing")!)

        let result = await cache.retrieve(for: request)

        #expect(result == nil)
    }

    @Test("Invalidate single entry")
    func invalidateSingle() async {
        let cache = ResponseCache()
        let request = URLRequest(url: URL(string: "https://api.example.com/test")!)
        let data = "test data".data(using: .utf8)!

        await cache.store(data: data, for: request, ttl: 60)
        await cache.invalidate(for: request)
        let result = await cache.retrieve(for: request)

        #expect(result == nil)
    }

    @Test("Invalidate all entries")
    func invalidateAll() async {
        let cache = ResponseCache()
        let request1 = URLRequest(url: URL(string: "https://api.example.com/test1")!)
        let request2 = URLRequest(url: URL(string: "https://api.example.com/test2")!)

        await cache.store(data: Data(), for: request1, ttl: 60)
        await cache.store(data: Data(), for: request2, ttl: 60)
        await cache.invalidateAll()

        #expect(await cache.count == 0)
    }

    @Test("Expired entries return nil")
    func expiredEntries() async throws {
        let cache = ResponseCache()
        let request = URLRequest(url: URL(string: "https://api.example.com/test")!)
        let data = "test data".data(using: .utf8)!

        await cache.store(data: data, for: request, ttl: 0.1)
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds

        let result = await cache.retrieve(for: request)
        #expect(result == nil)
    }
}

// MARK: - Interceptor Tests

@Suite("Interceptor Tests")
struct InterceptorTests {
    @Test("AuthInterceptor injects token")
    func authInterceptorInjectsToken() async throws {
        let interceptor = AuthInterceptor(
            tokenProvider: { "test-token" }
        )

        var request = URLRequest(url: URL(string: "https://api.example.com")!)
        request = try await interceptor.intercept(request: request)

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test("AuthInterceptor with custom header name")
    func authInterceptorCustomHeader() async throws {
        let interceptor = AuthInterceptor(
            headerName: "X-API-Key",
            tokenPrefix: nil,
            tokenProvider: { "my-api-key" }
        )

        var request = URLRequest(url: URL(string: "https://api.example.com")!)
        request = try await interceptor.intercept(request: request)

        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "my-api-key")
    }

    @Test("AuthInterceptor with nil token does nothing")
    func authInterceptorNilToken() async throws {
        let interceptor = AuthInterceptor(
            tokenProvider: { nil }
        )

        var request = URLRequest(url: URL(string: "https://api.example.com")!)
        request = try await interceptor.intercept(request: request)

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("LoggingInterceptor does not modify request")
    func loggingInterceptorPassthrough() async throws {
        let interceptor = LoggingInterceptor(level: .none)

        let originalRequest = URLRequest(url: URL(string: "https://api.example.com")!)
        let result = try await interceptor.intercept(request: originalRequest)

        #expect(result.url == originalRequest.url)
    }

    @Test("LoggingInterceptor does not modify response data")
    func loggingInterceptorResponsePassthrough() async throws {
        let interceptor = LoggingInterceptor(level: .verbose)
        let response = HTTPURLResponse(
            url: URL(string: "https://api.example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let data = "test".data(using: .utf8)!

        let result = try await interceptor.intercept(response: response, data: data)

        #expect(result == data)
    }
}

// MARK: - MockNetworkClient Tests

@Suite("MockNetworkClient Tests")
struct MockNetworkClientTests {
    @Test("Stub success response")
    func stubSuccessResponse() async throws {
        let client = MockNetworkClient()
        let expectedUser = User(id: "123", name: "John", email: "john@example.com")

        await client.stub(GetUserEndpoint.self) { _ in expectedUser }

        let result = try await client.request(GetUserEndpoint(id: "123"))

        #expect(result == expectedUser)
    }

    @Test("Stub error response")
    func stubErrorResponse() async throws {
        let client = MockNetworkClient()

        await client.stubError(GetUserEndpoint.self, error: .notFound())

        do {
            _ = try await client.request(GetUserEndpoint(id: "123"))
            Issue.record("Expected error to be thrown")
        } catch let error as NetworkError {
            #expect(error.kind == .notFound)
        }
    }

    @Test("Call counting")
    func callCounting() async throws {
        let client = MockNetworkClient()
        await client.stub(GetUserEndpoint.self) { _ in
            User(id: "1", name: "Test", email: "test@example.com")
        }

        _ = try await client.request(GetUserEndpoint(id: "1"))
        _ = try await client.request(GetUserEndpoint(id: "2"))
        _ = try await client.request(GetUserEndpoint(id: "3"))

        let count = await client.callCount(for: GetUserEndpoint.self)
        #expect(count == 3)
    }

    @Test("Called endpoints tracking")
    func calledEndpointsTracking() async throws {
        let client = MockNetworkClient()
        await client.stub(GetUserEndpoint.self) { _ in
            User(id: "1", name: "Test", email: "test@example.com")
        }

        _ = try await client.request(GetUserEndpoint(id: "abc"))
        _ = try await client.request(GetUserEndpoint(id: "xyz"))

        let endpoints = await client.calledEndpoints(of: GetUserEndpoint.self)
        #expect(endpoints.count == 2)
        #expect(endpoints[0].id == "abc")
        #expect(endpoints[1].id == "xyz")
    }

    @Test("Reset clears everything")
    func reset() async throws {
        let client = MockNetworkClient()
        await client.stub(GetUserEndpoint.self) { _ in
            User(id: "1", name: "Test", email: "test@example.com")
        }

        _ = try await client.request(GetUserEndpoint(id: "1"))
        await client.reset()

        let count = await client.callCount(for: GetUserEndpoint.self)
        #expect(count == 0)

        do {
            _ = try await client.request(GetUserEndpoint(id: "1"))
            Issue.record("Expected error after reset")
        } catch is MockError {
            // Expected
        }
    }

    @Test("Throws when no stub configured")
    func noStubConfigured() async {
        let client = MockNetworkClient()

        do {
            _ = try await client.request(GetUserEndpoint(id: "123"))
            Issue.record("Expected error to be thrown")
        } catch is MockError {
            // Expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Stub with delay")
    func stubWithDelay() async throws {
        let client = MockNetworkClient()
        let expectedUser = User(id: "123", name: "John", email: "john@example.com")

        await client.stub(GetUserEndpoint.self, delay: 0.1) { _ in expectedUser }

        let start = Date()
        let result = try await client.request(GetUserEndpoint(id: "123"))
        let elapsed = Date().timeIntervalSince(start)

        #expect(result == expectedUser)
        #expect(elapsed >= 0.1)
    }
}

// MARK: - URLRequest+Extensions Tests

@Suite("URLRequest Extensions Tests")
struct URLRequestExtensionsTests {
    @Test("Builds URL from endpoint and environment")
    func buildsURL() throws {
        let env = TestEnvironment()
        let endpoint = GetUserEndpoint(id: "123")

        let request = try URLRequest(endpoint: endpoint, environment: env)

        #expect(request.url?.absoluteString == "https://api.example.com/users/123")
        #expect(request.httpMethod == "GET")
    }

    @Test("Sets timeout from environment")
    func setsTimeout() throws {
        let env = TestEnvironment(timeout: 45)
        let endpoint = GetUserEndpoint(id: "123")

        let request = try URLRequest(endpoint: endpoint, environment: env)

        #expect(request.timeoutInterval == 45)
    }

    @Test("Timeout override takes precedence")
    func timeoutOverride() throws {
        let env = TestEnvironment(timeout: 30)
        let endpoint = GetUserEndpoint(id: "123")

        let request = try URLRequest(
            endpoint: endpoint,
            environment: env,
            timeoutOverride: 60
        )

        #expect(request.timeoutInterval == 60)
    }

    @Test("Merges headers correctly")
    func mergesHeaders() throws {
        let env = TestEnvironment(defaultHeaders: ["X-Env": "env-value", "X-Both": "env"])
        let endpoint = GetUserEndpoint(id: "123")

        let request = try URLRequest(
            endpoint: endpoint,
            environment: env,
            additionalHeaders: ["X-Additional": "additional-value", "X-Both": "additional"]
        )

        #expect(request.value(forHTTPHeaderField: "X-Env") == "env-value")
        #expect(request.value(forHTTPHeaderField: "X-Additional") == "additional-value")
        #expect(request.value(forHTTPHeaderField: "X-Both") == "additional")
    }

    @Test("Encodes body and sets Content-Type")
    func encodesBody() throws {
        let env = TestEnvironment()
        let endpoint = CreateUserEndpoint(name: "John", email: "john@example.com")

        let request = try URLRequest(endpoint: endpoint, environment: env)

        #expect(request.httpBody != nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }
}

// MARK: - RequestBuilder Tests

@Suite("RequestBuilder Tests")
struct RequestBuilderTests {
    @Test("Fluent API builds correct request")
    func fluentAPI() async throws {
        let client = MockNetworkClient()
        let expectedUser = User(id: "123", name: "John", email: "john@example.com")

        await client.stub(GetUserEndpoint.self) { _ in expectedUser }

        let builder = RequestBuilder(endpoint: GetUserEndpoint(id: "123")) { endpoint, timeout, headers in
            try await client.request(endpoint)
        }

        let result = try await builder
            .timeout(60)
            .header("X-Custom", "value")
            .send()

        #expect(result == expectedUser)
    }

    @Test("Builder preserves endpoint")
    func preservesEndpoint() {
        let endpoint = GetUserEndpoint(id: "test-id")
        let builder = RequestBuilder(endpoint: endpoint) { _, _, _ in
            User(id: "1", name: "Test", email: "test@example.com")
        }

        #expect(builder.endpoint.id == "test-id")
    }

    @Test("Builder accumulates headers")
    func accumulatesHeaders() {
        let endpoint = GetUserEndpoint(id: "123")
        let builder = RequestBuilder(endpoint: endpoint) { _, _, _ in
            User(id: "1", name: "Test", email: "test@example.com")
        }

        let modified = builder
            .header("X-First", "first")
            .header("X-Second", "second")
            .headers(["X-Third": "third"])

        #expect(modified.additionalHeaders["X-First"] == "first")
        #expect(modified.additionalHeaders["X-Second"] == "second")
        #expect(modified.additionalHeaders["X-Third"] == "third")
    }
}

// MARK: - Long Polling Test Helpers

struct Message: Codable, Equatable, Sendable {
    let id: String
    let content: String
}

struct MessagesPollingEndpoint: LongPollingEndpoint {
    var path: String { "/messages/poll" }
    var method: HTTPMethod { .get }
    var pollingTimeout: TimeInterval { 5 }
    var retryInterval: TimeInterval { 0.1 }

    typealias Response = [Message]
}

struct ConditionalPollingEndpoint: LongPollingEndpoint {
    let stopAfterCount: Int
    private(set) var receivedCount: Int = 0

    var path: String { "/events" }
    var method: HTTPMethod { .get }
    var pollingTimeout: TimeInterval { 5 }
    var retryInterval: TimeInterval { 0.1 }

    typealias Response = String

    func shouldContinuePolling(after response: String) -> Bool {
        // Stop when we receive "STOP" message
        response != "STOP"
    }
}

// MARK: - LongPollingEndpoint Tests

@Suite("LongPollingEndpoint Tests")
struct LongPollingEndpointTests {
    @Test("Default values are applied")
    func defaults() {
        struct MinimalPollingEndpoint: LongPollingEndpoint {
            var path: String { "/poll" }
            var method: HTTPMethod { .get }
            typealias Response = String
        }

        let endpoint = MinimalPollingEndpoint()
        #expect(endpoint.pollingTimeout == 30)
        #expect(endpoint.retryInterval == 1)
        #expect(endpoint.shouldContinuePolling(after: "any") == true)
    }

    @Test("Custom values override defaults")
    func customValues() {
        let endpoint = MessagesPollingEndpoint()
        #expect(endpoint.pollingTimeout == 5)
        #expect(endpoint.retryInterval == 0.1)
    }

    @Test("shouldContinuePolling can stop polling")
    func conditionalStop() {
        let endpoint = ConditionalPollingEndpoint(stopAfterCount: 3)
        #expect(endpoint.shouldContinuePolling(after: "hello") == true)
        #expect(endpoint.shouldContinuePolling(after: "world") == true)
        #expect(endpoint.shouldContinuePolling(after: "STOP") == false)
    }
}

// MARK: - LongPollingConfiguration Tests

@Suite("LongPollingConfiguration Tests")
struct LongPollingConfigurationTests {
    @Test("Custom configuration")
    func customConfig() {
        let config = LongPollingConfiguration(
            timeout: 45,
            retryInterval: 2.5,
            maxConsecutiveErrors: 10
        )

        #expect(config.timeout == 45)
        #expect(config.retryInterval == 2.5)
        #expect(config.maxConsecutiveErrors == 10)
    }

    @Test("Preset configurations")
    func presets() {
        #expect(LongPollingConfiguration.short.timeout == 10)
        #expect(LongPollingConfiguration.short.retryInterval == 0.5)

        #expect(LongPollingConfiguration.standard.timeout == 30)
        #expect(LongPollingConfiguration.standard.retryInterval == 1)

        #expect(LongPollingConfiguration.long.timeout == 60)
        #expect(LongPollingConfiguration.long.retryInterval == 2)

        #expect(LongPollingConfiguration.realtime.timeout == 15)
        #expect(LongPollingConfiguration.realtime.retryInterval == 0.1)
    }

    @Test("Configuration is equatable")
    func equatable() {
        let config1 = LongPollingConfiguration(timeout: 30, retryInterval: 1)
        let config2 = LongPollingConfiguration(timeout: 30, retryInterval: 1)
        let config3 = LongPollingConfiguration(timeout: 60, retryInterval: 1)

        #expect(config1 == config2)
        #expect(config1 != config3)
    }
}

// MARK: - LongPollingState Tests

@Suite("LongPollingState Tests")
struct LongPollingStateTests {
    @Test("States are equatable")
    func equatable() {
        #expect(LongPollingState.idle == LongPollingState.idle)
        #expect(LongPollingState.polling == LongPollingState.polling)
        #expect(LongPollingState.cancelled == LongPollingState.cancelled)
        #expect(LongPollingState.completed == LongPollingState.completed)
        #expect(LongPollingState.waiting(retryIn: 1.0) == LongPollingState.waiting(retryIn: 1.0))
        #expect(LongPollingState.waiting(retryIn: 1.0) != LongPollingState.waiting(retryIn: 2.0))
        #expect(LongPollingState.failed(.timeout()) == LongPollingState.failed(.timeout()))
        #expect(LongPollingState.failed(.timeout()) != LongPollingState.failed(.noConnection()))
    }

    @Test("Different states are not equal")
    func inequality() {
        #expect(LongPollingState.idle != LongPollingState.polling)
        #expect(LongPollingState.polling != LongPollingState.cancelled)
    }
}

// MARK: - MockNetworkClient Sequence Tests

@Suite("MockNetworkClient Sequence Tests")
struct MockNetworkClientSequenceTests {
    @Test("Sequence stub returns responses in order")
    func sequenceInOrder() async throws {
        let client = MockNetworkClient()
        let messages = [
            [Message(id: "1", content: "First")],
            [Message(id: "2", content: "Second")],
            [Message(id: "3", content: "Third")]
        ]

        await client.stubSequence(MessagesPollingEndpoint.self, responses: messages)

        let result1 = try await client.request(MessagesPollingEndpoint())
        let result2 = try await client.request(MessagesPollingEndpoint())
        let result3 = try await client.request(MessagesPollingEndpoint())

        #expect(result1[0].content == "First")
        #expect(result2[0].content == "Second")
        #expect(result3[0].content == "Third")
    }

    @Test("Sequence stub throws when exhausted")
    func sequenceExhausted() async throws {
        let client = MockNetworkClient()
        let messages = [[Message(id: "1", content: "Only one")]]

        await client.stubSequence(MessagesPollingEndpoint.self, responses: messages)

        _ = try await client.request(MessagesPollingEndpoint())

        do {
            _ = try await client.request(MessagesPollingEndpoint())
            Issue.record("Expected error when sequence exhausted")
        } catch let error as MockError {
            if case .sequenceExhausted = error {
                // Expected
            } else {
                Issue.record("Wrong error type: \(error)")
            }
        }
    }

    @Test("Sequence stub with mixed results")
    func sequenceMixedResults() async throws {
        let client = MockNetworkClient()
        let sequence: [Result<[Message], NetworkError>] = [
            .success([Message(id: "1", content: "Success")]),
            .failure(.timeout()),
            .success([Message(id: "2", content: "After timeout")])
        ]

        await client.stubSequence(MessagesPollingEndpoint.self, sequence: sequence)

        // First call succeeds
        let result1 = try await client.request(MessagesPollingEndpoint())
        #expect(result1[0].content == "Success")

        // Second call fails with timeout
        do {
            _ = try await client.request(MessagesPollingEndpoint())
            Issue.record("Expected timeout error")
        } catch let error as NetworkError {
            #expect(error.kind == .timeout)
        }

        // Third call succeeds
        let result3 = try await client.request(MessagesPollingEndpoint())
        #expect(result3[0].content == "After timeout")
    }

    @Test("Sequence stub with delays")
    func sequenceWithDelays() async throws {
        let client = MockNetworkClient()
        let messages = [
            [Message(id: "1", content: "First")],
            [Message(id: "2", content: "Second")]
        ]

        await client.stubSequence(
            MessagesPollingEndpoint.self,
            responses: messages,
            delays: [0.1, 0.1]
        )

        let start = Date()
        _ = try await client.request(MessagesPollingEndpoint())
        _ = try await client.request(MessagesPollingEndpoint())
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed >= 0.2)
    }

    @Test("Sequence tracks call count")
    func sequenceCallCount() async throws {
        let client = MockNetworkClient()
        let messages = [
            [Message(id: "1", content: "First")],
            [Message(id: "2", content: "Second")]
        ]

        await client.stubSequence(MessagesPollingEndpoint.self, responses: messages)

        _ = try await client.request(MessagesPollingEndpoint())
        _ = try await client.request(MessagesPollingEndpoint())

        let count = await client.callCount(for: MessagesPollingEndpoint.self)
        #expect(count == 2)
    }
}

// MARK: - NetworkError NoContent Tests

@Suite("NetworkError NoContent Tests")
struct NetworkErrorNoContentTests {
    @Test("NoContent error is equatable")
    func noContentEquatable() {
        #expect(NetworkError.noContent() == NetworkError.noContent())
        #expect(NetworkError.noContent() != NetworkError.notFound())
    }
}

// MARK: - CacheControlParser Tests

@Suite("CacheControlParser Tests")
struct CacheControlParserTests {
    @Test("Parses max-age directive")
    func parsesMaxAge() {
        let result = CacheControlParser.parse("max-age=3600")

        #expect(result?.maxAge == 3600)
        #expect(result?.noCache == false)
        #expect(result?.noStore == false)
    }

    @Test("Parses no-cache directive")
    func parsesNoCache() {
        let result = CacheControlParser.parse("no-cache")

        #expect(result?.noCache == true)
        #expect(result?.maxAge == nil)
    }

    @Test("Parses no-store directive")
    func parsesNoStore() {
        let result = CacheControlParser.parse("no-store")

        #expect(result?.noStore == true)
    }

    @Test("Parses private directive")
    func parsesPrivate() {
        let result = CacheControlParser.parse("private")

        #expect(result?.isPrivate == true)
        #expect(result?.isPublic == false)
    }

    @Test("Parses public directive")
    func parsesPublic() {
        let result = CacheControlParser.parse("public")

        #expect(result?.isPublic == true)
        #expect(result?.isPrivate == false)
    }

    @Test("Parses must-revalidate directive")
    func parsesMustRevalidate() {
        let result = CacheControlParser.parse("must-revalidate")

        #expect(result?.mustRevalidate == true)
    }

    @Test("Parses immutable directive")
    func parsesImmutable() {
        let result = CacheControlParser.parse("immutable")

        #expect(result?.immutable == true)
    }

    @Test("Parses stale-while-revalidate directive")
    func parsesStaleWhileRevalidate() {
        let result = CacheControlParser.parse("stale-while-revalidate=60")

        #expect(result?.staleWhileRevalidate == 60)
    }

    @Test("Parses stale-if-error directive")
    func parsesStaleIfError() {
        let result = CacheControlParser.parse("stale-if-error=300")

        #expect(result?.staleIfError == 300)
    }

    @Test("Parses s-maxage directive")
    func parsesSMaxAge() {
        let result = CacheControlParser.parse("s-maxage=7200")

        #expect(result?.sharedMaxAge == 7200)
    }

    @Test("Parses multiple directives")
    func parsesMultipleDirectives() {
        let result = CacheControlParser.parse("public, max-age=3600, must-revalidate")

        #expect(result?.isPublic == true)
        #expect(result?.maxAge == 3600)
        #expect(result?.mustRevalidate == true)
    }

    @Test("Handles whitespace correctly")
    func handlesWhitespace() {
        let result = CacheControlParser.parse("  max-age=3600  ,  no-cache  ")

        #expect(result?.maxAge == 3600)
        #expect(result?.noCache == true)
    }

    @Test("Returns nil for empty string")
    func returnsNilForEmptyString() {
        let result = CacheControlParser.parse("")

        #expect(result == nil)
    }

    @Test("Returns nil for nil input")
    func returnsNilForNilInput() {
        let result = CacheControlParser.parse(nil)

        #expect(result == nil)
    }

    @Test("Case insensitive parsing")
    func caseInsensitive() {
        let result = CacheControlParser.parse("MAX-AGE=3600, NO-CACHE")

        #expect(result?.maxAge == 3600)
        #expect(result?.noCache == true)
    }
}

// MARK: - HTTPDateParser Tests

@Suite("HTTPDateParser Tests")
struct HTTPDateParserTests {
    @Test("Parses RFC 1123 format")
    func parsesRFC1123() {
        let dateString: String = "Sun, 06 Nov 1994 08:49:37 GMT"
        let date: Date? = HTTPDateParser.parse(dateString)

        #expect(date != nil)

        let calendar: Calendar = Calendar(identifier: .gregorian)
        let components: DateComponents = calendar.dateComponents(in: TimeZone(identifier: "GMT")!, from: date!)
        #expect(components.year == 1994)
        #expect(components.month == 11)
        #expect(components.day == 6)
    }

    @Test("Parses RFC 850 format")
    func parsesRFC850() {
        let dateString: String = "Sunday, 06-Nov-94 08:49:37 GMT"
        let date: Date? = HTTPDateParser.parse(dateString)

        #expect(date != nil)
    }

    @Test("Parses asctime format")
    func parsesAsctime() {
        let dateString: String = "Sun Nov  6 08:49:37 1994"
        let date: Date? = HTTPDateParser.parse(dateString)

        #expect(date != nil)
    }

    @Test("Returns nil for invalid format")
    func returnsNilForInvalid() {
        let date: Date? = HTTPDateParser.parse("invalid date")

        #expect(date == nil)
    }

    @Test("Returns nil for nil input")
    func returnsNilForNil() {
        let date: Date? = HTTPDateParser.parse(nil)

        #expect(date == nil)
    }

    @Test("Formats date as RFC 1123")
    func formatsAsRFC1123() {
        let components: DateComponents = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "GMT"),
            year: 1994,
            month: 11,
            day: 6,
            hour: 8,
            minute: 49,
            second: 37
        )
        let date: Date = components.date!
        let formatted: String = HTTPDateParser.format(date)

        #expect(formatted == "Sun, 06 Nov 1994 08:49:37 GMT")
    }
}

// MARK: - CacheMetadata Tests

@Suite("CacheMetadata Tests")
struct CacheMetadataTests {
    @Test("isExpired returns true when past expiresAt")
    func isExpiredWhenPast() {
        let metadata: CacheMetadata = CacheMetadata(
            cachedAt: Date().addingTimeInterval(-100),
            expiresAt: Date().addingTimeInterval(-10)
        )

        #expect(metadata.isExpired == true)
    }

    @Test("isExpired returns false when before expiresAt")
    func isNotExpiredWhenFuture() {
        let metadata: CacheMetadata = CacheMetadata(
            cachedAt: Date(),
            expiresAt: Date().addingTimeInterval(100)
        )

        #expect(metadata.isExpired == false)
    }

    @Test("isExpired returns false when expiresAt is nil")
    func isNotExpiredWhenNil() {
        let metadata: CacheMetadata = CacheMetadata(
            cachedAt: Date(),
            expiresAt: nil
        )

        #expect(metadata.isExpired == false)
    }

    @Test("requiresRevalidation when noCache is true")
    func requiresRevalidationNoCache() {
        let cacheControl: CacheControlDirective = CacheControlDirective(noCache: true)
        let metadata: CacheMetadata = CacheMetadata(
            cachedAt: Date(),
            cacheControl: cacheControl
        )

        #expect(metadata.requiresRevalidation == true)
    }

    @Test("requiresRevalidation when mustRevalidate is true")
    func requiresRevalidationMustRevalidate() {
        let cacheControl: CacheControlDirective = CacheControlDirective(mustRevalidate: true)
        let metadata: CacheMetadata = CacheMetadata(
            cachedAt: Date(),
            cacheControl: cacheControl
        )

        #expect(metadata.requiresRevalidation == true)
    }

    @Test("isStaleButRevalidatable within window")
    func staleWithinWindow() {
        let metadata: CacheMetadata = CacheMetadata(
            cachedAt: Date().addingTimeInterval(-100),
            expiresAt: Date().addingTimeInterval(-10)
        )

        #expect(metadata.isStaleButRevalidatable(within: 60) == true)
        #expect(metadata.isStaleButRevalidatable(within: 5) == false)
    }
}

// MARK: - HTTPCachePolicy Tests

@Suite("HTTPCachePolicy Tests")
struct HTTPCachePolicyTests {
    @Test("shouldCache returns false for no-store")
    func noStorePreventsCache() {
        let policy: HTTPCachePolicy = HTTPCachePolicy()
        let response: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Cache-Control": "no-store"]
        )!

        #expect(policy.shouldCache(response: response) == false)
    }

    @Test("shouldCache returns true for cacheable status codes")
    func cacheableStatusCodes() {
        let policy: HTTPCachePolicy = HTTPCachePolicy()
        let cacheableCodes: [Int] = [200, 203, 301, 404]

        for code in cacheableCodes {
            let response: HTTPURLResponse = HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: code,
                httpVersion: nil,
                headerFields: nil
            )!
            #expect(policy.shouldCache(response: response) == true)
        }
    }

    @Test("shouldCache returns false for non-cacheable status codes")
    func nonCacheableStatusCodes() {
        let policy: HTTPCachePolicy = HTTPCachePolicy()
        let nonCacheableCodes: [Int] = [201, 302, 400, 500]

        for code in nonCacheableCodes {
            let response: HTTPURLResponse = HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: code,
                httpVersion: nil,
                headerFields: nil
            )!
            #expect(policy.shouldCache(response: response) == false)
        }
    }

    @Test("ttl uses max-age from Cache-Control")
    func ttlFromMaxAge() {
        let policy: HTTPCachePolicy = HTTPCachePolicy()
        let response: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Cache-Control": "max-age=3600"]
        )!

        #expect(policy.ttl(for: response) == 3600)
    }

    @Test("ttl uses Expires header as fallback")
    func ttlFromExpires() {
        let policy: HTTPCachePolicy = HTTPCachePolicy()
        let futureDate: Date = Date().addingTimeInterval(1800)
        let expiresString: String = HTTPDateParser.format(futureDate)
        let response: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Expires": expiresString]
        )!

        let ttl: TimeInterval? = policy.ttl(for: response)
        #expect(ttl != nil)
        #expect(ttl! > 1700 && ttl! < 1900)
    }

    @Test("ttl uses defaultTTL when no headers")
    func ttlDefaultFallback() {
        let policy: HTTPCachePolicy = HTTPCachePolicy(defaultTTL: 600)
        let response: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        #expect(policy.ttl(for: response) == 600)
    }

    @Test("ttl returns nil when no headers and no default")
    func ttlReturnsNilWhenNoInfo() {
        let policy: HTTPCachePolicy = HTTPCachePolicy(defaultTTL: 0)
        let response: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        #expect(policy.ttl(for: response) == nil)
    }
}

// MARK: - ResponseCache HTTP Headers Tests

@Suite("ResponseCache HTTP Headers Tests")
struct ResponseCacheHTTPHeadersTests {
    @Test("Store respects no-store directive")
    func storeRespectsNoStore() async {
        let cache: ResponseCache = ResponseCache()
        let request: URLRequest = URLRequest(url: URL(string: "https://example.com/test")!)
        let response: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://example.com/test")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Cache-Control": "no-store"]
        )!
        let data: Data = "test".data(using: .utf8)!

        let stored: Bool = await cache.store(data: data, for: request, response: response)

        #expect(stored == false)
        #expect(await cache.count == 0)
    }

    @Test("Store caches with max-age")
    func storeCachesWithMaxAge() async {
        let cache: ResponseCache = ResponseCache()
        let request: URLRequest = URLRequest(url: URL(string: "https://example.com/test")!)
        let response: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://example.com/test")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Cache-Control": "max-age=3600"]
        )!
        let data: Data = "test".data(using: .utf8)!

        let stored: Bool = await cache.store(data: data, for: request, response: response)

        #expect(stored == true)
        #expect(await cache.count == 1)
    }

    @Test("retrieveWithMetadata returns fresh for valid entry")
    func retrieveWithMetadataFresh() async {
        let cache: ResponseCache = ResponseCache()
        let request: URLRequest = URLRequest(url: URL(string: "https://example.com/test")!)
        let response: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://example.com/test")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Cache-Control": "max-age=3600", "ETag": "\"abc123\""]
        )!
        let data: Data = "test".data(using: .utf8)!

        await cache.store(data: data, for: request, response: response)
        let result: CacheRetrievalResult = await cache.retrieveWithMetadata(for: request)

        if case .fresh(let retrievedData, let metadata) = result {
            #expect(retrievedData == data)
            #expect(metadata.etag == "\"abc123\"")
        } else {
            Issue.record("Expected fresh result")
        }
    }

    @Test("retrieveWithMetadata returns needsRevalidation for no-cache")
    func retrieveWithMetadataNeedsRevalidation() async {
        let cache: ResponseCache = ResponseCache()
        let request: URLRequest = URLRequest(url: URL(string: "https://example.com/test")!)
        let data: Data = "test".data(using: .utf8)!

        await cache.store(data: data, for: request, ttl: 3600)

        let result: CacheRetrievalResult = await cache.retrieveWithMetadata(for: request)

        if case .fresh(let retrievedData, _) = result {
            #expect(retrievedData == data)
        } else {
            Issue.record("Expected fresh result for TTL-based cache")
        }
    }

    @Test("retrieveWithMetadata returns miss for non-existent entry")
    func retrieveWithMetadataMiss() async {
        let cache: ResponseCache = ResponseCache()
        let request: URLRequest = URLRequest(url: URL(string: "https://example.com/missing")!)

        let result: CacheRetrievalResult = await cache.retrieveWithMetadata(for: request)

        if case .miss = result {
            // Expected
        } else {
            Issue.record("Expected miss result")
        }
    }

    @Test("metadata returns stored metadata")
    func metadataReturnsStored() async {
        let cache: ResponseCache = ResponseCache()
        let request: URLRequest = URLRequest(url: URL(string: "https://example.com/test")!)
        let response: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://example.com/test")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Cache-Control": "max-age=3600",
                "ETag": "\"abc123\"",
                "Last-Modified": "Sun, 06 Nov 1994 08:49:37 GMT"
            ]
        )!

        await cache.store(data: Data(), for: request, response: response)
        let metadata: CacheMetadata? = await cache.metadata(for: request)

        #expect(metadata != nil)
        #expect(metadata?.etag == "\"abc123\"")
        #expect(metadata?.lastModified == "Sun, 06 Nov 1994 08:49:37 GMT")
    }

    @Test("updateAfterRevalidation refreshes entry")
    func updateAfterRevalidation() async {
        let cache: ResponseCache = ResponseCache()
        let request: URLRequest = URLRequest(url: URL(string: "https://example.com/test")!)
        let initialResponse: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://example.com/test")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Cache-Control": "max-age=100", "ETag": "\"old\""]
        )!
        let data: Data = "test".data(using: .utf8)!

        await cache.store(data: data, for: request, response: initialResponse)

        let revalidationResponse: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://example.com/test")!,
            statusCode: 304,
            httpVersion: nil,
            headerFields: ["Cache-Control": "max-age=3600", "ETag": "\"new\""]
        )!

        await cache.updateAfterRevalidation(for: request, response: revalidationResponse)

        let metadata: CacheMetadata? = await cache.metadata(for: request)
        #expect(metadata?.etag == "\"new\"")
    }
}

// MARK: - EndpointCachePolicy Tests

@Suite("EndpointCachePolicy Tests")
struct EndpointCachePolicyTests {
    struct NoCacheEndpoint: Endpoint {
        var path: String { "/no-cache" }
        var method: HTTPMethod { .get }
        var cachePolicy: EndpointCachePolicy { .noCache }
        typealias Response = String
    }

    struct AlwaysCacheEndpoint: Endpoint {
        var path: String { "/always-cache" }
        var method: HTTPMethod { .get }
        var cachePolicy: EndpointCachePolicy { .always(ttl: 600) }
        typealias Response = String
    }

    struct OverrideTTLEndpoint: Endpoint {
        var path: String { "/override-ttl" }
        var method: HTTPMethod { .get }
        var cachePolicy: EndpointCachePolicy { .overrideTTL(1800) }
        typealias Response = String
    }

    struct DefaultEndpoint: Endpoint {
        var path: String { "/default" }
        var method: HTTPMethod { .get }
        typealias Response = String
    }

    @Test("Default endpoint uses respectHeaders policy")
    func defaultUsesRespectHeaders() {
        let endpoint: DefaultEndpoint = DefaultEndpoint()

        if case .respectHeaders = endpoint.cachePolicy {
            // Expected
        } else {
            Issue.record("Expected respectHeaders policy")
        }
    }

    @Test("noCache policy is set correctly")
    func noCachePolicySet() {
        let endpoint: NoCacheEndpoint = NoCacheEndpoint()

        if case .noCache = endpoint.cachePolicy {
            // Expected
        } else {
            Issue.record("Expected noCache policy")
        }
    }

    @Test("always policy includes TTL")
    func alwaysPolicyWithTTL() {
        let endpoint: AlwaysCacheEndpoint = AlwaysCacheEndpoint()

        if case .always(let ttl) = endpoint.cachePolicy {
            #expect(ttl == 600)
        } else {
            Issue.record("Expected always policy")
        }
    }

    @Test("overrideTTL policy includes TTL")
    func overrideTTLPolicyWithTTL() {
        let endpoint: OverrideTTLEndpoint = OverrideTTLEndpoint()

        if case .overrideTTL(let ttl) = endpoint.cachePolicy {
            #expect(ttl == 1800)
        } else {
            Issue.record("Expected overrideTTL policy")
        }
    }

    @Test("Default cacheTTL is nil")
    func defaultCacheTTLIsNil() {
        let endpoint: DefaultEndpoint = DefaultEndpoint()

        #expect(endpoint.cacheTTL == nil)
    }
}

// MARK: - CacheRetrievalResult Tests

@Suite("CacheRetrievalResult Tests")
struct CacheRetrievalResultTests {
    @Test("data property returns data for all cases except miss")
    func dataProperty() {
        let testData: Data = "test".data(using: .utf8)!
        let metadata: CacheMetadata = CacheMetadata(cachedAt: Date())

        let fresh: CacheRetrievalResult = .fresh(testData, metadata)
        let stale: CacheRetrievalResult = .stale(testData, metadata)
        let needsRevalidation: CacheRetrievalResult = .needsRevalidation(testData, metadata)
        let miss: CacheRetrievalResult = .miss

        #expect(fresh.data == testData)
        #expect(stale.data == testData)
        #expect(needsRevalidation.data == testData)
        #expect(miss.data == nil)
    }

    @Test("metadata property returns metadata for all cases except miss")
    func metadataProperty() {
        let testData: Data = "test".data(using: .utf8)!
        let metadata: CacheMetadata = CacheMetadata(etag: "\"test\"", cachedAt: Date())

        let fresh: CacheRetrievalResult = .fresh(testData, metadata)
        let stale: CacheRetrievalResult = .stale(testData, metadata)
        let needsRevalidation: CacheRetrievalResult = .needsRevalidation(testData, metadata)
        let miss: CacheRetrievalResult = .miss

        #expect(fresh.metadata?.etag == "\"test\"")
        #expect(stale.metadata?.etag == "\"test\"")
        #expect(needsRevalidation.metadata?.etag == "\"test\"")
        #expect(miss.metadata == nil)
    }
}

// MARK: - CacheControlDirective Tests

@Suite("CacheControlDirective Tests")
struct CacheControlDirectiveTests {
    @Test("Default initializer sets all values to defaults")
    func defaultInitializer() {
        let directive: CacheControlDirective = CacheControlDirective()

        #expect(directive.maxAge == nil)
        #expect(directive.sharedMaxAge == nil)
        #expect(directive.noCache == false)
        #expect(directive.noStore == false)
        #expect(directive.isPrivate == false)
        #expect(directive.isPublic == false)
        #expect(directive.mustRevalidate == false)
        #expect(directive.staleWhileRevalidate == nil)
        #expect(directive.staleIfError == nil)
        #expect(directive.immutable == false)
    }

    @Test("CacheControlDirective is Equatable")
    func equatable() {
        let directive1: CacheControlDirective = CacheControlDirective(maxAge: 3600, noCache: true)
        let directive2: CacheControlDirective = CacheControlDirective(maxAge: 3600, noCache: true)
        let directive3: CacheControlDirective = CacheControlDirective(maxAge: 7200, noCache: true)

        #expect(directive1 == directive2)
        #expect(directive1 != directive3)
    }

    @Test("CacheControlDirective is Codable")
    func codable() throws {
        let directive: CacheControlDirective = CacheControlDirective(
            maxAge: 3600,
            noCache: true,
            isPublic: true,
            staleWhileRevalidate: 60
        )

        let encoder: JSONEncoder = JSONEncoder()
        let data: Data = try encoder.encode(directive)

        let decoder: JSONDecoder = JSONDecoder()
        let decoded: CacheControlDirective = try decoder.decode(CacheControlDirective.self, from: data)

        #expect(decoded == directive)
    }
}

// MARK: - SanitizationConfig Tests

@Suite("SanitizationConfig Tests")
struct SanitizationConfigTests {
    @Test("Default configuration has expected sensitive headers")
    func defaultSensitiveHeaders() {
        let config: SanitizationConfig = .default

        #expect(config.sensitiveHeaders.contains("authorization"))
        #expect(config.sensitiveHeaders.contains("x-api-key"))
        #expect(config.sensitiveHeaders.contains("cookie"))
    }

    @Test("Default configuration has expected sensitive query params")
    func defaultSensitiveQueryParams() {
        let config: SanitizationConfig = .default

        #expect(config.sensitiveQueryParams.contains("token"))
        #expect(config.sensitiveQueryParams.contains("api_key"))
        #expect(config.sensitiveQueryParams.contains("password"))
    }

    @Test("Default configuration has expected sensitive body fields")
    func defaultSensitiveBodyFields() {
        let config: SanitizationConfig = .default

        #expect(config.sensitiveBodyFields.contains("password"))
        #expect(config.sensitiveBodyFields.contains("secret"))
        #expect(config.sensitiveBodyFields.contains("token"))
    }

    @Test("None configuration disables all sanitization")
    func noneConfigDisablesSanitization() {
        let config: SanitizationConfig = .none

        #expect(config.sensitiveHeaders.isEmpty)
        #expect(config.sensitiveQueryParams.isEmpty)
        #expect(config.sensitiveBodyFields.isEmpty)
    }

    @Test("Strict configuration has additional sensitive fields")
    func strictConfigHasAdditionalFields() {
        let config: SanitizationConfig = .strict

        #expect(config.sensitiveBodyFields.contains("creditCard"))
        #expect(config.sensitiveBodyFields.contains("ssn"))
        #expect(config.sensitiveQueryParams.contains("signature"))
    }

    @Test("Custom configuration can be created")
    func customConfiguration() {
        let config: SanitizationConfig = SanitizationConfig(
            sensitiveHeaders: ["x-custom-auth"],
            sensitiveQueryParams: ["custom_token"],
            sensitiveBodyFields: ["customSecret"],
            redactionString: "***"
        )

        #expect(config.sensitiveHeaders.contains("x-custom-auth"))
        #expect(config.sensitiveQueryParams.contains("custom_token"))
        #expect(config.sensitiveBodyFields.contains("customSecret"))
        #expect(config.redactionString == "***")
    }
}

// MARK: - Header Sanitization Tests

@Suite("Header Sanitization Tests")
struct HeaderSanitizationTests {
    @Test("Authorization header is redacted")
    func authorizationHeaderRedacted() {
        let config: SanitizationConfig = .default
        let headers: [String: String] = [
            "Authorization": "Bearer secret-token-12345",
            "Content-Type": "application/json"
        ]

        let sanitized: [String: String] = config.sanitizeHeaders(headers)

        #expect(sanitized["Authorization"] == "[REDACTED]")
        #expect(sanitized["Content-Type"] == "application/json")
    }

    @Test("X-API-Key header is redacted")
    func apiKeyHeaderRedacted() {
        let config: SanitizationConfig = .default
        let headers: [String: String] = [
            "X-API-Key": "my-secret-api-key",
            "Accept": "application/json"
        ]

        let sanitized: [String: String] = config.sanitizeHeaders(headers)

        #expect(sanitized["X-API-Key"] == "[REDACTED]")
        #expect(sanitized["Accept"] == "application/json")
    }

    @Test("Cookie header is redacted")
    func cookieHeaderRedacted() {
        let config: SanitizationConfig = .default
        let headers: [String: String] = [
            "Cookie": "session=abc123; token=secret"
        ]

        let sanitized: [String: String] = config.sanitizeHeaders(headers)

        #expect(sanitized["Cookie"] == "[REDACTED]")
    }

    @Test("Case insensitive header matching")
    func caseInsensitiveHeaderMatching() {
        let config: SanitizationConfig = .default
        let headers: [String: String] = [
            "AUTHORIZATION": "Bearer token",
            "authorization": "Bearer token2"
        ]

        let sanitized: [String: String] = config.sanitizeHeaders(headers)

        #expect(sanitized["AUTHORIZATION"] == "[REDACTED]")
        #expect(sanitized["authorization"] == "[REDACTED]")
    }

    @Test("None config does not redact headers")
    func noneConfigNoRedaction() {
        let config: SanitizationConfig = .none
        let headers: [String: String] = [
            "Authorization": "Bearer secret-token"
        ]

        let sanitized: [String: String] = config.sanitizeHeaders(headers)

        #expect(sanitized["Authorization"] == "Bearer secret-token")
    }

    @Test("Nil headers returns empty dictionary")
    func nilHeadersReturnsEmpty() {
        let config: SanitizationConfig = .default
        let sanitized: [String: String] = config.sanitizeHeaders(nil)

        #expect(sanitized.isEmpty)
    }
}

// MARK: - URL Sanitization Tests

@Suite("URL Sanitization Tests")
struct URLSanitizationTests {
    @Test("Token query param is redacted")
    func tokenQueryParamRedacted() {
        let config: SanitizationConfig = .default
        let url: URL = URL(string: "https://api.example.com/data?token=secret123&page=1")!

        let sanitized: String = config.sanitizeURL(url)

        #expect(sanitized.contains("token="))
        #expect(sanitized.contains("page=1"))
        #expect(!sanitized.contains("secret123"))
    }

    @Test("API key query param is redacted")
    func apiKeyQueryParamRedacted() {
        let config: SanitizationConfig = .default
        let url: URL = URL(string: "https://api.example.com/search?api_key=mykey&q=test")!

        let sanitized: String = config.sanitizeURL(url)

        #expect(sanitized.contains("api_key="))
        #expect(sanitized.contains("q=test"))
        #expect(!sanitized.contains("mykey"))
    }

    @Test("Password query param is redacted")
    func passwordQueryParamRedacted() {
        let config: SanitizationConfig = .default
        let url: URL = URL(string: "https://api.example.com/login?user=john&password=secret")!

        let sanitized: String = config.sanitizeURL(url)

        #expect(sanitized.contains("password="))
        #expect(sanitized.contains("user=john"))
        #expect(!sanitized.contains("=secret"))
    }

    @Test("Multiple sensitive params are redacted")
    func multipleSensitiveParamsRedacted() {
        let config: SanitizationConfig = .default
        let url: URL = URL(string: "https://api.example.com/auth?token=t1&api_key=k1&access_token=a1")!

        let sanitized: String = config.sanitizeURL(url)

        #expect(!sanitized.contains("=t1"))
        #expect(!sanitized.contains("=k1"))
        #expect(!sanitized.contains("=a1"))
        #expect(sanitized.contains("token="))
        #expect(sanitized.contains("api_key="))
        #expect(sanitized.contains("access_token="))
    }

    @Test("URL without query params unchanged")
    func urlWithoutQueryParamsUnchanged() {
        let config: SanitizationConfig = .default
        let url: URL = URL(string: "https://api.example.com/users/123")!

        let sanitized: String = config.sanitizeURL(url)

        #expect(sanitized == "https://api.example.com/users/123")
    }

    @Test("None config does not redact query params")
    func noneConfigNoQueryParamRedaction() {
        let config: SanitizationConfig = .none
        let url: URL = URL(string: "https://api.example.com/data?token=secret")!

        let sanitized: String = config.sanitizeURL(url)

        #expect(sanitized.contains("token=secret"))
    }

    @Test("Nil URL returns 'nil' string")
    func nilURLReturnsNilString() {
        let config: SanitizationConfig = .default

        let sanitized: String = config.sanitizeURL(nil)

        #expect(sanitized == "nil")
    }

    @Test("Case insensitive query param matching")
    func caseInsensitiveQueryParamMatching() {
        let config: SanitizationConfig = .default
        let url: URL = URL(string: "https://api.example.com/data?TOKEN=secret&Token=secret2")!

        let sanitized: String = config.sanitizeURL(url)

        #expect(!sanitized.contains("=secret"))
    }
}

// MARK: - Body Sanitization Tests

@Suite("Body Sanitization Tests")
struct BodySanitizationTests {
    @Test("Password field in JSON body is redacted")
    func passwordFieldRedacted() {
        let config: SanitizationConfig = .default
        let json: [String: Any] = ["username": "john", "password": "secret123"]
        let data: Data = try! JSONSerialization.data(withJSONObject: json)

        let sanitized: String? = config.sanitizeBody(data, contentType: "application/json")

        #expect(sanitized != nil)
        #expect(sanitized!.contains("\"password\":\"[REDACTED]\""))
        #expect(sanitized!.contains("\"username\":\"john\""))
        #expect(!sanitized!.contains("secret123"))
    }

    @Test("Token field in JSON body is redacted")
    func tokenFieldRedacted() {
        let config: SanitizationConfig = .default
        let json: [String: Any] = ["token": "abc123", "data": "value"]
        let data: Data = try! JSONSerialization.data(withJSONObject: json)

        let sanitized: String? = config.sanitizeBody(data, contentType: "application/json")

        #expect(sanitized != nil)
        #expect(sanitized!.contains("\"token\":\"[REDACTED]\""))
        #expect(!sanitized!.contains("abc123"))
    }

    @Test("Multiple sensitive fields are redacted")
    func multipleSensitiveFieldsRedacted() {
        let config: SanitizationConfig = .default
        let json: [String: Any] = [
            "password": "pass1",
            "secret": "sec1",
            "api_key": "key1",
            "name": "John"
        ]
        let data: Data = try! JSONSerialization.data(withJSONObject: json)

        let sanitized: String? = config.sanitizeBody(data, contentType: "application/json")

        #expect(sanitized != nil)
        #expect(sanitized!.contains("\"password\":\"[REDACTED]\""))
        #expect(sanitized!.contains("\"secret\":\"[REDACTED]\""))
        #expect(sanitized!.contains("\"api_key\":\"[REDACTED]\""))
        #expect(sanitized!.contains("\"name\":\"John\""))
    }

    @Test("Non-JSON body is not parsed")
    func nonJSONBodyNotParsed() {
        let config: SanitizationConfig = .default
        let text: String = "password=secret&user=john"
        let data: Data = text.data(using: .utf8)!

        let sanitized: String? = config.sanitizeBody(data, contentType: "text/plain")

        #expect(sanitized == text)
    }

    @Test("None config does not redact body fields")
    func noneConfigNoBodyRedaction() {
        let config: SanitizationConfig = .none
        let json: [String: Any] = ["password": "secret"]
        let data: Data = try! JSONSerialization.data(withJSONObject: json)

        let sanitized: String? = config.sanitizeBody(data, contentType: "application/json")

        #expect(sanitized != nil)
        #expect(sanitized!.contains("secret"))
    }

    @Test("Large body is truncated without parsing")
    func largeBodyTruncated() {
        var config: SanitizationConfig = .default
        config.maxBodySizeForSanitization = 100
        let largeJson: [String: Any] = ["password": "secret", "data": String(repeating: "x", count: 200)]
        let data: Data = try! JSONSerialization.data(withJSONObject: largeJson)

        let sanitized: String? = config.sanitizeBody(data, contentType: "application/json", maxLength: 50)

        #expect(sanitized != nil)
        #expect(sanitized!.count <= 53)
        #expect(sanitized!.hasSuffix("..."))
    }

    @Test("Nil body returns nil")
    func nilBodyReturnsNil() {
        let config: SanitizationConfig = .default

        let sanitized: String? = config.sanitizeBody(nil, contentType: "application/json")

        #expect(sanitized == nil)
    }

    @Test("Empty body returns nil")
    func emptyBodyReturnsNil() {
        let config: SanitizationConfig = .default

        let sanitized: String? = config.sanitizeBody(Data(), contentType: "application/json")

        #expect(sanitized == nil)
    }

    @Test("Nested JSON objects are sanitized recursively")
    func nestedJSONObjectsSanitized() {
        let config: SanitizationConfig = .default
        let json: [String: Any] = [
            "user": [
                "name": "John",
                "password": "secret123",
                "credentials": [
                    "api_key": "key123",
                    "token": "token456"
                ]
            ],
            "data": "value"
        ]
        let data: Data = try! JSONSerialization.data(withJSONObject: json)

        let sanitized: String? = config.sanitizeBody(data, contentType: "application/json")

        #expect(sanitized != nil)
        #expect(!sanitized!.contains("secret123"))
        #expect(!sanitized!.contains("key123"))
        #expect(!sanitized!.contains("token456"))
        #expect(sanitized!.contains("\"name\":\"John\""))
        #expect(sanitized!.contains("\"data\":\"value\""))
    }

    @Test("JSON arrays with sensitive fields are sanitized")
    func jsonArraysSanitized() {
        let config: SanitizationConfig = .default
        let json: [[String: Any]] = [
            ["username": "john", "password": "pass1"],
            ["username": "jane", "password": "pass2"]
        ]
        let data: Data = try! JSONSerialization.data(withJSONObject: json)

        let sanitized: String? = config.sanitizeBody(data, contentType: "application/json")

        #expect(sanitized != nil)
        #expect(!sanitized!.contains("pass1"))
        #expect(!sanitized!.contains("pass2"))
        #expect(sanitized!.contains("\"username\":\"john\""))
        #expect(sanitized!.contains("\"username\":\"jane\""))
    }

    @Test("Deeply nested arrays and objects are sanitized")
    func deeplyNestedStructuresSanitized() {
        let config: SanitizationConfig = .default
        let json: [String: Any] = [
            "items": [
                ["nested": ["deep": ["secret": "hidden"]]],
                ["token": "exposed"]
            ]
        ]
        let data: Data = try! JSONSerialization.data(withJSONObject: json)

        let sanitized: String? = config.sanitizeBody(data, contentType: "application/json")

        #expect(sanitized != nil)
        #expect(!sanitized!.contains("hidden"))
        #expect(!sanitized!.contains("exposed"))
    }
}

// MARK: - LoggingInterceptor Sanitization Tests

@Suite("LoggingInterceptor Sanitization Tests")
struct LoggingInterceptorSanitizationTests {
    @Test("Interceptor with default sanitization config")
    func interceptorWithDefaultConfig() async throws {
        let interceptor: LoggingInterceptor = LoggingInterceptor(level: .verbose)
        var request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test?token=secret")!)
        request.addValue("Bearer token123", forHTTPHeaderField: "Authorization")

        let result: URLRequest = try await interceptor.intercept(request: request)

        #expect(result.url == request.url)
    }

    @Test("Interceptor with none sanitization config")
    func interceptorWithNoneConfig() async throws {
        let interceptor: LoggingInterceptor = LoggingInterceptor(
            level: .verbose,
            sanitization: .none
        )
        var request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test")!)
        request.addValue("Bearer token123", forHTTPHeaderField: "Authorization")

        let result: URLRequest = try await interceptor.intercept(request: request)

        #expect(result.url == request.url)
    }

    @Test("Interceptor with custom sanitization config")
    func interceptorWithCustomConfig() async throws {
        let customConfig: SanitizationConfig = SanitizationConfig(
            sensitiveHeaders: ["x-custom-secret"],
            sensitiveQueryParams: ["custom_token"],
            sensitiveBodyFields: ["customPassword"]
        )
        let interceptor: LoggingInterceptor = LoggingInterceptor(
            level: .verbose,
            sanitization: customConfig
        )
        let request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test")!)

        let result: URLRequest = try await interceptor.intercept(request: request)

        #expect(result.url == request.url)
    }

    @Test("Interceptor does not modify request")
    func interceptorPassthrough() async throws {
        let interceptor: LoggingInterceptor = LoggingInterceptor(level: .verbose)
        var request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/test")!)
        request.addValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.httpBody = "{\"password\":\"secret\"}".data(using: .utf8)

        let result: URLRequest = try await interceptor.intercept(request: request)

        #expect(result.url == request.url)
        #expect(result.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(result.httpBody == request.httpBody)
    }

    @Test("Interceptor does not modify response data")
    func interceptorResponsePassthrough() async throws {
        let interceptor: LoggingInterceptor = LoggingInterceptor(level: .verbose)
        let response: HTTPURLResponse = HTTPURLResponse(
            url: URL(string: "https://api.example.com/test")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Set-Cookie": "session=secret"]
        )!
        let data: Data = "{\"token\":\"secret\"}".data(using: .utf8)!

        let result: Data = try await interceptor.intercept(response: response, data: data)

        #expect(result == data)
    }
}
