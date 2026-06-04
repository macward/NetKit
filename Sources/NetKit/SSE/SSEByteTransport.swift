import Foundation

// MARK: - Public Streaming Surface

extension NetworkClient {
    /// Opens a Server-Sent Events stream for the given endpoint.
    ///
    /// Returns an ``SSEStream`` you can consume with `for try await`. The stream
    /// opens a single long-lived connection, forces the `Accept:
    /// text/event-stream` header, runs the request interceptor chain (so an
    /// ``AuthInterceptor`` injects the `Authorization` header), and splits the
    /// response bytes into typed events.
    ///
    /// This path deliberately bypasses caching, deduplication, retry, and the
    /// regular request execution pipeline: a stream is a unique, persistent
    /// connection and must never be coalesced or served from cache.
    ///
    /// - Parameter endpoint: The SSE endpoint to stream.
    /// - Returns: An ``SSEStream`` of typed events.
    public func stream<E: SSEEndpoint>(_ endpoint: E) -> SSEStream<E> {
        stream(endpoint, configuration: .long)
    }

    /// Opens a Server-Sent Events stream for the given endpoint with a custom
    /// configuration.
    ///
    /// - Parameters:
    ///   - endpoint: The SSE endpoint to stream.
    ///   - configuration: The stream configuration (timeout). Defaults to
    ///     ``SSEConfiguration/long`` via the single-argument overload.
    /// - Returns: An ``SSEStream`` of typed events.
    public func stream<E: SSEEndpoint>(
        _ endpoint: E,
        configuration: SSEConfiguration
    ) -> SSEStream<E> {
        let timeout: TimeInterval = configuration.timeout
        let dependencies: SSEStreamDependencies = sseDependencies

        // Derive config from the shared session so test URLProtocols are inherited;
        // raise timeouts for a persistent connection. `session.configuration` returns
        // a mutable copy — safe to mutate without affecting the original session.
        let streamingConfiguration: URLSessionConfiguration = dependencies.session.configuration
        streamingConfiguration.timeoutIntervalForRequest = timeout
        streamingConfiguration.timeoutIntervalForResource = timeout

        let environment: NetworkEnvironment = dependencies.environment
        let encoder: JSONEncoder = dependencies.encoder
        let baseSession: URLSession = dependencies.session

        // The taskBox is created inside the factory so that each invocation
        // (makeAsyncIterator or rawEvents) owns its own cancel handle. A shared
        // taskBox would be overwritten on every set() call, causing one iterator's
        // cancel() to kill a different iterator's in-flight task.
        let lineSource: @Sendable () -> AsyncThrowingStream<String, any Error> = { [self] in
            let taskBox: SSEStreamTaskBox = SSEStreamTaskBox()
            return SSEByteTransport.makeLineSource(
                configuration: streamingConfiguration,
                baseSession: baseSession,
                taskBox: taskBox,
                makeRequest: {
                    var request: URLRequest = try URLRequest(
                        endpoint: endpoint,
                        environment: environment,
                        additionalHeaders: [:],
                        timeoutOverride: timeout,
                        encoder: encoder
                    )
                    // Force the SSE Accept header, overriding any default.
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    try await self.applyRequestInterceptors(to: &request)
                    return request
                },
                onResponse: { httpResponse, request in
                    let snapshot: RequestSnapshot = RequestSnapshot(request: request)
                    // Run response interceptors with empty data — SSE has no buffered
                    // body at connection-open time, but interceptors should still observe
                    // headers (e.g. for logging or 401 detection).
                    var data: Data = Data()
                    try await self.applyResponseInterceptors(to: &data, response: httpResponse)
                    try self.validateResponse(httpResponse, request: snapshot, data: data)
                }
            )
        }

        return SSEStream(lineSource: lineSource)
    }
}

/// The `NetworkClient` dependencies needed to build an SSE stream, captured into
/// a `Sendable` snapshot so the streaming surface can live outside the client
/// without exposing its `private` stored properties broadly.
internal struct SSEStreamDependencies: Sendable {
    let environment: NetworkEnvironment
    let encoder: JSONEncoder
    /// The full session — not just its configuration — so that a delegate
    /// (e.g. `CertificatePinningDelegate`) is inherited by the streaming session.
    let session: URLSession
}

/// A `Sendable` holder for the in-flight streaming data task, so the transport
/// can be cancelled from the stream's termination/cancellation hooks. The task
/// is set after `bytes(for:)` returns.
final class SSEStreamTaskBox: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var task: URLSessionDataTask?

    func set(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let captured: URLSessionDataTask? = task
        lock.unlock()
        captured?.cancel()
    }
}

/// The byte-level adapter that opens a streaming connection and feeds SSE lines
/// into an `AsyncThrowingStream`.
///
/// This is the real network seam behind `NetworkClient.stream(_:)`. It is kept
/// separate from the client so the client extension only needs to build the
/// request (with access to its private dependencies) and hand it off here.
enum SSEByteTransport {
    /// Builds a fresh line-source stream for one iterator.
    ///
    /// The returned stream opens `URLSession.bytes(for:)` on a dedicated session
    /// derived from `configuration`, splits the response bytes into lines
    /// (preserving the blank lines that delimit SSE events), and yields them one
    /// per element. It finishes cleanly when the transport closes and finishes
    /// with the thrown error when it is cut mid-stream. The session is
    /// invalidated and the underlying task cancelled when iteration terminates.
    ///
    /// - Parameters:
    ///   - configuration: The session configuration (already timeout-adjusted
    ///     and inheriting any test `protocolClasses`).
    ///   - baseSession: The client's underlying session. Its delegate (e.g. a
    ///     `CertificatePinningDelegate`) is reused so that security policies apply
    ///     to streaming connections, not just regular requests.
    ///   - taskBox: A holder the in-flight data task is written into, so the
    ///     `SSEStream` cancellation hook can cut the request.
    ///   - makeRequest: An async builder for the outgoing request, run inside the
    ///     producer task. It applies the interceptor chain and the SSE `Accept`
    ///     header.
    /// - Returns: A fresh line stream.
    static func makeLineSource(
        configuration: URLSessionConfiguration,
        baseSession: URLSession,
        taskBox: SSEStreamTaskBox,
        makeRequest: @escaping @Sendable () async throws -> URLRequest,
        onResponse: @escaping @Sendable (HTTPURLResponse, URLRequest) async throws -> Void
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let streamingSession: URLSession = URLSession(
                configuration: configuration,
                delegate: baseSession.delegate,
                delegateQueue: nil
            )

            let producer: Task<Void, Never> = Task {
                do {
                    let request: URLRequest = try await makeRequest()

                    let (bytes, urlResponse): (URLSession.AsyncBytes, URLResponse) =
                        try await streamingSession.bytes(for: request)
                    taskBox.set(bytes.task)

                    guard let httpResponse = urlResponse as? HTTPURLResponse else {
                        throw NetworkError.unknown(
                            request: RequestSnapshot(request: request),
                            underlyingError: NSError(domain: "NetKit", code: -1, userInfo: [
                                NSLocalizedDescriptionKey: "Invalid response type"
                            ])
                        )
                    }

                    try await onResponse(httpResponse, request)

                    try await emitLines(from: bytes, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                taskBox.cancel()
                producer.cancel()
                streamingSession.invalidateAndCancel()
            }
        }
    }

    /// Splits an `AsyncBytes` sequence into lines and yields them, preserving
    /// empty lines.
    ///
    /// `AsyncBytes.lines` is unsuitable for SSE because it omits empty lines, and
    /// the blank line is precisely the SSE event delimiter. This splitter honors
    /// all three SSE line terminators: `\n`, `\r`, and `\r\n`.
    private static func emitLines(
        from bytes: URLSession.AsyncBytes,
        into continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async throws {
        var buffer: [UInt8] = []
        var previousWasCR: Bool = false

        for try await byte in bytes {
            switch byte {
            case 0x0A: // \n
                if previousWasCR {
                    // Tail of a CRLF pair; the line was already emitted on the
                    // \r. Swallow this \n.
                    previousWasCR = false
                } else {
                    continuation.yield(decodeLine(buffer))
                    buffer.removeAll(keepingCapacity: true)
                }

            case 0x0D: // \r
                continuation.yield(decodeLine(buffer))
                buffer.removeAll(keepingCapacity: true)
                previousWasCR = true

            default:
                previousWasCR = false
                buffer.append(byte)
            }
        }

        // Emit any trailing partial line (no terminating newline).
        if !buffer.isEmpty {
            continuation.yield(decodeLine(buffer))
        }
    }

    /// Decodes a buffered line of UTF-8 bytes into a `String`, replacing any
    /// invalid sequences rather than dropping the line. SSE mandates UTF-8 and a
    /// malformed byte must not discard the surrounding line, so the lossy,
    /// non-failable `String(decoding:as:)` is the correct choice here.
    private static func decodeLine(_ bytes: [UInt8]) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }
}
