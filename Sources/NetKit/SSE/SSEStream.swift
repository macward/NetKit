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

    /// The internal source backing this stream.
    ///
    /// Two modes are supported, sharing the same public surface:
    /// - ``Source/lines`` drives the full bytes → parser → typed decode pipeline
    ///   used by the real transport (task 004/005).
    /// - ``Source/elements`` yields pre-built `E.Event` values directly, used by
    ///   ``MockNetworkClient`` to inject deterministic sequences without a parser
    ///   or any decoding (task 006).
    private let source: Source

    /// Invoked exactly once when iteration finalizes for any reason (terminal
    /// event, error, cancellation, or normal end). Defaults to a no-op; the
    /// network factory passes `{ task.cancel() }` here so abandoning the
    /// `for await` cuts the underlying HTTP request.
    private let onCancel: @Sendable () -> Void

    /// The backing source of an ``SSEStream``.
    enum Source: Sendable {
        /// A factory that produces a fresh line stream per iterator. Lines drive
        /// the parser + discriminator pipeline.
        case lines(@Sendable () -> AsyncThrowingStream<String, any Error>)

        /// A factory that produces a fresh stream of pre-built typed events per
        /// iterator. No parser or decoding is involved.
        case elements(@Sendable () -> AsyncThrowingStream<E.Event, any Error>)
    }

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
        self.source = .lines(lineSource)
        self.onCancel = onCancel
    }

    /// Creates an SSE stream from an injected element source.
    ///
    /// In this "elements mode" the iterator pulls pre-built `E.Event` values
    /// directly — no line parsing and no discriminator decoding. The stream ends
    /// *cleanly* when the source finishes (no
    /// ``SSEError/unexpectedDisconnect(lastEventID:)`` is synthesized; the source
    /// owns terminal-ness), and rethrows if the source finishes with an error.
    ///
    /// This is the seam used by ``MockNetworkClient`` to inject deterministic
    /// event sequences in tests. It performs no networking.
    ///
    /// - Parameters:
    ///   - elements: A factory that returns a fresh event stream per iterator.
    ///   - onCancel: A hook invoked once when iteration finalizes. Defaults to a
    ///     no-op.
    init(
        elements: @escaping @Sendable () -> AsyncThrowingStream<E.Event, any Error>,
        onCancel: @escaping @Sendable () -> Void = {}
    ) {
        self.source = .elements(elements)
        self.onCancel = onCancel
    }

    public func makeAsyncIterator() -> AsyncIterator {
        switch source {
        case .lines(let factory):
            return AsyncIterator(lineSource: factory(), onCancel: onCancel)
        case .elements(let factory):
            return AsyncIterator(elementSource: factory(), onCancel: onCancel)
        }
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
        guard case .lines(let lineSource) = source else {
            // Elements mode has no wire-level events to expose.
            return AsyncThrowingStream { $0.finish() }
        }
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
        /// The active iteration mode. Line mode runs the parser + decode
        /// pipeline; element mode pulls pre-built events directly.
        private enum Mode {
            case lines(
                iterator: AsyncThrowingStream<String, any Error>.AsyncIterator,
                parser: SSELineParser
            )
            case elements(iterator: AsyncThrowingStream<E.Event, any Error>.AsyncIterator)
        }

        private var mode: Mode
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
            self.mode = .lines(iterator: lineSource.makeAsyncIterator(), parser: SSELineParser())
            self.onCancel = onCancel
        }

        init(
            elementSource: AsyncThrowingStream<E.Event, any Error>,
            onCancel: @escaping @Sendable () -> Void
        ) {
            self.mode = .elements(iterator: elementSource.makeAsyncIterator())
            self.onCancel = onCancel
        }

        public mutating func next() async throws -> E.Event? {
            switch mode {
            case .lines:
                return try await nextFromLines()
            case .elements:
                return try await nextFromElements()
            }
        }

        // MARK: - Element mode

        private mutating func nextFromElements() async throws -> E.Event? {
            guard !Task.isCancelled else {
                finalize()
                return nil
            }

            guard case .elements(var iterator) = mode else {
                return nil
            }

            let element: E.Event?
            do {
                element = try await iterator.next()
            } catch {
                // The injected source finished with an error: rethrow as-is.
                finalize()
                throw error
            }
            mode = .elements(iterator: iterator)

            guard let element else {
                // Source finished cleanly: the source owns terminal-ness, so no
                // unexpectedDisconnect is synthesized here.
                finalize()
                return nil
            }

            return element
        }

        // MARK: - Line mode

        private mutating func nextFromLines() async throws -> E.Event? {
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

            guard case .lines(var iterator, var parser) = mode else {
                return nil
            }

            while true {
                guard !Task.isCancelled else {
                    mode = .lines(iterator: iterator, parser: parser)
                    finalize()
                    return nil
                }

                let line: String?
                do {
                    line = try await iterator.next()
                } catch {
                    // The transport was cut mid-stream.
                    mode = .lines(iterator: iterator, parser: parser)
                    finalize()
                    throw SSEError.unexpectedDisconnect(lastEventID: parser.lastEventID)
                }

                guard let line else {
                    // Source finished. Without a terminal, this is unexpected.
                    mode = .lines(iterator: iterator, parser: parser)
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
                    mode = .lines(iterator: iterator, parser: parser)
                    finalize()
                    throw error
                } catch {
                    mode = .lines(iterator: iterator, parser: parser)
                    finalize()
                    throw SSEError.decodingFailed(error)
                }

                if event.isTerminal {
                    terminalDelivered = true
                }

                mode = .lines(iterator: iterator, parser: parser)
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
