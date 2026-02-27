import Foundation

/// A protocol for collecting network request metrics.
///
/// Implement this protocol to capture request timing, success/failure rates,
/// and other telemetry data. The collector is called asynchronously after each
/// request completes, allowing for non-blocking analytics integration.
///
/// ## Usage
///
/// ```swift
/// let client = NetworkClient(
///     environment: myEnvironment,
///     metricsCollector: MyMetricsCollector()
/// )
/// ```
///
/// ## Creating a Custom Collector
///
/// ```swift
/// final class AnalyticsMetricsCollector: MetricsCollector {
///     func collect(metrics: NetworkRequestMetrics) async {
///         Analytics.log(event: "network_request", parameters: [
///             "endpoint": metrics.endpoint.path,
///             "duration_ms": metrics.duration * 1000,
///             "success": metrics.isSuccess
///         ])
///     }
/// }
/// ```
///
/// ## Third-Party Integration Examples
///
/// ### Firebase Analytics
///
/// ```swift
/// final class FirebaseMetricsCollector: MetricsCollector {
///     func collect(metrics: NetworkRequestMetrics) async {
///         Analytics.logEvent("network_request", parameters: [
///             "endpoint": metrics.endpoint.path,
///             "method": metrics.endpoint.method,
///             "duration_ms": metrics.duration * 1000,
///             "status_code": metrics.statusCode ?? 0,
///             "success": metrics.isSuccess,
///             "retry_count": metrics.attempt,
///             "from_cache": metrics.wasFromCache
///         ])
///     }
/// }
/// ```
///
/// ### Sentry Performance Monitoring
///
/// ```swift
/// final class SentryMetricsCollector: MetricsCollector {
///     func collect(metrics: NetworkRequestMetrics) async {
///         let transaction = SentrySDK.startTransaction(
///             name: "\(metrics.endpoint.method) \(metrics.endpoint.path)",
///             operation: "http.client"
///         )
///         transaction.setData(value: metrics.statusCode, key: "http.status_code")
///         transaction.setData(value: metrics.duration, key: "duration")
///         transaction.finish(status: metrics.isSuccess ? .ok : .internalError)
///     }
/// }
/// ```
///
/// ### DataDog RUM
///
/// ```swift
/// final class DataDogMetricsCollector: MetricsCollector {
///     func collect(metrics: NetworkRequestMetrics) async {
///         RUMMonitor.shared().addResourceMetrics(
///             resourceKey: "\(metrics.endpoint.method)-\(metrics.endpoint.path)",
///             metrics: .init(
///                 fetch: .init(
///                     start: metrics.startTime,
///                     end: metrics.endTime
///                 )
///             ),
///             attributes: [
///                 "http.status_code": metrics.statusCode ?? 0,
///                 "retry_count": metrics.attempt
///             ]
///         )
///     }
/// }
/// ```
///
/// ## Sampling for High-Traffic Applications
///
/// ```swift
/// final class SampledMetricsCollector: MetricsCollector {
///     private let underlyingCollector: MetricsCollector
///     private let sampleRate: Double // 0.0 to 1.0
///
///     init(collector: MetricsCollector, sampleRate: Double) {
///         self.underlyingCollector = collector
///         self.sampleRate = sampleRate
///     }
///
///     func collect(metrics: NetworkRequestMetrics) async {
///         // Always collect errors
///         if !metrics.isSuccess || Double.random(in: 0...1) < sampleRate {
///             await underlyingCollector.collect(metrics: metrics)
///         }
///     }
/// }
/// ```
public protocol MetricsCollector: Sendable {
    /// Called after a network request completes (success or failure).
    ///
    /// This method is called asynchronously and should not block.
    /// For high-traffic applications, consider implementing sampling
    /// to reduce overhead.
    ///
    /// - Parameter metrics: The metrics captured for the completed request.
    func collect(metrics: NetworkRequestMetrics) async
}

// MARK: - NetworkRequestMetrics

/// Metrics captured for a single network request.
///
/// Contains timing information, endpoint details, and the result of the request.
/// For requests with retries, metrics are collected for each individual attempt.
public struct NetworkRequestMetrics: Sendable {
    /// Metadata about the endpoint that was called.
    public let endpoint: EndpointMetadata

    /// The time when the request started.
    public let startTime: Date

    /// The time when the request completed (success or failure).
    public let endTime: Date

    /// The HTTP status code, if a response was received.
    public let statusCode: Int?

    /// Whether the request completed successfully.
    public let isSuccess: Bool

    /// The error that occurred, if any.
    public let error: NetworkError?

    /// The current retry attempt (0-indexed). First attempt is 0.
    public let attempt: Int

    /// Whether this response was served from cache.
    public let wasFromCache: Bool

    /// Whether this request was deduplicated (shared response with another request).
    public let wasDeduplicatedRequest: Bool

    /// The total duration of the request in seconds.
    public var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    /// Creates a new NetworkRequestMetrics instance.
    public init(
        endpoint: EndpointMetadata,
        startTime: Date,
        endTime: Date,
        statusCode: Int?,
        isSuccess: Bool,
        error: NetworkError?,
        attempt: Int,
        wasFromCache: Bool,
        wasDeduplicatedRequest: Bool = false
    ) {
        self.endpoint = endpoint
        self.startTime = startTime
        self.endTime = endTime
        self.statusCode = statusCode
        self.isSuccess = isSuccess
        self.error = error
        self.attempt = attempt
        self.wasFromCache = wasFromCache
        self.wasDeduplicatedRequest = wasDeduplicatedRequest
    }
}

// MARK: - EndpointMetadata

/// Metadata about an endpoint for metrics tracking.
///
/// Contains identifying information about the endpoint that was called,
/// useful for grouping and analyzing metrics.
public struct EndpointMetadata: Sendable, Hashable {
    /// The path of the endpoint (e.g., "/api/users/123").
    public let path: String

    /// The HTTP method used (e.g., "GET", "POST").
    public let method: String

    /// The base URL of the endpoint.
    public let baseURL: String

    /// Creates a new EndpointMetadata instance.
    public init(path: String, method: String, baseURL: String) {
        self.path = path
        self.method = method
        self.baseURL = baseURL
    }

    /// Creates EndpointMetadata from an Endpoint and NetworkEnvironment.
    internal init<E: Endpoint>(endpoint: E, environment: NetworkEnvironment) {
        self.path = endpoint.path
        self.method = endpoint.method.rawValue
        self.baseURL = environment.baseURL.absoluteString
    }
}
