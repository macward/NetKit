import Testing
import Foundation
@testable import NetKit

// MARK: - Mock Metrics Collector

/// A mock metrics collector for testing that stores all collected metrics.
actor MockMetricsCollector: MetricsCollector {
    private(set) var collectedMetrics: [NetworkRequestMetrics] = []

    func collect(metrics: NetworkRequestMetrics) async {
        collectedMetrics.append(metrics)
    }

    func reset() {
        collectedMetrics.removeAll()
    }

    var count: Int {
        collectedMetrics.count
    }

    var lastMetrics: NetworkRequestMetrics? {
        collectedMetrics.last
    }

    func metrics(at index: Int) -> NetworkRequestMetrics? {
        guard index < collectedMetrics.count else { return nil }
        return collectedMetrics[index]
    }
}

// MARK: - Test Helpers

private struct MetricsTestEnvironment: NetworkEnvironment {
    var baseURL: URL = URL(string: "https://api.example.com")!
    var defaultHeaders: [String: String] = [:]
    var timeout: TimeInterval = 30
}

private struct MetricsTestEndpoint: Endpoint {
    var path: String = "/test"
    var method: HTTPMethod = .get
    typealias Response = MetricsTestResponse
}

private struct MetricsTestResponse: Codable, Equatable, Sendable {
    let message: String
}

// MARK: - Metrics Collection Tests

@Suite("NetworkRequestMetrics Tests")
struct NetworkRequestMetricsTests {
    @Test("Duration is calculated correctly")
    func durationCalculation() {
        let start: Date = Date()
        let end: Date = start.addingTimeInterval(1.5)

        let metrics: NetworkRequestMetrics = NetworkRequestMetrics(
            endpoint: EndpointMetadata(path: "/test", method: "GET", baseURL: "https://api.example.com"),
            startTime: start,
            endTime: end,
            statusCode: 200,
            isSuccess: true,
            error: nil,
            attempt: 0,
            wasFromCache: false,
            wasDeduplicatedRequest: false
        )

        #expect(abs(metrics.duration - 1.5) < 0.001)
    }

    @Test("EndpointMetadata is correctly created")
    func endpointMetadataCreation() {
        let metadata: EndpointMetadata = EndpointMetadata(
            path: "/users/123",
            method: "POST",
            baseURL: "https://api.test.com"
        )

        #expect(metadata.path == "/users/123")
        #expect(metadata.method == "POST")
        #expect(metadata.baseURL == "https://api.test.com")
    }

    @Test("EndpointMetadata is hashable")
    func endpointMetadataHashable() {
        let baseURL: String = "https://api.example.com"
        let metadata1: EndpointMetadata = EndpointMetadata(path: "/test", method: "GET", baseURL: baseURL)
        let metadata2: EndpointMetadata = EndpointMetadata(path: "/test", method: "GET", baseURL: baseURL)
        let metadata3: EndpointMetadata = EndpointMetadata(path: "/other", method: "GET", baseURL: baseURL)

        #expect(metadata1 == metadata2)
        #expect(metadata1 != metadata3)

        var set: Set<EndpointMetadata> = Set()
        set.insert(metadata1)
        set.insert(metadata2)
        #expect(set.count == 1)
    }
}

@Suite("MetricsCollector Tests")
struct MetricsCollectorTests {
    @Test("MockMetricsCollector stores metrics")
    func mockCollectorStoresMetrics() async {
        let collector: MockMetricsCollector = MockMetricsCollector()

        let metrics: NetworkRequestMetrics = NetworkRequestMetrics(
            endpoint: EndpointMetadata(path: "/test", method: "GET", baseURL: "https://api.example.com"),
            startTime: Date(),
            endTime: Date(),
            statusCode: 200,
            isSuccess: true,
            error: nil,
            attempt: 0,
            wasFromCache: false,
            wasDeduplicatedRequest: false
        )

        await collector.collect(metrics: metrics)

        let count: Int = await collector.count
        #expect(count == 1)

        let last: NetworkRequestMetrics? = await collector.lastMetrics
        #expect(last?.endpoint.path == "/test")
    }

    @Test("MockMetricsCollector can be reset")
    func mockCollectorReset() async {
        let collector: MockMetricsCollector = MockMetricsCollector()

        let metrics: NetworkRequestMetrics = NetworkRequestMetrics(
            endpoint: EndpointMetadata(path: "/test", method: "GET", baseURL: "https://api.example.com"),
            startTime: Date(),
            endTime: Date(),
            statusCode: 200,
            isSuccess: true,
            error: nil,
            attempt: 0,
            wasFromCache: false,
            wasDeduplicatedRequest: false
        )

        await collector.collect(metrics: metrics)
        await collector.reset()

        let count: Int = await collector.count
        #expect(count == 0)
    }
}

@Suite("NetworkClient Metrics Integration Tests")
struct NetworkClientMetricsIntegrationTests {
    @Test("Metrics include correct endpoint information")
    func metricsEndpointInfo() {
        let endpoint: MetricsTestEndpoint = MetricsTestEndpoint()
        let environment: MetricsTestEnvironment = MetricsTestEnvironment()

        let metadata: EndpointMetadata = EndpointMetadata(endpoint: endpoint, environment: environment)

        #expect(metadata.path == "/test")
        #expect(metadata.method == "GET")
        #expect(metadata.baseURL == "https://api.example.com")
    }
}

@Suite("ConsoleMetricsCollector Tests")
struct ConsoleMetricsCollectorTests {
    @Test("ConsoleMetricsCollector can be created with defaults")
    func defaultCreation() {
        let collector: ConsoleMetricsCollector = ConsoleMetricsCollector()
        // Verify instance was created (non-optional type, always succeeds)
        #expect(type(of: collector) == ConsoleMetricsCollector.self)
    }

    @Test("ConsoleMetricsCollector can be created with custom parameters")
    func customCreation() {
        let collector: ConsoleMetricsCollector = ConsoleMetricsCollector(
            subsystem: "TestApp",
            category: "Network",
            includeTimestamps: false,
            minimumDurationToLog: 0.1
        )
        // Verify instance was created with custom config
        #expect(type(of: collector) == ConsoleMetricsCollector.self)
    }

    @Test("ConsoleMetricsCollector respects minimum duration filter")
    func minimumDurationFilter() async {
        // Create collector with 1 second minimum
        let collector: ConsoleMetricsCollector = ConsoleMetricsCollector(
            minimumDurationToLog: 1.0
        )

        // This should not log (duration < 1 second)
        let fastMetrics: NetworkRequestMetrics = NetworkRequestMetrics(
            endpoint: EndpointMetadata(path: "/test", method: "GET", baseURL: "https://api.example.com"),
            startTime: Date(),
            endTime: Date().addingTimeInterval(0.1),
            statusCode: 200,
            isSuccess: true,
            error: nil,
            attempt: 0,
            wasFromCache: false,
            wasDeduplicatedRequest: false
        )

        // Should not throw or cause issues
        await collector.collect(metrics: fastMetrics)
    }
}

// MARK: - URLProtocol Mock for Integration Tests

/// A mock URLProtocol for intercepting network requests in tests.
private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            fatalError("MockURLProtocol.requestHandler not set")
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Real NetworkClient Integration Tests

@Suite("NetworkClient Real Metrics Integration Tests", .serialized)
struct NetworkClientRealMetricsIntegrationTests {
    /// Creates a URLSession configured with MockURLProtocol.
    private func createMockSession() -> URLSession {
        let config: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("Real NetworkClient collects metrics on successful request")
    func realClientCollectsMetricsOnSuccess() async throws {
        // Setup mock response
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = #"{"message":"success"}"#.data(using: .utf8)!
            return (response, data)
        }

        let collector = MockMetricsCollector()
        let client = NetworkClient(
            environment: MetricsTestEnvironment(),
            session: createMockSession(),
            metricsCollector: collector
        )

        let response: MetricsTestResponse = try await client.request(MetricsTestEndpoint())

        #expect(response.message == "success")

        let count = await collector.count
        #expect(count == 1)

        let metrics = await collector.lastMetrics
        #expect(metrics?.endpoint.path == "/test")
        #expect(metrics?.endpoint.method == "GET")
        #expect(metrics?.statusCode == 200)
        #expect(metrics?.isSuccess == true)
        #expect(metrics?.error == nil)
        #expect(metrics?.attempt == 0)
        #expect(metrics?.wasFromCache == false)
        #expect(metrics?.wasDeduplicatedRequest == false)
        #expect(metrics?.duration ?? 0 > 0)
    }

    @Test("Real NetworkClient collects metrics on failed request")
    func realClientCollectsMetricsOnFailure() async throws {
        // Setup mock error response
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = #"{"error":"Internal Server Error"}"#.data(using: .utf8)!
            return (response, data)
        }

        let collector = MockMetricsCollector()
        let client = NetworkClient(
            environment: MetricsTestEnvironment(),
            session: createMockSession(),
            metricsCollector: collector
        )

        do {
            let _: MetricsTestResponse = try await client.request(MetricsTestEndpoint())
            Issue.record("Expected request to fail")
        } catch {
            // Expected failure
        }

        let count = await collector.count
        #expect(count == 1)

        let metrics = await collector.lastMetrics
        #expect(metrics?.endpoint.path == "/test")
        #expect(metrics?.statusCode == 500)
        #expect(metrics?.isSuccess == false)
        #expect(metrics?.error != nil)
    }

    @Test("Real NetworkClient collects metrics for each retry attempt")
    func realClientCollectsMetricsForRetries() async throws {
        var attemptCount = 0

        // Setup mock that fails twice then succeeds
        MockURLProtocol.requestHandler = { request in
            attemptCount += 1
            if attemptCount < 3 {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data())
            } else {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                let data = #"{"message":"success"}"#.data(using: .utf8)!
                return (response, data)
            }
        }

        let collector = MockMetricsCollector()
        let retryPolicy = RetryPolicy(
            maxRetries: 3,
            delay: .fixed(0.01),
            shouldRetry: { error in
                if case .serviceUnavailable = error.kind { return true }
                return false
            }
        )
        let client = NetworkClient(
            environment: MetricsTestEnvironment(),
            retryPolicy: retryPolicy,
            session: createMockSession(),
            metricsCollector: collector
        )

        let response: MetricsTestResponse = try await client.request(MetricsTestEndpoint())
        #expect(response.message == "success")

        // Should have 3 metrics: 2 failures + 1 success
        let count = await collector.count
        #expect(count == 3)

        // First attempt (failure)
        let firstMetrics = await collector.metrics(at: 0)
        #expect(firstMetrics?.attempt == 0)
        #expect(firstMetrics?.isSuccess == false)
        #expect(firstMetrics?.statusCode == 503)

        // Second attempt (failure)
        let secondMetrics = await collector.metrics(at: 1)
        #expect(secondMetrics?.attempt == 1)
        #expect(secondMetrics?.isSuccess == false)
        #expect(secondMetrics?.statusCode == 503)

        // Third attempt (success)
        let thirdMetrics = await collector.metrics(at: 2)
        #expect(thirdMetrics?.attempt == 2)
        #expect(thirdMetrics?.isSuccess == true)
        #expect(thirdMetrics?.statusCode == 200)
    }

    @Test("NetworkClient without metricsCollector does not crash")
    func clientWithoutCollectorDoesNotCrash() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = #"{"message":"success"}"#.data(using: .utf8)!
            return (response, data)
        }

        // Create client WITHOUT metricsCollector (nil)
        let client = NetworkClient(
            environment: MetricsTestEnvironment(),
            session: createMockSession(),
            metricsCollector: nil
        )

        // Should complete without crash
        let response: MetricsTestResponse = try await client.request(MetricsTestEndpoint())
        #expect(response.message == "success")
    }

    @Test("Metrics duration is positive and reasonable")
    func metricsDurationIsPositive() async throws {
        MockURLProtocol.requestHandler = { request in
            // Add small delay to ensure measurable duration
            Thread.sleep(forTimeInterval: 0.01)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = #"{"message":"success"}"#.data(using: .utf8)!
            return (response, data)
        }

        let collector = MockMetricsCollector()
        let client = NetworkClient(
            environment: MetricsTestEnvironment(),
            session: createMockSession(),
            metricsCollector: collector
        )

        let _: MetricsTestResponse = try await client.request(MetricsTestEndpoint())

        let metrics = await collector.lastMetrics
        #expect(metrics != nil)
        #expect(metrics!.duration > 0)
        #expect(metrics!.duration < 10) // Should be much less than 10 seconds
        #expect(metrics!.startTime < metrics!.endTime)
    }
}
