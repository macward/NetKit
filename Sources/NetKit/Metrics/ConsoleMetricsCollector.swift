import Foundation
import os

/// A metrics collector that logs metrics to the console.
///
/// Useful for development and debugging. In production, consider using
/// a custom collector that sends metrics to your analytics backend.
///
/// ## Example
///
/// ```swift
/// let client = NetworkClient(
///     environment: myEnvironment,
///     metricsCollector: ConsoleMetricsCollector()
/// )
/// ```
///
/// - Note: Uses `@unchecked Sendable` because `Logger` is internally thread-safe
///   but not marked as `Sendable` in current Swift versions.
///   See: https://developer.apple.com/forums/thread/747816
public final class ConsoleMetricsCollector: MetricsCollector, @unchecked Sendable {
    private let logger: Logger
    // nonisolated(unsafe): ISO8601DateFormatter is thread-safe for reading after configuration.
    // The formatter is configured once at initialization and only read thereafter.
    private nonisolated(unsafe) static let timestampFormatter: ISO8601DateFormatter = {
        let formatter: ISO8601DateFormatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let includeTimestamps: Bool
    private let minimumDurationToLog: TimeInterval?

    /// Creates a new ConsoleMetricsCollector.
    ///
    /// - Parameters:
    ///   - subsystem: The subsystem for the logger. Defaults to "NetKit".
    ///   - category: The category for the logger. Defaults to "Metrics".
    ///   - includeTimestamps: Whether to include timestamps in log output. Defaults to true.
    ///   - minimumDurationToLog: Only log requests that take longer than this duration.
    ///                           Useful for identifying slow requests. Defaults to nil (log all).
    public init(
        subsystem: String = "NetKit",
        category: String = "Metrics",
        includeTimestamps: Bool = true,
        minimumDurationToLog: TimeInterval? = nil
    ) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.includeTimestamps = includeTimestamps
        self.minimumDurationToLog = minimumDurationToLog
    }

    public func collect(metrics: NetworkRequestMetrics) async {
        if let minimum = minimumDurationToLog, metrics.duration < minimum {
            return
        }

        let statusEmoji: String = metrics.isSuccess ? "✅" : "❌"
        let cacheInfo: String = metrics.wasFromCache ? " [CACHE]" : ""
        let dedupInfo: String = metrics.wasDeduplicatedRequest ? " [DEDUP]" : ""
        let retryInfo: String = metrics.attempt > 0 ? " [RETRY #\(metrics.attempt)]" : ""
        let statusCode: String = metrics.statusCode.map { "HTTP \($0)" } ?? "No response"
        let durationMs: String = String(format: "%.2fms", metrics.duration * 1000)

        var message: String = """
            \(statusEmoji) \(metrics.endpoint.method) \(metrics.endpoint.path)\
            \(cacheInfo)\(dedupInfo)\(retryInfo)
            """

        if includeTimestamps {
            message += "\n   Started: \(Self.timestampFormatter.string(from: metrics.startTime))"
        }

        message += "\n   Duration: \(durationMs)"
        message += "\n   Status: \(statusCode)"

        if let error = metrics.error {
            message += "\n   Error: \(error.localizedDescription)"
        }

        if metrics.isSuccess {
            logger.info("\(message)")
        } else {
            logger.warning("\(message)")
        }
    }
}
