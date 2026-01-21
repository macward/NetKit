import Testing
import Foundation
@testable import NetKit

// MARK: - Test Helpers

private struct DeduplicationTestEnvironment: NetworkEnvironment {
    var baseURL: URL { URL(string: "https://api.test.com")! }
    var defaultHeaders: [String: String] { [:] }
    var timeout: TimeInterval { 30 }
}

private struct TestResponse: Codable, Equatable, Sendable {
    let id: String
    let value: String
}

private struct DeduplicatedGetEndpoint: Endpoint {
    var path: String { "/data" }
    var method: HTTPMethod { .get }
    var deduplicationPolicy: DeduplicationPolicy { .automatic }
    typealias Response = TestResponse
}

private struct NeverDeduplicateEndpoint: Endpoint {
    var path: String { "/data" }
    var method: HTTPMethod { .get }
    var deduplicationPolicy: DeduplicationPolicy { .never }
    typealias Response = TestResponse
}

private struct AlwaysDeduplicateEndpoint: Endpoint {
    var path: String { "/data" }
    var method: HTTPMethod { .post }
    var deduplicationPolicy: DeduplicationPolicy { .always }
    typealias Response = TestResponse
}

private struct PostEndpoint: Endpoint {
    let bodyData: String

    var path: String { "/data" }
    var method: HTTPMethod { .post }
    var body: (any Encodable & Sendable)? { ["data": bodyData] }
    typealias Response = TestResponse
}

private struct ParameterizedGetEndpoint: Endpoint {
    let id: String

    var path: String { "/data/\(id)" }
    var method: HTTPMethod { .get }
    typealias Response = TestResponse
}

// MARK: - DeduplicationPolicy Tests

@Suite("DeduplicationPolicy Tests")
struct DeduplicationPolicyTests {
    @Test("Automatic is the default for endpoints")
    func automaticIsDefault() {
        struct DefaultEndpoint: Endpoint {
            var path: String { "/test" }
            var method: HTTPMethod { .get }
            typealias Response = String
        }

        let endpoint = DefaultEndpoint()
        if case .automatic = endpoint.deduplicationPolicy {
            // Expected
        } else {
            Issue.record("Expected automatic deduplication policy as default")
        }
    }

    @Test("Never policy can be set")
    func neverPolicyCanBeSet() {
        let endpoint = NeverDeduplicateEndpoint()
        if case .never = endpoint.deduplicationPolicy {
            // Expected
        } else {
            Issue.record("Expected never deduplication policy")
        }
    }

    @Test("Always policy can be set")
    func alwaysPolicyCanBeSet() {
        let endpoint = AlwaysDeduplicateEndpoint()
        if case .always = endpoint.deduplicationPolicy {
            // Expected
        } else {
            Issue.record("Expected always deduplication policy")
        }
    }
}

// MARK: - RequestKey Tests

@Suite("RequestKey Tests")
struct RequestKeyTests {
    @Test("RequestKey is created from URLRequest")
    func requestKeyFromURLRequest() {
        var request = URLRequest(url: URL(string: "https://api.example.com/users")!)
        request.httpMethod = "GET"

        let key = RequestKey(from: request)

        #expect(key.url.absoluteString == "https://api.example.com/users")
        #expect(key.method == "GET")
        #expect(key.bodyHash == nil)
    }

    @Test("RequestKey includes body hash when body exists")
    func requestKeyWithBody() {
        var request = URLRequest(url: URL(string: "https://api.example.com/users")!)
        request.httpMethod = "POST"
        request.httpBody = "{\"name\":\"test\"}".data(using: .utf8)

        let key = RequestKey(from: request)

        #expect(key.bodyHash != nil)
    }

    @Test("Same requests produce equal keys")
    func sameRequestsEqualKeys() {
        var request1 = URLRequest(url: URL(string: "https://api.example.com/users")!)
        request1.httpMethod = "GET"

        var request2 = URLRequest(url: URL(string: "https://api.example.com/users")!)
        request2.httpMethod = "GET"

        let key1 = RequestKey(from: request1)
        let key2 = RequestKey(from: request2)

        #expect(key1 == key2)
    }

    @Test("Different URLs produce different keys")
    func differentURLsDifferentKeys() {
        var request1 = URLRequest(url: URL(string: "https://api.example.com/users")!)
        request1.httpMethod = "GET"

        var request2 = URLRequest(url: URL(string: "https://api.example.com/posts")!)
        request2.httpMethod = "GET"

        let key1 = RequestKey(from: request1)
        let key2 = RequestKey(from: request2)

        #expect(key1 != key2)
    }

    @Test("Different methods produce different keys")
    func differentMethodsDifferentKeys() {
        var request1 = URLRequest(url: URL(string: "https://api.example.com/users")!)
        request1.httpMethod = "GET"

        var request2 = URLRequest(url: URL(string: "https://api.example.com/users")!)
        request2.httpMethod = "POST"

        let key1 = RequestKey(from: request1)
        let key2 = RequestKey(from: request2)

        #expect(key1 != key2)
    }

    @Test("Different bodies produce different keys")
    func differentBodiesDifferentKeys() {
        var request1 = URLRequest(url: URL(string: "https://api.example.com/users")!)
        request1.httpMethod = "POST"
        request1.httpBody = "{\"name\":\"john\"}".data(using: .utf8)

        var request2 = URLRequest(url: URL(string: "https://api.example.com/users")!)
        request2.httpMethod = "POST"
        request2.httpBody = "{\"name\":\"jane\"}".data(using: .utf8)

        let key1 = RequestKey(from: request1)
        let key2 = RequestKey(from: request2)

        #expect(key1 != key2)
    }

    @Test("RequestKey is hashable for use in dictionaries")
    func requestKeyIsHashable() {
        var request = URLRequest(url: URL(string: "https://api.example.com/users")!)
        request.httpMethod = "GET"

        let key = RequestKey(from: request)
        var dictionary: [RequestKey: String] = [:]
        dictionary[key] = "value"

        #expect(dictionary[key] == "value")
    }
}

// MARK: - InFlightRequestTracker Tests

@Suite("InFlightRequestTracker Tests")
struct InFlightRequestTrackerTests {
    @Test("Tracker starts empty")
    func trackerStartsEmpty() async {
        let tracker = InFlightRequestTracker()
        var request = URLRequest(url: URL(string: "https://api.example.com/test")!)
        request.httpMethod = "GET"
        let key = RequestKey(from: request)

        let existingTask = await tracker.existingTask(for: key)

        #expect(existingTask == nil)
    }

    @Test("Can register and retrieve task")
    func canRegisterAndRetrieveTask() async {
        let tracker = InFlightRequestTracker()
        var request = URLRequest(url: URL(string: "https://api.example.com/test")!)
        request.httpMethod = "GET"
        let key = RequestKey(from: request)

        let task = Task<Data, Error> {
            "test".data(using: .utf8)!
        }

        await tracker.register(task, for: key)
        let retrievedTask = await tracker.existingTask(for: key)

        #expect(retrievedTask != nil)
    }

    @Test("Can remove task")
    func canRemoveTask() async {
        let tracker = InFlightRequestTracker()
        var request = URLRequest(url: URL(string: "https://api.example.com/test")!)
        request.httpMethod = "GET"
        let key = RequestKey(from: request)

        let task = Task<Data, Error> {
            "test".data(using: .utf8)!
        }

        await tracker.register(task, for: key)
        await tracker.remove(key: key)
        let retrievedTask = await tracker.existingTask(for: key)

        #expect(retrievedTask == nil)
    }

    @Test("Different keys maintain separate tasks")
    func differentKeysSeparateTasks() async {
        let tracker = InFlightRequestTracker()

        var request1 = URLRequest(url: URL(string: "https://api.example.com/test1")!)
        request1.httpMethod = "GET"
        let key1 = RequestKey(from: request1)

        var request2 = URLRequest(url: URL(string: "https://api.example.com/test2")!)
        request2.httpMethod = "GET"
        let key2 = RequestKey(from: request2)

        let task1 = Task<Data, Error> { "data1".data(using: .utf8)! }
        let task2 = Task<Data, Error> { "data2".data(using: .utf8)! }

        await tracker.register(task1, for: key1)
        await tracker.register(task2, for: key2)

        let retrieved1 = await tracker.existingTask(for: key1)
        let retrieved2 = await tracker.existingTask(for: key2)

        #expect(retrieved1 != nil)
        #expect(retrieved2 != nil)

        // Remove one shouldn't affect the other
        await tracker.remove(key: key1)
        #expect(await tracker.existingTask(for: key1) == nil)
        #expect(await tracker.existingTask(for: key2) != nil)
    }
}

// MARK: - MockNetworkClient Deduplication Tests

@Suite("MockNetworkClient Deduplication Tests")
struct MockNetworkClientDeduplicationTests {
    @Test("Concurrent identical GET requests all get responses")
    func concurrentIdenticalRequestsAllGetResponses() async throws {
        let client = MockNetworkClient()
        let expectedResponse = TestResponse(id: "1", value: "test")

        await client.stub(DeduplicatedGetEndpoint.self, delay: 0.05) { _ in
            expectedResponse
        }

        // Launch 10 concurrent requests
        let results = try await withThrowingTaskGroup(of: TestResponse.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await client.request(DeduplicatedGetEndpoint())
                }
            }

            var responses: [TestResponse] = []
            for try await response in group {
                responses.append(response)
            }
            return responses
        }

        // All should get the same response
        #expect(results.count == 10)
        for result in results {
            #expect(result == expectedResponse)
        }

        // MockNetworkClient tracks all calls
        let count = await client.callCount(for: DeduplicatedGetEndpoint.self)
        #expect(count == 10)
    }

    @Test("Different parameterized endpoints are tracked separately")
    func differentEndpointsTrackedSeparately() async throws {
        let client = MockNetworkClient()

        await client.stub(ParameterizedGetEndpoint.self, delay: 0.02) { endpoint in
            TestResponse(id: endpoint.id, value: "response")
        }

        async let response1 = client.request(ParameterizedGetEndpoint(id: "1"))
        async let response2 = client.request(ParameterizedGetEndpoint(id: "2"))

        let results = try await [response1, response2]

        #expect(results[0].id == "1")
        #expect(results[1].id == "2")

        // Both calls are tracked
        let count = await client.callCount(for: ParameterizedGetEndpoint.self)
        #expect(count == 2)
    }

    @Test("POST requests are tracked")
    func postRequestsAreTracked() async throws {
        let client = MockNetworkClient()

        await client.stub(PostEndpoint.self, delay: 0.02) { endpoint in
            TestResponse(id: "1", value: endpoint.bodyData)
        }

        async let response1 = client.request(PostEndpoint(bodyData: "first"))
        async let response2 = client.request(PostEndpoint(bodyData: "second"))

        let results = try await [response1, response2]

        #expect(results[0].value == "first")
        #expect(results[1].value == "second")

        let count = await client.callCount(for: PostEndpoint.self)
        #expect(count == 2)
    }

    @Test("Error is propagated to all callers")
    func errorPropagatedToAllCallers() async throws {
        let client = MockNetworkClient()

        await client.stubError(DeduplicatedGetEndpoint.self, error: .timeout())

        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        _ = try await client.request(DeduplicatedGetEndpoint())
                        Issue.record("Expected timeout error")
                    } catch let error as NetworkError {
                        #expect(error.kind == .timeout)
                    }
                }
            }
        }
    }
}

// MARK: - Deduplication Policy Integration Tests

@Suite("Deduplication Policy Integration Tests")
struct DeduplicationPolicyIntegrationTests {
    @Test("Never policy endpoint is configured correctly")
    func neverPolicyEndpointConfigured() async throws {
        let client = MockNetworkClient()

        await client.stub(NeverDeduplicateEndpoint.self) { _ in
            TestResponse(id: "1", value: "test")
        }

        // Multiple sequential calls
        _ = try await client.request(NeverDeduplicateEndpoint())
        _ = try await client.request(NeverDeduplicateEndpoint())

        let count = await client.callCount(for: NeverDeduplicateEndpoint.self)
        #expect(count == 2)
    }

    @Test("Always policy endpoint is configured correctly")
    func alwaysPolicyEndpointConfigured() async throws {
        let client = MockNetworkClient()

        await client.stub(AlwaysDeduplicateEndpoint.self, delay: 0.02) { _ in
            TestResponse(id: "1", value: "test")
        }

        // Concurrent calls
        async let response1 = client.request(AlwaysDeduplicateEndpoint())
        async let response2 = client.request(AlwaysDeduplicateEndpoint())

        let results = try await [response1, response2]

        #expect(results[0] == results[1])
    }

    @Test("Default GET endpoints use automatic deduplication")
    func defaultGetUsesAutomatic() {
        struct DefaultGetEndpoint: Endpoint {
            var path: String { "/test" }
            var method: HTTPMethod { .get }
            typealias Response = String
        }

        let endpoint = DefaultGetEndpoint()

        if case .automatic = endpoint.deduplicationPolicy {
            // Expected - automatic means GET will be deduplicated
        } else {
            Issue.record("Expected automatic policy for GET endpoints")
        }
    }

    @Test("Default POST endpoints use automatic deduplication (no dedup)")
    func defaultPostUsesAutomatic() {
        struct DefaultPostEndpoint: Endpoint {
            var path: String { "/test" }
            var method: HTTPMethod { .post }
            typealias Response = String
        }

        let endpoint = DefaultPostEndpoint()

        if case .automatic = endpoint.deduplicationPolicy {
            // Expected - automatic means POST won't be deduplicated
        } else {
            Issue.record("Expected automatic policy for POST endpoints")
        }
    }
}

// MARK: - Thread Safety Tests

@Suite("Deduplication Thread Safety Tests")
struct DeduplicationThreadSafetyTests {
    @Test("Concurrent access to tracker is thread-safe")
    func concurrentAccessIsThreadSafe() async {
        let tracker = InFlightRequestTracker()

        await withTaskGroup(of: Void.self) { group in
            // Multiple concurrent registrations
            for i in 0..<100 {
                group.addTask {
                    var request = URLRequest(url: URL(string: "https://api.example.com/test/\(i)")!)
                    request.httpMethod = "GET"
                    let key = RequestKey(from: request)
                    let task = Task<Data, Error> { "data\(i)".data(using: .utf8)! }
                    await tracker.register(task, for: key)
                }
            }

            // Concurrent lookups
            for i in 0..<100 {
                group.addTask {
                    var request = URLRequest(url: URL(string: "https://api.example.com/test/\(i)")!)
                    request.httpMethod = "GET"
                    let key = RequestKey(from: request)
                    _ = await tracker.existingTask(for: key)
                }
            }

            // Concurrent removals
            for i in 0..<50 {
                group.addTask {
                    var request = URLRequest(url: URL(string: "https://api.example.com/test/\(i)")!)
                    request.httpMethod = "GET"
                    let key = RequestKey(from: request)
                    await tracker.remove(key: key)
                }
            }
        }

        // If we got here without crashes, the test passes
    }

    @Test("Stress test with high concurrency")
    func stressTestHighConcurrency() async throws {
        let client = MockNetworkClient()
        let response = TestResponse(id: "stress", value: "test")

        await client.stub(DeduplicatedGetEndpoint.self) { _ in response }

        let results = try await withThrowingTaskGroup(of: TestResponse.self) { group in
            for _ in 0..<1000 {
                group.addTask {
                    try await client.request(DeduplicatedGetEndpoint())
                }
            }

            var responses: [TestResponse] = []
            for try await result in group {
                responses.append(result)
            }
            return responses
        }

        #expect(results.count == 1000)
        #expect(results.allSatisfy { $0 == response })
    }
}
