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
/// ## Single-pass contract
///
/// `SSEStream` is **single-pass**. Each call to `makeAsyncIterator()` — including
/// an implicit call via `for try await` — and each access to ``rawEvents``
/// invokes the underlying line-source factory, which opens a fresh HTTP
/// connection to the server. Iterating the same `SSEStream` value twice, or
/// consuming ``rawEvents`` while a typed `for try await` loop is active, opens
/// two simultaneous connections and makes two separate server calls (two billed
/// LLM requests, duplicate side-effects). Design your callers to consume a
/// stream exactly once.
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
    ///   used by the real transport.
    /// - ``Source/elements`` yields pre-built `E.Event` values directly, used by
    ///   ``MockNetworkClient`` to inject deterministic sequences without a parser
    ///   or any decoding.
    private let source: Source

    /// Invoked **at most once** when iteration ends for any reason: terminal
    /// event, error, task cancellation, or the consumer breaking early out of the
    /// `for try await` loop. The hook fires either from `finalize()` inside
    /// `next()` or, for early `break`, when the iterator is dropped (via the
    /// iterator's `OnDeinit` helper). Defaults to a no-op.
    private let onCancel: CancelOnce

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
    /// This is the internal seam used by the client-facing factory, the dialect
    /// presets, and the test suite. It performs no networking.
    ///
    /// - Parameters:
    ///   - lineSource: A factory that returns a fresh line stream per iterator.
    ///   - onCancel: A hook invoked at most once when iteration ends for any
    ///     reason. Defaults to a no-op.
    init(
        lineSource: @escaping @Sendable () -> AsyncThrowingStream<String, any Error>,
        onCancel: @escaping @Sendable () -> Void = {}
    ) {
        self.source = .lines(lineSource)
        self.onCancel = CancelOnce(onCancel)
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
    /// > Important: Elements mode bypasses the SSE line parser, the
    /// > ``SSEDecodableEvent`` discriminator, and the `isTerminal` /
    /// > ``SSEError/unexpectedDisconnect(lastEventID:)`` logic. Tests that use
    /// > this mode verify event-consumption behavior but do NOT exercise the
    /// > real parsing/decoding pipeline or the terminal/disconnect semantics.
    /// > Use ``SSEStream/init(lineSource:onCancel:)`` to exercise the full
    /// > pipeline in tests.
    ///
    /// - Parameters:
    ///   - elements: A factory that returns a fresh event stream per iterator.
    ///   - onCancel: A hook invoked at most once when iteration ends. Defaults to
    ///     a no-op.
    init(
        elements: @escaping @Sendable () -> AsyncThrowingStream<E.Event, any Error>,
        onCancel: @escaping @Sendable () -> Void = {}
    ) {
        self.source = .elements(elements)
        self.onCancel = CancelOnce(onCancel)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        switch source {
        case .lines(let factory):
            return AsyncIterator(lineSource: factory(), onCancel: onCancel)
        case .elements(let factory):
            return AsyncIterator(elementSource: factory(), onCancel: onCancel)
        }
    }

    /// A view over the transport that yields the raw ``SSEEvent`` values
    /// without typed decoding.
    ///
    /// This exposes the lower-level transport for callers that want to inspect
    /// the wire events directly. It assembles events through the same
    /// ``SSELineParser`` but does not invoke the discriminator, apply terminal
    /// semantics, or raise ``SSEError/unexpectedDisconnect(lastEventID:)`` on a
    /// bare end. Transport errors are still propagated.
    ///
    /// > Important: Accessing `rawEvents` calls the line-source factory and
    /// > opens a **new, independent connection**. Consuming `rawEvents` while a
    /// > typed `for try await` loop over the same `SSEStream` is active opens
    /// > two simultaneous connections. Use one or the other, not both.
    public var rawEvents: AsyncThrowingStream<SSEEvent, any Error> {
        guard case .lines(let lineSource) = source else {
            // Elements mode has no wire-level events to expose.
            return AsyncThrowingStream { $0.finish() }
        }
        let cancel: CancelOnce = onCancel
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Defer the factory call to inside the Task so the connection is
                // not opened until iteration begins (not on property access).
                let source: AsyncThrowingStream<String, any Error> = lineSource()
                var parser = SSELineParser()
                do {
                    // withTaskCancellationHandler ensures that when this Task is
                    // cancelled (via onTermination → task.cancel()), the consuming
                    // for-await is unblocked immediately — without waiting for the
                    // URLSession chain (invalidateAndCancel → stopLoading →
                    // URLError.cancelled) to propagate. Without this, rawTask hangs
                    // when rawTask.cancel() races with a long-lived open connection.
                    try await withTaskCancellationHandler {
                        for try await line in source {
                            try Task.checkCancellation()
                            if let event: SSEEvent = parser.consume(line: line) {
                                continuation.yield(event)
                            }
                        }
                        if let event: SSEEvent = parser.flush() {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } onCancel: {
                        // Fired synchronously when task.cancel() is called.
                        // Idempotent: subsequent finish() calls are no-ops.
                        continuation.finish(throwing: CancellationError())
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                cancel.fire()
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
        private let onCancel: CancelOnce
        /// Fires the cancel hook when the iterator struct is dropped without
        /// `finalize()` being called (e.g. the consumer exits via `break`). The
        /// class is held exclusively by this iterator, so its `deinit` fires as
        /// soon as the iterator value is destroyed.
        private let cancelOnDeinit: OnDeinit

        /// Whether a terminal event has already been delivered. Once `true`, a
        /// subsequent source end is a clean close rather than a disconnect.
        private var terminalDelivered: Bool = false

        /// Whether finalization has already run, so the cancellation hook is
        /// invoked at most once.
        private var finalized: Bool = false

        /// Set to `true` after the line source ends cleanly and any final
        /// flushed event has been returned. The next pull throws
        /// ``SSEError/unexpectedDisconnect(lastEventID:)``.
        private var sourceEnded: Bool = false

        /// The `lastEventID` captured when `sourceEnded` becomes `true`, so it
        /// is available on the subsequent pull that throws the disconnect error.
        private var lastKnownEventID: String?

        fileprivate init(
            lineSource: AsyncThrowingStream<String, any Error>,
            onCancel: CancelOnce
        ) {
            self.mode = .lines(iterator: lineSource.makeAsyncIterator(), parser: SSELineParser())
            self.onCancel = onCancel
            self.cancelOnDeinit = OnDeinit { onCancel.fire() }
        }

        fileprivate init(
            elementSource: AsyncThrowingStream<E.Event, any Error>,
            onCancel: CancelOnce
        ) {
            self.mode = .elements(iterator: elementSource.makeAsyncIterator())
            self.onCancel = onCancel
            self.cancelOnDeinit = OnDeinit { onCancel.fire() }
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

            // A terminal event was already delivered; this is a clean end.
            guard !terminalDelivered else {
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

            if element.isTerminal {
                terminalDelivered = true
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

            // The final flushed event was already returned on the previous pull.
            if sourceEnded {
                finalize()
                throw SSEError.unexpectedDisconnect(lastEventID: lastKnownEventID)
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
                } catch let error as NetworkError {
                    // HTTP-level error (e.g. 4xx/5xx status, connection refused) —
                    // propagate as-is so callers receive the structured error.
                    mode = .lines(iterator: iterator, parser: parser)
                    finalize()
                    throw error
                } catch {
                    mode = .lines(iterator: iterator, parser: parser)
                    finalize()
                    // A cancelled task causes URLSession to throw URLError.cancelled.
                    // Treat this as cooperative cancellation (return nil) rather than
                    // wrapping it in unexpectedDisconnect, which would mislead callers
                    // into treating cancellation as a reconnectable network failure.
                    if Task.isCancelled {
                        return nil
                    }
                    throw SSEError.unexpectedDisconnect(lastEventID: parser.lastEventID)
                }

                guard let line else {
                    // Flush any event buffered without a closing blank line (e.g. a
                    // server that closes the connection without a final \n\n). If
                    // there is a partial event, return it now and defer the
                    // unexpectedDisconnect error to the next pull via sourceEnded.
                    if let flushed: SSEEvent = parser.flush() {
                        let event: E.Event = try decodeOrFinalize(flushed, parser: &parser, iterator: &iterator)
                        sourceEnded = true
                        lastKnownEventID = parser.lastEventID
                        if event.isTerminal { terminalDelivered = true }
                        mode = .lines(iterator: iterator, parser: parser)
                        return event
                    }
                    mode = .lines(iterator: iterator, parser: parser)
                    finalize()
                    // A cancelled task causes the line-source producer to finish
                    // cleanly (nil), not throw. Treat this as cooperative
                    // cancellation rather than a network disconnect.
                    if Task.isCancelled {
                        return nil
                    }
                    throw SSEError.unexpectedDisconnect(lastEventID: parser.lastEventID)
                }

                // Feed the parser; blank/comment lines yield nil and we loop.
                guard let rawEvent: SSEEvent = parser.consume(line: line) else {
                    continue
                }

                let event: E.Event = try decodeOrFinalize(rawEvent, parser: &parser, iterator: &iterator)
                if event.isTerminal { terminalDelivered = true }
                mode = .lines(iterator: iterator, parser: parser)
                return event
            }
        }

        /// Decodes a raw ``SSEEvent`` into a typed `E.Event`.
        ///
        /// On failure, saves the current parser/iterator state, finalizes the
        /// iterator, and rethrows — either the original ``SSEError`` or a wrapped
        /// ``SSEError/decodingFailed(_:)`` for non-SSE errors.
        private mutating func decodeOrFinalize(
            _ raw: SSEEvent,
            parser: inout SSELineParser,
            iterator: inout AsyncThrowingStream<String, any Error>.AsyncIterator
        ) throws -> E.Event {
            do {
                return try E.Event(eventName: raw.event, data: raw.data)
            } catch let error as SSEError {
                mode = .lines(iterator: iterator, parser: parser)
                finalize()
                throw error
            } catch {
                mode = .lines(iterator: iterator, parser: parser)
                finalize()
                throw SSEError.decodingFailed(error)
            }
        }

        /// Runs the cancellation hook exactly once.
        private mutating func finalize() {
            guard !finalized else {
                return
            }
            finalized = true
            onCancel.fire()
        }
    }
}

// MARK: - CancelOnce / OnDeinit

/// Runs a `@Sendable` block at most once, regardless of how many callers invoke `fire()`.
///
/// Shared between `SSEStream.AsyncIterator` and `SSEStream.rawEvents` so that a
/// custom `onCancel` hook never fires more than once even if both paths are active.
private final class CancelOnce: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var fired: Bool = false
    private let block: @Sendable () -> Void

    init(_ block: @escaping @Sendable () -> Void) {
        self.block = block
    }

    func fire() {
        lock.lock()
        let shouldFire: Bool = !fired
        if shouldFire { fired = true }
        lock.unlock()
        if shouldFire { block() }
    }
}

/// Fires a `@Sendable` block when this object is deallocated.
///
/// Stored inside `SSEStream.AsyncIterator` (a struct) so that the block runs
/// when the iterator is dropped — e.g. when the consumer exits a `for try await`
/// loop via `break` without going through `finalize()`.
private final class OnDeinit: @unchecked Sendable {
    private let block: @Sendable () -> Void

    init(_ block: @escaping @Sendable () -> Void) {
        self.block = block
    }

    deinit {
        block()
    }
}
