import Foundation

/// A mock network client for testing that allows stubbing responses and tracking calls.
public actor MockNetworkClient: NetworkClientProtocol {
    private var stubs: [ObjectIdentifier: Any] = [:]
    private var errorStubs: [ObjectIdentifier: NetworkError] = [:]
    private var delays: [ObjectIdentifier: TimeInterval] = [:]
    private var callCounts: [ObjectIdentifier: Int] = [:]
    private var calledEndpoints: [ObjectIdentifier: [Any]] = [:]
    private var sequenceStubs: [ObjectIdentifier: SequenceStub] = [:]

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
