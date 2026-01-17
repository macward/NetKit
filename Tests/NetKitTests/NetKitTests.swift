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
        #expect(NetworkError.invalidURL == NetworkError.invalidURL)
        #expect(NetworkError.noConnection == NetworkError.noConnection)
        #expect(NetworkError.timeout == NetworkError.timeout)
        #expect(NetworkError.unauthorized == NetworkError.unauthorized)
        #expect(NetworkError.forbidden == NetworkError.forbidden)
        #expect(NetworkError.notFound == NetworkError.notFound)
        #expect(NetworkError.serverError(statusCode: 500) == NetworkError.serverError(statusCode: 500))
        #expect(NetworkError.serverError(statusCode: 500) != NetworkError.serverError(statusCode: 502))
    }

    @Test("Different error types are not equal")
    func inequality() {
        #expect(NetworkError.invalidURL != NetworkError.noConnection)
        #expect(NetworkError.timeout != NetworkError.unauthorized)
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

        #expect(policy.shouldRetry(error: .noConnection, attempt: 0) == true)
        #expect(policy.shouldRetry(error: .timeout, attempt: 0) == true)
        #expect(policy.shouldRetry(error: .serverError(statusCode: 500), attempt: 0) == true)
        #expect(policy.shouldRetry(error: .serverError(statusCode: 503), attempt: 0) == true)
    }

    @Test("Should not retry on non-retryable errors")
    func shouldNotRetryOnNonRetryableErrors() {
        let policy = RetryPolicy(maxRetries: 3)

        #expect(policy.shouldRetry(error: .unauthorized, attempt: 0) == false)
        #expect(policy.shouldRetry(error: .forbidden, attempt: 0) == false)
        #expect(policy.shouldRetry(error: .notFound, attempt: 0) == false)
        #expect(policy.shouldRetry(error: .invalidURL, attempt: 0) == false)
    }

    @Test("Should respect max retries")
    func respectsMaxRetries() {
        let policy = RetryPolicy(maxRetries: 2)

        #expect(policy.shouldRetry(error: .timeout, attempt: 0) == true)
        #expect(policy.shouldRetry(error: .timeout, attempt: 1) == true)
        #expect(policy.shouldRetry(error: .timeout, attempt: 2) == false)
        #expect(policy.shouldRetry(error: .timeout, attempt: 3) == false)
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
        let policy = RetryPolicy(maxRetries: 3, delay: .exponential(base: 1.0, multiplier: 2.0, jitter: 0))

        #expect(policy.delay(for: 0) == 1.0)
        #expect(policy.delay(for: 1) == 2.0)
        #expect(policy.delay(for: 2) == 4.0)
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

        await client.stubError(GetUserEndpoint.self, error: .notFound)

        do {
            _ = try await client.request(GetUserEndpoint(id: "123"))
            Issue.record("Expected error to be thrown")
        } catch let error as NetworkError {
            #expect(error == .notFound)
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
        #expect(LongPollingState.failed(.timeout) == LongPollingState.failed(.timeout))
        #expect(LongPollingState.failed(.timeout) != LongPollingState.failed(.noConnection))
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
            .failure(.timeout),
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
            #expect(error == .timeout)
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
        #expect(NetworkError.noContent == NetworkError.noContent)
        #expect(NetworkError.noContent != NetworkError.notFound)
    }
}
