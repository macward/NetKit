# Task 006: Network Metrics and Telemetry

**Completed**: 2026-01-21
**Branch**: task/006-network-metrics
**Status**: Done

## Summary

Added a comprehensive network metrics and telemetry system for tracking request duration, success/failure rates, and integration with analytics systems. The system uses a protocol-based design that allows users to implement custom collectors for any analytics backend (Firebase, Sentry, DataDog, etc.).

## Changes

### Added
- `Sources/NetKit/Metrics/MetricsCollector.swift` - Core metrics types:
  - `MetricsCollector` protocol for collecting network request metrics
  - `NetworkRequestMetrics` struct with timing, status, error, retry, and deduplication info
  - `EndpointMetadata` struct for endpoint identification
- `Sources/NetKit/Metrics/ConsoleMetricsCollector.swift` - Development/debugging collector with:
  - Configurable logging subsystem and category
  - Optional timestamp inclusion
  - Minimum duration filter for identifying slow requests
- `Tests/NetKitTests/MetricsTests.swift` - Comprehensive test suite including:
  - `MockMetricsCollector` actor for testing
  - Tests for `NetworkRequestMetrics` duration calculation
  - Tests for `EndpointMetadata` hashability
  - Tests for `ConsoleMetricsCollector` configuration
  - Real NetworkClient integration tests with URLProtocol mock:
    - Metrics collection on successful requests
    - Metrics collection on failed requests
    - Metrics collection for each retry attempt
    - Graceful handling when no metricsCollector is configured
    - Duration timing validation

### Modified
- `Sources/NetKit/Core/NetworkClient.swift`:
  - Added `metricsCollector: (any MetricsCollector)?` parameter to `init`
  - Implemented metrics collection in `performDeduplicatedRequest`
  - Implemented metrics collection in `performNonDeduplicatedRequest`
  - Implemented metrics collection in `performUpload`
  - Implemented metrics collection in `performDownload`
  - Added private helper methods: `collectMetrics()`, `collectSuccessMetrics()`, `collectFailureMetrics()`
- `Sources/NetKit/Core/InFlightRequestTracker.swift`:
  - Added `InFlightTaskResult` struct to distinguish between task creators and waiters
  - Updated `getOrCreate` to return `InFlightTaskResult` instead of just `Task`

### Documentation
- Added comprehensive documentation with third-party integration examples:
  - Firebase Analytics
  - Sentry Performance Monitoring
  - DataDog RUM
  - Sampling strategy for high-traffic applications

## Files Changed
- `Sources/NetKit/Metrics/MetricsCollector.swift` (created)
- `Sources/NetKit/Metrics/ConsoleMetricsCollector.swift` (created)
- `Sources/NetKit/Core/NetworkClient.swift` (modified)
- `Sources/NetKit/Core/InFlightRequestTracker.swift` (modified)
- `Tests/NetKitTests/MetricsTests.swift` (created)
- `tasks/006-network-metrics.task` (modified)

## API

### Usage

```swift
// Create a custom collector
final class MyMetricsCollector: MetricsCollector {
    func collect(metrics: NetworkRequestMetrics) async {
        print("Request to \(metrics.endpoint.path) took \(metrics.duration)s")
    }
}

// Use with NetworkClient
let client = NetworkClient(
    environment: myEnvironment,
    metricsCollector: MyMetricsCollector()
)
```

### NetworkRequestMetrics Properties
- `endpoint: EndpointMetadata` - Path, method, and base URL
- `startTime: Date` - When the request started
- `endTime: Date` - When the request completed
- `duration: TimeInterval` - Calculated duration in seconds
- `statusCode: Int?` - HTTP status code (nil for downloads or network errors)
- `isSuccess: Bool` - Whether the request succeeded
- `error: NetworkError?` - The error if failed
- `attempt: Int` - Current retry attempt (0-indexed)
- `wasFromCache: Bool` - Whether served from cache
- `wasDeduplicatedRequest: Bool` - Whether this waited for another in-flight request

## Notes
- Metrics collection uses `Date`-based timing (sufficient for most analytics use cases)
- URLSessionTaskMetrics for precise DNS/TLS timing is deferred to a future phase
- Third-party SDKs (Firebase, Sentry, DataDog) are NOT included as dependencies
- Users implement their own collectors using their preferred analytics SDKs
- The `metricsCollector` parameter is optional to maintain backward compatibility
