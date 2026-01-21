import Foundation
import os

// MARK: - Transfer Metrics

/// Tracks transfer speed and timing for progress calculations.
internal struct TransferMetrics: Sendable {
    let startTime: Date
    var lastUpdateTime: Date
    var recentBytesPerSecond: [Double]

    private static let maxSamples: Int = 5

    init() {
        let now: Date = Date()
        self.startTime = now
        self.lastUpdateTime = now
        self.recentBytesPerSecond = []
    }

    mutating func recordTransfer(bytes: Int64, at time: Date = Date()) {
        let elapsed: TimeInterval = time.timeIntervalSince(lastUpdateTime)
        guard elapsed > 0 else { return }

        let speed: Double = Double(bytes) / elapsed
        recentBytesPerSecond.append(speed)

        if recentBytesPerSecond.count > Self.maxSamples {
            recentBytesPerSecond.removeFirst()
        }

        lastUpdateTime = time
    }

    var averageSpeed: Double? {
        guard !recentBytesPerSecond.isEmpty else { return nil }
        return recentBytesPerSecond.reduce(0, +) / Double(recentBytesPerSecond.count)
    }

    func estimatedTimeRemaining(bytesRemaining: Int64) -> TimeInterval? {
        guard let speed = averageSpeed, speed > 0 else { return nil }
        return Double(bytesRemaining) / speed
    }
}

// MARK: - Progress State

/// Thread-safe state container for progress tracking.
internal struct ProgressState: Sendable {
    var bytesCompleted: Int64 = 0
    var totalBytes: Int64?
    var metrics: TransferMetrics = TransferMetrics()
    var isFinished: Bool = false
}

// MARK: - Upload Progress Delegate

/// A URLSession delegate that tracks upload progress and reports it via AsyncStream.
///
/// This delegate uses `OSAllocatedUnfairLock` for thread-safe access to state
/// and coordinates with an `AsyncStream.Continuation` to yield progress updates.
internal final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<ProgressState>
    private let continuation: AsyncStream<TransferProgress>.Continuation

    /// Creates an upload progress delegate.
    /// - Parameter continuation: The continuation to yield progress updates to.
    init(continuation: AsyncStream<TransferProgress>.Continuation) {
        self.state = OSAllocatedUnfairLock(initialState: ProgressState())
        self.continuation = continuation
        super.init()

        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.isFinished = true }
        }
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let progress: TransferProgress = state.withLock { state -> TransferProgress in
            guard !state.isFinished else {
                return TransferProgress(
                    bytesCompleted: state.bytesCompleted,
                    totalBytes: state.totalBytes,
                    isComplete: true
                )
            }

            state.metrics.recordTransfer(bytes: bytesSent)
            state.bytesCompleted = totalBytesSent

            let expectedTotal: Int64? = totalBytesExpectedToSend > 0
                ? totalBytesExpectedToSend
                : nil
            state.totalBytes = expectedTotal

            let bytesRemaining: Int64 = (expectedTotal ?? 0) - totalBytesSent
            let eta: TimeInterval? = bytesRemaining > 0
                ? state.metrics.estimatedTimeRemaining(bytesRemaining: bytesRemaining)
                : nil

            return TransferProgress(
                bytesCompleted: totalBytesSent,
                totalBytes: expectedTotal,
                isComplete: false,
                estimatedTimeRemaining: eta,
                bytesPerSecond: state.metrics.averageSpeed
            )
        }

        continuation.yield(progress)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let finalProgress: TransferProgress = state.withLock { state -> TransferProgress in
            state.isFinished = true
            return TransferProgress(
                bytesCompleted: state.bytesCompleted,
                totalBytes: state.totalBytes,
                isComplete: error == nil
            )
        }

        if error == nil {
            continuation.yield(finalProgress)
        }
        continuation.finish()
    }

    /// Resets the delegate state for retry attempts.
    func reset() {
        state.withLock { state in
            state.bytesCompleted = 0
            state.totalBytes = nil
            state.metrics = TransferMetrics()
            state.isFinished = false
        }
    }
}

// MARK: - Download Progress Delegate

/// A URLSession delegate that tracks download progress and reports it via AsyncStream.
internal final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<ProgressState>
    private let continuation: AsyncStream<TransferProgress>.Continuation
    private let destination: URL
    private let completionHandler: @Sendable (Result<URL, Error>) -> Void
    private let sessionBox: OSAllocatedUnfairLock<URLSession?>

    /// Creates a download progress delegate.
    /// - Parameters:
    ///   - destination: The URL where the downloaded file should be moved.
    ///   - continuation: The continuation to yield progress updates to.
    ///   - completionHandler: Called when the download completes or fails.
    init(
        destination: URL,
        continuation: AsyncStream<TransferProgress>.Continuation,
        completionHandler: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        self.state = OSAllocatedUnfairLock(initialState: ProgressState())
        self.continuation = continuation
        self.destination = destination
        self.completionHandler = completionHandler
        self.sessionBox = OSAllocatedUnfairLock(initialState: nil)
        super.init()

        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.isFinished = true }
        }
    }

    /// Sets the URLSession reference for cleanup on completion.
    /// Must be called after creating the session.
    func setSession(_ session: URLSession) {
        sessionBox.withLock { $0 = session }
    }

    private func invalidateSession() {
        sessionBox.withLock { session in
            session?.finishTasksAndInvalidate()
            session = nil
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress: TransferProgress = state.withLock { state -> TransferProgress in
            guard !state.isFinished else {
                return TransferProgress(
                    bytesCompleted: state.bytesCompleted,
                    totalBytes: state.totalBytes,
                    isComplete: true
                )
            }

            state.metrics.recordTransfer(bytes: bytesWritten)
            state.bytesCompleted = totalBytesWritten

            let expectedTotal: Int64? = totalBytesExpectedToWrite > 0
                ? totalBytesExpectedToWrite
                : nil
            state.totalBytes = expectedTotal

            let bytesRemaining: Int64 = (expectedTotal ?? 0) - totalBytesWritten
            let eta: TimeInterval? = bytesRemaining > 0
                ? state.metrics.estimatedTimeRemaining(bytesRemaining: bytesRemaining)
                : nil

            return TransferProgress(
                bytesCompleted: totalBytesWritten,
                totalBytes: expectedTotal,
                isComplete: false,
                estimatedTimeRemaining: eta,
                bytesPerSecond: state.metrics.averageSpeed
            )
        }

        continuation.yield(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let fileManager: FileManager = FileManager.default

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            let parentDirectory: URL = destination.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDirectory.path) {
                try fileManager.createDirectory(
                    at: parentDirectory,
                    withIntermediateDirectories: true
                )
            }

            try fileManager.moveItem(at: location, to: destination)

            let finalProgress: TransferProgress = state.withLock { state -> TransferProgress in
                state.isFinished = true
                return TransferProgress(
                    bytesCompleted: state.bytesCompleted,
                    totalBytes: state.totalBytes,
                    isComplete: true
                )
            }

            continuation.yield(finalProgress)
            continuation.finish()
            invalidateSession()
            completionHandler(.success(destination))

        } catch {
            state.withLock { $0.isFinished = true }
            continuation.finish()
            invalidateSession()
            completionHandler(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }

        state.withLock { $0.isFinished = true }
        continuation.finish()
        invalidateSession()
        completionHandler(.failure(error))
    }

    /// Resets the delegate state for retry attempts.
    func reset() {
        state.withLock { state in
            state.bytesCompleted = 0
            state.totalBytes = nil
            state.metrics = TransferMetrics()
            state.isFinished = false
        }
    }
}
