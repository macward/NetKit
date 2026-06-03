import Testing
import Foundation
@testable import NetKit

// MARK: - SSEError Tests

@Suite("SSEError")
struct SSEErrorTests {
    @Test("decodingFailed carries an optional description")
    func decodingFailedShape() {
        let error: SSEError = .decodingFailed(description: "bad json")
        guard case .decodingFailed(let description) = error else {
            Issue.record("Expected .decodingFailed case")
            return
        }
        #expect(description == "bad json")
    }

    @Test("decodingFailed accepts a nil description")
    func decodingFailedNilDescription() {
        let error: SSEError = .decodingFailed(description: nil)
        guard case .decodingFailed(let description) = error else {
            Issue.record("Expected .decodingFailed case")
            return
        }
        #expect(description == nil)
    }

    @Test("decodingFailed convenience captures the underlying error description")
    func decodingFailedFromUnderlyingError() {
        struct SampleError: Error {}
        let underlying: SampleError = SampleError()
        let error: SSEError = .decodingFailed(underlying)
        guard case .decodingFailed(let description) = error else {
            Issue.record("Expected .decodingFailed case")
            return
        }
        #expect(description == underlying.localizedDescription)
    }

    @Test("unexpectedDisconnect carries the last event id")
    func unexpectedDisconnectShape() {
        let error: SSEError = .unexpectedDisconnect(lastEventID: "42")
        guard case .unexpectedDisconnect(let lastEventID) = error else {
            Issue.record("Expected .unexpectedDisconnect case")
            return
        }
        #expect(lastEventID == "42")
    }

    @Test("unexpectedDisconnect accepts a nil last event id")
    func unexpectedDisconnectNilID() {
        let error: SSEError = .unexpectedDisconnect(lastEventID: nil)
        guard case .unexpectedDisconnect(let lastEventID) = error else {
            Issue.record("Expected .unexpectedDisconnect case")
            return
        }
        #expect(lastEventID == nil)
    }

    @Test("decodingFailed is distinguishable from unexpectedDisconnect")
    func casesAreDistinct() {
        let decoding: SSEError = .decodingFailed(description: nil)
        let disconnect: SSEError = .unexpectedDisconnect(lastEventID: nil)
        #expect(decoding != disconnect)
    }

    @Test("Equatable distinguishes disconnects with different last event ids")
    func disconnectEqualityByID() {
        #expect(SSEError.unexpectedDisconnect(lastEventID: "1") != SSEError.unexpectedDisconnect(lastEventID: "2"))
        #expect(SSEError.unexpectedDisconnect(lastEventID: "1") == SSEError.unexpectedDisconnect(lastEventID: "1"))
    }

    @Test("errorDescription is provided for both cases")
    func localizedDescriptions() {
        #expect(SSEError.decodingFailed(description: "x").errorDescription != nil)
        #expect(SSEError.unexpectedDisconnect(lastEventID: "x").errorDescription != nil)
    }
}
