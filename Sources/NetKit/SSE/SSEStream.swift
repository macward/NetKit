import Foundation

/// An `AsyncSequence` that yields typed events decoded from a Server-Sent Events
/// (SSE) stream.
///
/// `SSEStream` orchestrates the full pipeline of a live SSE connection:
/// transport bytes are split into lines, the lines are fed through an
/// ``SSELineParser`` state machine to assemble raw ``SSEEvent`` values, and each
/// raw event is handed to the endpoint's ``SSEDecodableEvent`` discriminator to
/// produce a typed `E.Event`. Consume it with `for try await`:
/// ```swift
/// for try await event in client.stream(ChatStreamEndpoint()) {
///     handle(event)
/// }
/// ```
///
/// The stream ends when:
/// - the discriminator produces a terminal event (`isTerminal == true`) — that
///   event is delivered as the final element and the next pull returns `nil`,
/// - the consuming task is cancelled, or
/// - the transport closes cleanly *after* a terminal event was delivered.
///
/// It throws:
/// - ``SSEError/decodingFailed(description:)`` when the discriminator fails to
///   decode a payload, and
/// - ``SSEError/unexpectedDisconnect(lastEventID:)`` when the transport ends or
///   errors *before* a terminal event was delivered.
///
/// ## Testability seam
///
/// `SSEStream` does not open any network connection itself. It is constructed
/// from an injected line-source factory and an optional cancellation hook, which
/// keeps the underlying transport type fully erased from the public generic
/// signature. The real network adapter (`URLSession.AsyncBytes.lines`) is wired
/// in by the client-facing factory; tests feed lines directly via an
/// `AsyncThrowingStream<String, any Error>`.
public struct SSEStream<E: SSEEndpoint>: AsyncSequence, Sendable {
    public typealias Element = E.Event

    /// Produces a fresh line stream for each iterator. Each call must yield the
    /// SSE payload split into lines (without trailing newlines), finishing when
    /// the transport closes and finishing-with-error when it is cut mid-stream.
    private let lineSource: @Sendable () -> AsyncThrowingStream<String, any Error>

    /// Invoked exactly once when iteration finalizes for any reason (terminal
    /// event, error, cancellation, or normal end). Defaults to a no-op; the
    /// network factory passes `{ task.cancel() }` here so abandoning the
    /// `for await` cuts the underlying HTTP request.
    private let onCancel: @Sendable () -> Void

    /// Creates an SSE stream from an injected line source.
    ///
    /// This is the internal seam used by the client-facing factory (task 005),
    /// the dialect presets (task 006+), and the test suite. It performs no
    /// networking.
    ///
    /// - Parameters:
    ///   - lineSource: A factory that returns a fresh line stream per iterator.
    ///   - onCancel: A hook invoked once when iteration finalizes. Defaults to a
    ///     no-op.
    init(
        lineSource: @escaping @Sendable () -> AsyncThrowingStream<String, any Error>,
        onCancel: @escaping @Sendable () -> Void = {}
    ) {
        self.lineSource = lineSource
        self.onCancel = onCancel
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(lineSource: lineSource(), onCancel: onCancel)
    }

    /// A view over the same transport that yields the raw ``SSEEvent`` values
    /// without typed decoding.
    ///
    /// This exposes the lower-level transport for callers that want to inspect
    /// the wire events directly. It assembles events through the same
    /// ``SSELineParser`` but does not invoke the discriminator, apply terminal
    /// semantics, or raise ``SSEError/unexpectedDisconnect(lastEventID:)`` on a
    /// bare end. Transport errors are still propagated.
    public var rawEvents: AsyncThrowingStream<SSEEvent, any Error> {
        let source: AsyncThrowingStream<String, any Error> = lineSource()
        let cancel: @Sendable () -> Void = onCancel
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSELineParser()
                do {
                    for try await line in source {
                        try Task.checkCancellation()
                        if let event: SSEEvent = parser.consume(line: line) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                cancel()
            }
        }
    }

    /// The async iterator that drives the bytes → parser → typed decode pipeline.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private var iterator: AsyncThrowingStream<String, any Error>.AsyncIterator
        private var parser: SSELineParser
        private let onCancel: @Sendable () -> Void

        /// Whether a terminal event has already been delivered. Once `true`, a
        /// subsequent source end is a clean close rather than a disconnect.
        private var terminalDelivered: Bool = false

        /// Whether finalization has already run, so the cancellation hook is
        /// invoked at most once.
        private var finalized: Bool = false

        init(
            lineSource: AsyncThrowingStream<String, any Error>,
            onCancel: @escaping @Sendable () -> Void
        ) {
            self.iterator = lineSource.makeAsyncIterator()
            self.parser = SSELineParser()
            self.onCancel = onCancel
        }

        public mutating func next() async throws -> E.Event? {
            // Honor cancellation before doing any work.
            guard !Task.isCancelled else {
                finalize()
                return nil
            }

            // A terminal event was already delivered; this is a clean end.
            guard !terminalDelivered else {
                finalize()
                return nil
            }

            while true {
                guard !Task.isCancelled else {
                    finalize()
                    return nil
                }

                let line: String?
                do {
                    line = try await iterator.next()
                } catch {
                    // The transport was cut mid-stream.
                    finalize()
                    throw SSEError.unexpectedDisconnect(lastEventID: parser.lastEventID)
                }

                guard let line else {
                    // Source finished. Without a terminal, this is unexpected.
                    finalize()
                    throw SSEError.unexpectedDisconnect(lastEventID: parser.lastEventID)
                }

                // Feed the parser; blank/comment lines yield nil and we loop.
                guard let rawEvent: SSEEvent = parser.consume(line: line) else {
                    continue
                }

                let event: E.Event
                do {
                    event = try E.Event(eventName: rawEvent.event, data: rawEvent.data)
                } catch let error as SSEError {
                    finalize()
                    throw error
                } catch {
                    finalize()
                    throw SSEError.decodingFailed(error)
                }

                if event.isTerminal {
                    terminalDelivered = true
                }

                return event
            }
        }

        /// Runs the cancellation hook exactly once.
        private mutating func finalize() {
            guard !finalized else {
                return
            }
            finalized = true
            onCancel()
        }
    }
}
