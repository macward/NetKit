import Testing
import Foundation
@testable import NetKit

// MARK: - Sample Event & Endpoint

/// A minimal SSE event used to exercise `MockNetworkClient.stubStream`.
private enum MockStreamEvent: SSEDecodableEvent, Equatable {
    case chunk(text: String)
    case done

    init(eventName: String?, data: String) throws {
        if data == "[DONE]" {
            self = .done
            return
        }
        self = .chunk(text: data)
    }

    var isTerminal: Bool {
        if case .done = self { return true }
        return false
    }
}

private struct MockStreamEndpoint: SSEEndpoint {
    var path: String { "/v1/mock/stream" }
    var method: HTTPMethod { .get }
    typealias Event = MockStreamEvent
}

// MARK: - Tests

@Suite("MockNetworkClient stream stubbing")
struct MockNetworkClientStreamTests {
    @Test("Injected event sequence is received complete via for try await without network")
    func stubStreamYieldsAllEvents() async throws {
        let mock: MockNetworkClient = MockNetworkClient()
        let stubbed: [MockStreamEvent] = [
            .chunk(text: "Hello"),
            .chunk(text: "World"),
            .done
        ]
        await mock.stubStream(MockStreamEndpoint.self, events: stubbed)

        var received: [MockStreamEvent] = []
        for try await event in mock.stream(MockStreamEndpoint()) {
            received.append(event)
        }

        #expect(received == stubbed)
        let wasCalled: Bool = await mock.wasCalled(MockStreamEndpoint.self)
        #expect(wasCalled)
        let callCount: Int = await mock.callCount(for: MockStreamEndpoint.self)
        #expect(callCount == 1)
    }

    @Test("Injected error ends the for try await loop with that error after preceding events")
    func stubStreamThrowsInjectedError() async throws {
        let mock: MockNetworkClient = MockNetworkClient()
        await mock.stubStream(
            MockStreamEndpoint.self,
            events: [.chunk(text: "partial")],
            error: SSEError.decodingFailed(description: "boom")
        )

        var received: [MockStreamEvent] = []
        var caught: (any Error)?
        do {
            for try await event in mock.stream(MockStreamEndpoint()) {
                received.append(event)
            }
        } catch {
            caught = error
        }

        #expect(received == [.chunk(text: "partial")])
        #expect(caught as? SSEError == .decodingFailed(description: "boom"))
    }

    @Test("Error-only stub throws without yielding any event")
    func stubStreamErrorOnly() async {
        let mock: MockNetworkClient = MockNetworkClient()
        await mock.stubStream(
            MockStreamEndpoint.self,
            events: [],
            error: SSEError.unexpectedDisconnect(lastEventID: nil)
        )

        await #expect(throws: SSEError.unexpectedDisconnect(lastEventID: nil)) {
            for try await _ in mock.stream(MockStreamEndpoint()) {}
        }
    }

    @Test("No stub configured produces an empty stream that finishes cleanly")
    func streamWithoutStubFinishesEmpty() async throws {
        let mock: MockNetworkClient = MockNetworkClient()

        var received: [MockStreamEvent] = []
        for try await event in mock.stream(MockStreamEndpoint()) {
            received.append(event)
        }

        #expect(received.isEmpty)
    }

    @Test("reset clears stream stubs")
    func resetClearsStreamStubs() async throws {
        let mock: MockNetworkClient = MockNetworkClient()
        await mock.stubStream(MockStreamEndpoint.self, events: [.chunk(text: "x")])
        await mock.reset()

        var received: [MockStreamEvent] = []
        for try await event in mock.stream(MockStreamEndpoint()) {
            received.append(event)
        }

        #expect(received.isEmpty)
    }
}
