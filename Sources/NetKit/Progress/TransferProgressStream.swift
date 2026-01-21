import Foundation

/// An AsyncSequence that yields transfer progress updates.
///
/// Use this with `for await` to track upload or download progress:
/// ```swift
/// let (progress, responseTask) = client.upload(file: fileURL, to: endpoint)
///
/// for await update in progress {
///     print("Progress: \(update.fractionCompleted ?? 0)")
/// }
///
/// let response = try await responseTask.value
/// ```
public struct TransferProgressStream: AsyncSequence, Sendable {
    public typealias Element = TransferProgress

    private let stream: AsyncStream<TransferProgress>

    /// Creates a transfer progress stream from an AsyncStream.
    /// - Parameter stream: The underlying AsyncStream of progress updates.
    internal init(stream: AsyncStream<TransferProgress>) {
        self.stream = stream
    }

    /// Creates a transfer progress stream with a continuation for yielding progress.
    /// - Parameter build: A closure that receives the continuation to yield progress updates.
    internal init(
        _ build: (AsyncStream<TransferProgress>.Continuation) -> Void
    ) {
        self.stream = AsyncStream(TransferProgress.self, build)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: stream.makeAsyncIterator())
    }

    /// The async iterator for consuming progress updates.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private var iterator: AsyncStream<TransferProgress>.AsyncIterator

        init(iterator: AsyncStream<TransferProgress>.AsyncIterator) {
            self.iterator = iterator
        }

        public mutating func next() async -> TransferProgress? {
            await iterator.next()
        }
    }
}

// MARK: - Static Factories

extension TransferProgressStream {
    /// Creates an empty progress stream that completes immediately.
    internal static var empty: TransferProgressStream {
        TransferProgressStream { continuation in
            continuation.finish()
        }
    }

    /// Creates a progress stream that yields a single completed progress.
    /// - Parameter totalBytes: The total bytes transferred.
    internal static func completed(totalBytes: Int64) -> TransferProgressStream {
        TransferProgressStream { continuation in
            continuation.yield(TransferProgress.completed(totalBytes: totalBytes))
            continuation.finish()
        }
    }

    /// Creates a progress stream from a sequence of progress updates.
    /// - Parameter sequence: The progress updates to yield.
    internal static func from(_ sequence: [TransferProgress]) -> TransferProgressStream {
        TransferProgressStream { continuation in
            for progress in sequence {
                continuation.yield(progress)
            }
            continuation.finish()
        }
    }
}

// MARK: - Convenience Extensions

extension TransferProgressStream {
    /// Collects all progress updates into an array.
    /// Useful for testing.
    internal func collect() async -> [TransferProgress] {
        var results: [TransferProgress] = []
        for await progress in self {
            results.append(progress)
        }
        return results
    }

    /// Returns only the final progress update.
    public func last() async -> TransferProgress? {
        var lastProgress: TransferProgress?
        for await progress in self {
            lastProgress = progress
        }
        return lastProgress
    }
}
