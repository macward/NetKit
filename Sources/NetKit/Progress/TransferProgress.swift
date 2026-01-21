import Foundation

/// Represents the progress of a file transfer (upload or download).
public struct TransferProgress: Sendable, Equatable {
    /// The number of bytes that have been transferred.
    public let bytesCompleted: Int64

    /// The total expected bytes to transfer. `nil` if unknown.
    public let totalBytes: Int64?

    /// The fraction of the transfer that has completed (0.0 to 1.0).
    /// `nil` if total bytes is unknown.
    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return Double(bytesCompleted) / Double(totalBytes)
    }

    /// Whether the transfer has completed.
    public let isComplete: Bool

    /// Estimated time remaining in seconds. `nil` if cannot be calculated.
    public let estimatedTimeRemaining: TimeInterval?

    /// Transfer speed in bytes per second. `nil` if cannot be calculated.
    public let bytesPerSecond: Double?

    /// Creates a transfer progress instance.
    /// - Parameters:
    ///   - bytesCompleted: The number of bytes transferred so far.
    ///   - totalBytes: The total expected bytes. `nil` if unknown.
    ///   - isComplete: Whether the transfer has completed.
    ///   - estimatedTimeRemaining: Estimated seconds remaining.
    ///   - bytesPerSecond: Current transfer speed.
    public init(
        bytesCompleted: Int64,
        totalBytes: Int64?,
        isComplete: Bool = false,
        estimatedTimeRemaining: TimeInterval? = nil,
        bytesPerSecond: Double? = nil
    ) {
        self.bytesCompleted = bytesCompleted
        self.totalBytes = totalBytes
        self.isComplete = isComplete
        self.estimatedTimeRemaining = estimatedTimeRemaining
        self.bytesPerSecond = bytesPerSecond
    }

    /// A progress instance representing zero progress.
    public static var zero: TransferProgress {
        TransferProgress(bytesCompleted: 0, totalBytes: nil)
    }

    /// Creates a completed progress instance.
    /// - Parameter totalBytes: The total bytes transferred.
    public static func completed(totalBytes: Int64) -> TransferProgress {
        TransferProgress(
            bytesCompleted: totalBytes,
            totalBytes: totalBytes,
            isComplete: true
        )
    }
}

// MARK: - CustomStringConvertible

extension TransferProgress: CustomStringConvertible {
    public var description: String {
        var parts: [String] = []

        if let fraction = fractionCompleted {
            parts.append(String(format: "%.1f%%", fraction * 100))
        }

        parts.append("\(formatBytes(bytesCompleted))")

        if let total = totalBytes {
            parts.append("of \(formatBytes(total))")
        }

        if let speed = bytesPerSecond {
            parts.append("(\(formatBytes(Int64(speed)))/s)")
        }

        if let eta = estimatedTimeRemaining {
            parts.append("ETA: \(formatTime(eta))")
        }

        return parts.joined(separator: " ")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter: ByteCountFormatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else if seconds < 3600 {
            let minutes: Int = Int(seconds) / 60
            let secs: Int = Int(seconds) % 60
            return "\(minutes)m \(secs)s"
        } else {
            let hours: Int = Int(seconds) / 3600
            let minutes: Int = (Int(seconds) % 3600) / 60
            return "\(hours)h \(minutes)m"
        }
    }
}
