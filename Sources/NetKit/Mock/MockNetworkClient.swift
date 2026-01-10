import Foundation

/// A mock network client for testing that allows stubbing responses and tracking calls.
public actor MockNetworkClient: NetworkClientProtocol {
    private var stubs: [ObjectIdentifier: Any] = [:]
    private var errorStubs: [ObjectIdentifier: NetworkError] = [:]
    private var delays: [ObjectIdentifier: TimeInterval] = [:]
    private var callCounts: [ObjectIdentifier: Int] = [:]
    private var calledEndpoints: [ObjectIdentifier: [Any]] = [:]

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

    public var errorDescription: String? {
        switch self {
        case .noStubConfigured(let endpoint):
            return "No stub configured for endpoint: \(endpoint)"
        }
    }
}
