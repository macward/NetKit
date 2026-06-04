import Foundation

/// A mock network client for testing that allows stubbing responses and tracking calls.
// swiftlint:disable:next type_body_length
public actor MockNetworkClient: NetworkClientProtocol {
    private var stubs: [ObjectIdentifier: Any] = [:]
    private var errorStubs: [ObjectIdentifier: NetworkError] = [:]
    private var delays: [ObjectIdentifier: TimeInterval] = [:]
    private var callCounts: [ObjectIdentifier: Int] = [:]
    private var calledEndpoints: [ObjectIdentifier: [Any]] = [:]
    private var sequenceStubs: [ObjectIdentifier: SequenceStub] = [:]
    private var uploadStubs: [ObjectIdentifier: Any] = [:]
    private var downloadStubs: [ObjectIdentifier: URL] = [:]
    private var progressSequences: [ObjectIdentifier: [TransferProgress]] = [:]
    private var streamEventStubs: [ObjectIdentifier: [Any]] = [:]
    private var streamErrorStubs: [ObjectIdentifier: any Error] = [:]
    // Line-based stubs live in a lock-protected container so that the
    // nonisolated `stream<E>` method can read them synchronously.
    private let lineStubStorage: LineStubStorage = LineStubStorage()

    /// Internal struct to track sequence-based stubs
    private struct SequenceStub {
        var responses: [Any]
        var errors: [NetworkError?]
        var delays: [TimeInterval]
        var currentIndex: Int = 0
    }

    public init() {}

    // MARK: - Stubbing

    /// Stubs a response for an endpoint type.
    /// - Parameters:
    ///   - type: The endpoint type to stub.
    ///   - response: A closure that returns the response for a given endpoint.
    public func stub<E: Endpoint>(_ type: E.Type, response: @escaping @Sendable (E) -> E.Response) {
        let key = stubKey(for: type)
        stubs[key] = response
        errorStubs.removeValue(forKey: key)
    }

    /// Stubs an error for an endpoint type.
    /// - Parameters:
    ///   - type: The endpoint type to stub.
    ///   - error: The error to throw.
    public func stubError<E: Endpoint>(_ type: E.Type, error: NetworkError) {
        let key = stubKey(for: type)
        errorStubs[key] = error
        stubs.removeValue(forKey: key)
    }

    /// Stubs a response with a delay for an endpoint type.
    /// - Parameters:
    ///   - type: The endpoint type to stub.
    ///   - delay: The delay in seconds before returning the response.
    ///   - response: A closure that returns the response for a given endpoint.
    public func stub<E: Endpoint>(_ type: E.Type, delay: TimeInterval, response: @escaping @Sendable (E) -> E.Response) {
        let key = stubKey(for: type)
        stubs[key] = response
        delays[key] = delay
        errorStubs.removeValue(forKey: key)
    }

    // MARK: - Sequence Stubbing (for polling tests)

    /// Stubs a sequence of responses for an endpoint type.
    /// Each call returns the next response in the sequence.
    /// After all responses are exhausted, throws `MockError.sequenceExhausted`.
    /// - Parameters:
    ///   - type: The endpoint type to stub.
    ///   - responses: Array of responses to return in order.
    ///   - delays: Optional array of delays for each response.
    public func stubSequence<E: Endpoint>(
        _ type: E.Type,
        responses: [E.Response],
        delays: [TimeInterval] = []
    ) {
        let key = stubKey(for: type)
        sequenceStubs[key] = SequenceStub(
            responses: responses,
            errors: Array(repeating: nil, count: responses.count),
            delays: delays
        )
        stubs.removeValue(forKey: key)
        errorStubs.removeValue(forKey: key)
    }

    /// Stubs a sequence of responses and errors for an endpoint type.
    /// Use this to simulate intermittent failures during polling.
    /// - Parameters:
    ///   - type: The endpoint type to stub.
    ///   - sequence: Array of results (either response or error).
    ///   - delays: Optional array of delays for each result.
    public func stubSequence<E: Endpoint>(
        _ type: E.Type,
        sequence: [Result<E.Response, NetworkError>],
        delays: [TimeInterval] = []
    ) {
        let key = stubKey(for: type)
        var responses: [Any] = []
        var errors: [NetworkError?] = []

        for result in sequence {
            switch result {
            case .success(let response):
                responses.append(response)
                errors.append(nil)
            case .failure(let error):
                responses.append(EmptyResponse()) // Placeholder
                errors.append(error)
            }
        }

        sequenceStubs[key] = SequenceStub(
            responses: responses,
            errors: errors,
            delays: delays
        )
        stubs.removeValue(forKey: key)
        errorStubs.removeValue(forKey: key)
    }

    // MARK: - Stream Stubbing

    /// Stubs a sequence of pre-built events for an SSE endpoint type.
    ///
    /// When the corresponding `stream(_:)` is iterated, the events are yielded in
    /// order with **no network and no parsing**. This is the fast path for
    /// consumer-behavior tests.
    ///
    /// > Important: This mode bypasses the SSE line parser, the
    /// > ``SSEDecodableEvent`` discriminator, and the `isTerminal` /
    /// > ``SSEError/unexpectedDisconnect(lastEventID:)`` semantics. A sequence
    /// > that ends without a terminal event finishes *cleanly* in the mock but
    /// > would throw ``SSEError/unexpectedDisconnect(lastEventID:)`` against a
    /// > real server. To exercise the full parsing pipeline — including terminal
    /// > and disconnect behavior — use ``stubStreamLines(_:lines:error:)`` instead.
    ///
    /// - Parameters:
    ///   - type: The SSE endpoint type to stub.
    ///   - events: The events to yield, in order.
    ///   - error: An optional error to throw after the events are delivered.
    public func stubStream<E: SSEEndpoint>(
        _ type: E.Type,
        events: [E.Event],
        error: (any Error)? = nil
    ) {
        let key: ObjectIdentifier = stubKey(for: type)
        streamEventStubs[key] = events
        if let error {
            streamErrorStubs[key] = error
        } else {
            streamErrorStubs.removeValue(forKey: key)
        }
    }

    /// Stubs a sequence of raw SSE lines for an SSE endpoint type.
    ///
    /// When the corresponding `stream(_:)` is iterated the lines are fed through
    /// the **real** ``SSELineParser`` → ``SSEDecodableEvent`` → `isTerminal` /
    /// ``SSEError/unexpectedDisconnect(lastEventID:)`` pipeline, exactly as they
    /// would be against a live server. Use this overload when a test needs to
    /// verify parsing behavior, terminal semantics, or disconnect handling.
    ///
    /// - Parameters:
    ///   - type: The SSE endpoint type to stub.
    ///   - lines: Raw SSE text lines, including blank delimiters (e.g.
    ///     `["data: hello", ""]`).
    ///   - error: An optional error to throw from the line source after the lines
    ///     are delivered. Simulates a mid-stream transport cut.
    public func stubStreamLines<E: SSEEndpoint>(
        _ type: E.Type,
        lines: [String],
        error: (any Error)? = nil
    ) {
        lineStubStorage.set(lines, error: error, for: ObjectIdentifier(type))
    }

    // MARK: - Call Tracking

    /// Returns the number of times an endpoint type was called.
    /// - Parameter type: The endpoint type.
    /// - Returns: The number of calls.
    public func callCount<E: Endpoint>(for type: E.Type) -> Int {
        let key = stubKey(for: type)
        return callCounts[key] ?? 0
    }

    /// Returns all endpoints of a specific type that were called.
    /// - Parameter type: The endpoint type.
    /// - Returns: An array of endpoints that were called.
    public func calledEndpoints<E: Endpoint>(of type: E.Type) -> [E] {
        let key = stubKey(for: type)
        return (calledEndpoints[key] as? [E]) ?? []
    }

    /// Returns whether an endpoint type was called at least once.
    /// - Parameter type: The endpoint type.
    /// - Returns: `true` if the endpoint was called.
    public func wasCalled<E: Endpoint>(_ type: E.Type) -> Bool {
        callCount(for: type) > 0
    }

    // MARK: - Reset

    /// Resets all stubs, errors, delays, and call history.
    public func reset() {
        stubs.removeAll()
        errorStubs.removeAll()
        delays.removeAll()
        callCounts.removeAll()
        calledEndpoints.removeAll()
        sequenceStubs.removeAll()
        streamEventStubs.removeAll()
        streamErrorStubs.removeAll()
        lineStubStorage.removeAll()
    }

    // MARK: - NetworkClientProtocol

    public func request<E: Endpoint>(_ endpoint: E) async throws -> E.Response {
        let key = stubKey(for: E.self)

        // Record the call
        callCounts[key, default: 0] += 1
        if calledEndpoints[key] == nil {
            calledEndpoints[key] = [E]()
        }
        var endpoints = calledEndpoints[key] as! [E]
        endpoints.append(endpoint)
        calledEndpoints[key] = endpoints

        // Check for sequence stub first
        if var seqStub = sequenceStubs[key] {
            let index = seqStub.currentIndex

            // Check if sequence is exhausted
            guard index < seqStub.responses.count else {
                throw MockError.sequenceExhausted(endpoint: String(describing: E.self))
            }

            // Apply delay if configured for this index
            if index < seqStub.delays.count {
                let delay = seqStub.delays[index]
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }

            // Increment index for next call
            seqStub.currentIndex += 1
            sequenceStubs[key] = seqStub

            // Check for error at this index
            if let error = seqStub.errors[index] {
                throw error
            }

            // Return response
            guard let response = seqStub.responses[index] as? E.Response else {
                throw MockError.noStubConfigured(endpoint: String(describing: E.self))
            }
            return response
        }

        let stubClosure = stubs[key]
        let error = errorStubs[key]
        let delay = delays[key]

        // Apply delay if configured
        if let delay, delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        // Return error if stubbed
        if let error {
            throw error
        }

        // Return response if stubbed
        if let responseClosure = stubClosure as? @Sendable (E) -> E.Response {
            return responseClosure(endpoint)
        }

        // No stub configured
        throw MockError.noStubConfigured(endpoint: String(describing: E.self))
    }

    // MARK: - Private

    private func stubKey<E: Endpoint>(for type: E.Type) -> ObjectIdentifier {
        ObjectIdentifier(type)
    }

    // MARK: - Upload/Download Stubbing

    /// Stubs an upload response for an endpoint type.
    /// - Parameters:
    ///   - type: The endpoint type to stub.
    ///   - progressSequence: Optional sequence of progress updates to emit.
    ///   - response: A closure that returns the response for a given endpoint.
    public func stubUpload<E: Endpoint>(
        _ type: E.Type,
        progressSequence: [TransferProgress] = [],
        response: @escaping @Sendable (E) -> E.Response
    ) {
        let key: ObjectIdentifier = stubKey(for: type)
        uploadStubs[key] = response
        if !progressSequence.isEmpty {
            progressSequences[key] = progressSequence
        }
    }

    /// Stubs a download response for an endpoint type.
    /// - Parameters:
    ///   - type: The endpoint type to stub.
    ///   - progressSequence: Optional sequence of progress updates to emit.
    ///   - destinationURL: The URL to return as the download destination.
    public func stubDownload<E: Endpoint>(
        _ type: E.Type,
        progressSequence: [TransferProgress] = [],
        destinationURL: URL
    ) {
        let key: ObjectIdentifier = stubKey(for: type)
        downloadStubs[key] = destinationURL
        if !progressSequence.isEmpty {
            progressSequences[key] = progressSequence
        }
    }

    // MARK: - Upload Methods

    public func upload<E: Endpoint>(file: URL, to endpoint: E) async -> UploadResult<E.Response> {
        let (stream, continuation) = AsyncStream<TransferProgress>.makeStream()

        let responseTask: Task<E.Response, Error> = Task {
            try await self.performMockUpload(endpoint: endpoint, continuation: continuation)
        }

        return UploadResult(
            progress: TransferProgressStream(stream: stream),
            response: responseTask
        )
    }

    public func upload<E: Endpoint>(formData: MultipartFormData, to endpoint: E) async -> UploadResult<E.Response> {
        let (stream, continuation) = AsyncStream<TransferProgress>.makeStream()

        let responseTask: Task<E.Response, Error> = Task {
            try await self.performMockUpload(endpoint: endpoint, continuation: continuation)
        }

        return UploadResult(
            progress: TransferProgressStream(stream: stream),
            response: responseTask
        )
    }

    private func performMockUpload<E: Endpoint>(
        endpoint: E,
        continuation: AsyncStream<TransferProgress>.Continuation
    ) async throws -> E.Response {
        let key: ObjectIdentifier = stubKey(for: E.self)

        callCounts[key, default: 0] += 1
        if calledEndpoints[key] == nil {
            calledEndpoints[key] = [E]()
        }
        var endpoints = calledEndpoints[key] as! [E]
        endpoints.append(endpoint)
        calledEndpoints[key] = endpoints

        if let progressSeq = progressSequences[key] {
            for progress in progressSeq {
                continuation.yield(progress)
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        if let delay = delays[key], delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        if let error = errorStubs[key] {
            continuation.finish()
            throw error
        }

        if let responseClosure = uploadStubs[key] as? @Sendable (E) -> E.Response {
            let response: E.Response = responseClosure(endpoint)
            continuation.yield(TransferProgress.completed(totalBytes: 1000))
            continuation.finish()
            return response
        }

        if let responseClosure = stubs[key] as? @Sendable (E) -> E.Response {
            let response: E.Response = responseClosure(endpoint)
            continuation.yield(TransferProgress.completed(totalBytes: 1000))
            continuation.finish()
            return response
        }

        continuation.finish()
        throw MockError.noStubConfigured(endpoint: String(describing: E.self))
    }

    // MARK: - Download Methods

    public func download<E: Endpoint>(from endpoint: E, to destination: URL) async -> DownloadResult {
        let (stream, continuation) = AsyncStream<TransferProgress>.makeStream()

        let responseTask: Task<URL, Error> = Task {
            try await self.performMockDownload(endpoint: endpoint, destination: destination, continuation: continuation)
        }

        return DownloadResult(
            progress: TransferProgressStream(stream: stream),
            response: responseTask
        )
    }

    private func performMockDownload<E: Endpoint>(
        endpoint: E,
        destination: URL,
        continuation: AsyncStream<TransferProgress>.Continuation
    ) async throws -> URL {
        let key: ObjectIdentifier = stubKey(for: E.self)

        callCounts[key, default: 0] += 1
        if calledEndpoints[key] == nil {
            calledEndpoints[key] = [E]()
        }
        var endpoints = calledEndpoints[key] as! [E]
        endpoints.append(endpoint)
        calledEndpoints[key] = endpoints

        if let progressSeq = progressSequences[key] {
            for progress in progressSeq {
                continuation.yield(progress)
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        if let delay = delays[key], delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        if let error = errorStubs[key] {
            continuation.finish()
            throw error
        }

        if let stubURL = downloadStubs[key] {
            continuation.yield(TransferProgress.completed(totalBytes: 1000))
            continuation.finish()
            return stubURL
        }

        continuation.yield(TransferProgress.completed(totalBytes: 1000))
        continuation.finish()
        return destination
    }

    // MARK: - Streaming Methods

    public nonisolated func stream<E: SSEEndpoint>(_ endpoint: E) -> SSEStream<E> {
        let key: ObjectIdentifier = ObjectIdentifier(E.self)

        // Prefer lines-mode stub when configured — it exercises the real SSE
        // parser pipeline (including terminal/disconnect semantics).
        if let lineStub = lineStubStorage.get(for: key) {
            return SSEStream(lineSource: {
                AsyncThrowingStream { continuation in
                    let task = Task {
                        await self.recordStreamCall(endpoint: endpoint)
                        for line in lineStub.lines {
                            continuation.yield(line)
                        }
                        if let error = lineStub.error {
                            continuation.finish(throwing: error)
                        } else {
                            continuation.finish()
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            })
        }

        return SSEStream(elements: {
            AsyncThrowingStream { continuation in
                let task = Task {
                    let stub: (events: [E.Event], error: (any Error)?) = await self.stubbedStream(for: endpoint)
                    for event in stub.events {
                        continuation.yield(event)
                    }
                    if let error = stub.error {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        })
    }

    private func recordStreamCall<E: SSEEndpoint>(endpoint: E) {
        let key: ObjectIdentifier = ObjectIdentifier(E.self)
        callCounts[key, default: 0] += 1
        var endpoints: [E] = (calledEndpoints[key] as? [E]) ?? []
        endpoints.append(endpoint)
        calledEndpoints[key] = endpoints
    }

    /// Retrieves the configured stream stub for an endpoint, recording the call.
    ///
    /// If no stub is configured this returns an empty event list with no error,
    /// so the stream simply finishes cleanly (an empty stream). This keeps the
    /// "no stub" path quiet rather than surprising a consumer with an error.
    private func stubbedStream<E: SSEEndpoint>(
        for endpoint: E
    ) -> (events: [E.Event], error: (any Error)?) {
        let key: ObjectIdentifier = stubKey(for: E.self)

        callCounts[key, default: 0] += 1
        if calledEndpoints[key] == nil {
            calledEndpoints[key] = [E]()
        }
        var endpoints = (calledEndpoints[key] as? [E]) ?? []
        endpoints.append(endpoint)
        calledEndpoints[key] = endpoints

        let events: [E.Event] = (streamEventStubs[key] as? [E.Event]) ?? []
        let error: (any Error)? = streamErrorStubs[key]
        return (events, error)
    }
}

// MARK: - LineStubStorage

/// Thread-safe storage for raw SSE line stubs used by ``MockNetworkClient/stubStreamLines(_:lines:error:)``.
///
/// Lives outside the actor so that the `nonisolated` `stream<E>` method can
/// read stubs synchronously without hopping to the actor executor.
private final class LineStubStorage: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var stubs: [ObjectIdentifier: [String]] = [:]
    private var errors: [ObjectIdentifier: any Error] = [:]

    func set(_ lines: [String], error: (any Error)?, for key: ObjectIdentifier) {
        lock.lock()
        stubs[key] = lines
        if let error { errors[key] = error } else { errors.removeValue(forKey: key) }
        lock.unlock()
    }

    func get(for key: ObjectIdentifier) -> (lines: [String], error: (any Error)?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let lines = stubs[key] else { return nil }
        return (lines, errors[key])
    }

    func removeAll() {
        lock.lock()
        stubs.removeAll()
        errors.removeAll()
        lock.unlock()
    }
}

/// Errors specific to MockNetworkClient.
public enum MockError: Error, LocalizedError {
    case noStubConfigured(endpoint: String)
    case sequenceExhausted(endpoint: String)

    public var errorDescription: String? {
        switch self {
        case .noStubConfigured(let endpoint):
            return "No stub configured for endpoint: \(endpoint)"
        case .sequenceExhausted(let endpoint):
            return "Stub sequence exhausted for endpoint: \(endpoint)"
        }
    }
}
