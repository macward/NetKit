import Foundation

/// Reusable configuration presets for consuming a Server-Sent Events stream.
///
/// SSE connections are long-lived: the client holds a single connection open
/// and receives events as the server produces them. Because of this, the
/// request timeout must be far longer than a regular request — short timeouts
/// would tear down an idle-but-healthy stream. `SSEConfiguration` encapsulates
/// that long timeout, mirroring the preset pattern of `LongPollingConfiguration`.
public struct SSEConfiguration: Sendable, Equatable {
    /// The request timeout for the underlying connection, in seconds.
    ///
    /// This is the interval the connection may stay open waiting for data.
    /// For SSE it is intentionally large because a healthy stream can be idle
    /// between events for long periods.
    public let timeout: TimeInterval

    /// Creates a custom SSE configuration.
    /// - Parameter timeout: The request timeout in seconds. Defaults to 300
    ///   seconds (5 minutes).
    public init(timeout: TimeInterval = 300) {
        self.timeout = timeout
    }
}

// MARK: - Preset Configurations

public extension SSEConfiguration {
    /// Short-lived stream with a 60 second timeout.
    /// Suitable for bursty streams that complete quickly.
    static let short = SSEConfiguration(timeout: 60)

    /// Standard stream with a 5 minute timeout.
    /// Balanced default for most persistent event streams.
    static let standard = SSEConfiguration(timeout: 300)

    /// Long-lived stream with a 1 hour timeout.
    /// Suitable for connections expected to stay open for extended periods.
    static let long = SSEConfiguration(timeout: 3600)
}
