import Testing
import Foundation
@testable import NetKit

// MARK: - Helpers

private struct PinningStreamEnvironment: NetworkEnvironment {
    var baseURL: URL = URL(string: "https://api.example.com")!
    var defaultHeaders: [String: String] = [:]
    var timeout: TimeInterval = 30
}

private struct PinningStreamEndpoint: SSEEndpoint {
    var path: String { "/stream" }
    var method: HTTPMethod { .get }
    typealias Event = NeverEvent
}

private enum NeverEvent: SSEDecodableEvent {
    init(eventName: String?, data: String) throws { fatalError() }
    var isTerminal: Bool { false }
}

// MARK: - Tests

@Suite("SSE Certificate Pinning")
struct SSECertificatePinningTests {

    /// Verifies that the session stored in sseDependencies is the *same* session
    /// passed to the client — not just a copy of its configuration.
    ///
    /// Before the fix, sseDependencies only transported `session.configuration`,
    /// so the streaming URLSession was always created without a delegate, silently
    /// bypassing certificate pinning.  After the fix, the full session (delegate
    /// included) travels through SSEStreamDependencies.
    @Test("sseDependencies carries the full session, not just its configuration")
    func sseDependenciesCarriesSession() {
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            hosts: ["api.example.com"],
            publicKeys: [Data([0x01, 0x02, 0x03])]
        )
        let pinnedSession: URLSession = PinningSessionFactory.createSession(policy: policy)
        let client: NetworkClient = NetworkClient(
            environment: PinningStreamEnvironment(),
            session: pinnedSession
        )

        let deps: SSEStreamDependencies = client.sseDependencies
        #expect(deps.session === pinnedSession)
    }

    /// Verifies that the pinning delegate attached to the client session is
    /// retrievable from the session exposed by sseDependencies — i.e., the
    /// delegate survives the dependency snapshot and will be wired into the
    /// streaming URLSession that SSEByteTransport creates.
    @Test("sseDependencies session retains the CertificatePinningDelegate")
    func sseDependenciesSessionRetainsPinningDelegate() {
        let policy: SecurityPolicy = SecurityPolicy.publicKeyPinning(
            hosts: ["api.example.com"],
            publicKeys: [Data([0x01, 0x02, 0x03])]
        )
        let pinnedSession: URLSession = PinningSessionFactory.createSession(policy: policy)
        let client: NetworkClient = NetworkClient(
            environment: PinningStreamEnvironment(),
            session: pinnedSession
        )

        let deps: SSEStreamDependencies = client.sseDependencies
        let delegate: CertificatePinningDelegate? = PinningSessionFactory.delegate(for: deps.session)
        #expect(delegate != nil)
    }

    /// Verifies that a client built with the default shared session (no pinning)
    /// still produces a working sseDependencies snapshot — no regression for the
    /// common unpinned case.
    @Test("sseDependencies works for clients without pinning")
    func sseDependenciesWorksWithoutPinning() {
        let client: NetworkClient = NetworkClient(
            environment: PinningStreamEnvironment()
        )
        let deps: SSEStreamDependencies = client.sseDependencies
        // No pinning delegate — factory returns nil, and that is the correct result.
        let delegate: CertificatePinningDelegate? = PinningSessionFactory.delegate(for: deps.session)
        #expect(delegate == nil)
    }
}
