import Testing
import Foundation
@testable import NetKit

// MARK: - Sample Events

/// An OpenAI-style event that discriminates by `data` content.
///
/// The terminal `[DONE]` sentinel is modeled as a dedicated case and is never
/// decoded as JSON.
private enum OpenAIStyleEvent: SSEDecodableEvent {
    case chunk(text: String)
    case done

    private struct Payload: Decodable {
        let text: String
    }

    init(eventName: String?, data: String) throws {
        // Discriminate by data content: the [DONE] sentinel is terminal and
        // must never be parsed as JSON.
        if data == "[DONE]" {
            self = .done
            return
        }
        let decoded: Payload = try JSONDecoder().decode(Payload.self, from: Data(data.utf8))
        self = .chunk(text: decoded.text)
    }

    var isTerminal: Bool {
        if case .done = self { return true }
        return false
    }
}

/// An Anthropic-style event that discriminates by the `event:` name.
private enum AnthropicStyleEvent: SSEDecodableEvent {
    case messageStart(role: String)
    case contentBlockDelta(text: String)
    case messageStop

    private struct StartPayload: Decodable {
        let role: String
    }

    private struct DeltaPayload: Decodable {
        let text: String
    }

    init(eventName: String?, data: String) throws {
        switch eventName {
        case "message_start":
            let decoded: StartPayload = try JSONDecoder().decode(StartPayload.self, from: Data(data.utf8))
            self = .messageStart(role: decoded.role)
        case "content_block_delta":
            let decoded: DeltaPayload = try JSONDecoder().decode(DeltaPayload.self, from: Data(data.utf8))
            self = .contentBlockDelta(text: decoded.text)
        case "message_stop":
            self = .messageStop
        default:
            throw SSEError.decodingFailed(description: "Unknown event: \(eventName ?? "nil")")
        }
    }

    var isTerminal: Bool {
        if case .messageStop = self { return true }
        return false
    }
}

// MARK: - Sample Endpoints

private struct OpenAIStreamEndpoint: SSEEndpoint {
    var path: String { "/v1/chat/completions" }
    var method: HTTPMethod { .post }
    typealias Event = OpenAIStyleEvent
}

private struct AnthropicStreamEndpoint: SSEEndpoint {
    var path: String { "/v1/messages" }
    var method: HTTPMethod { .post }
    typealias Event = AnthropicStyleEvent
}

// MARK: - SSEEndpoint Tests

@Suite("SSEEndpoint")
struct SSEEndpointTests {
    @Test("Conformer reuses Endpoint transport properties without redeclaring them")
    func reusesTransportProperties() {
        let endpoint: OpenAIStreamEndpoint = OpenAIStreamEndpoint()
        #expect(endpoint.path == "/v1/chat/completions")
        #expect(endpoint.method == .post)
        // Inherited Endpoint defaults remain available without redeclaration.
        #expect(endpoint.headers.isEmpty)
        #expect(endpoint.queryParameters.isEmpty)
        #expect(endpoint.body == nil)
    }

    @Test("Inherited Response is neutralized to EmptyResponse by default")
    func responseNeutralizedToEmpty() {
        // The associated Response of the endpoint defaults to EmptyResponse.
        #expect(OpenAIStreamEndpoint.Response.self == EmptyResponse.self)
        #expect(AnthropicStreamEndpoint.Response.self == EmptyResponse.self)
    }

    @Test("OpenAI-style Event discriminates by data content")
    func openAIDiscriminatesByContent() throws {
        let event: OpenAIStyleEvent = try OpenAIStyleEvent(eventName: nil, data: #"{"text":"hello"}"#)
        guard case .chunk(let text) = event else {
            Issue.record("Expected .chunk case")
            return
        }
        #expect(text == "hello")
        #expect(event.isTerminal == false)
    }

    @Test("OpenAI-style terminal [DONE] sentinel is detected without decoding JSON")
    func openAITerminalSentinel() throws {
        let event: OpenAIStyleEvent = try OpenAIStyleEvent(eventName: nil, data: "[DONE]")
        guard case .done = event else {
            Issue.record("Expected .done case")
            return
        }
        #expect(event.isTerminal == true)
    }

    @Test("Anthropic-style Event discriminates by event name")
    func anthropicDiscriminatesByName() throws {
        let start: AnthropicStyleEvent = try AnthropicStyleEvent(
            eventName: "message_start",
            data: #"{"role":"assistant"}"#
        )
        guard case .messageStart(let role) = start else {
            Issue.record("Expected .messageStart case")
            return
        }
        #expect(role == "assistant")
        #expect(start.isTerminal == false)

        let delta: AnthropicStyleEvent = try AnthropicStyleEvent(
            eventName: "content_block_delta",
            data: #"{"text":"hi"}"#
        )
        guard case .contentBlockDelta(let text) = delta else {
            Issue.record("Expected .contentBlockDelta case")
            return
        }
        #expect(text == "hi")
    }

    @Test("Anthropic-style terminal message_stop is detected without decoding JSON")
    func anthropicTerminalEvent() throws {
        let event: AnthropicStyleEvent = try AnthropicStyleEvent(eventName: "message_stop", data: "")
        guard case .messageStop = event else {
            Issue.record("Expected .messageStop case")
            return
        }
        #expect(event.isTerminal == true)
    }

    @Test("Event init throws on undecodable data")
    func initThrowsOnUndecodableData() {
        #expect(throws: (any Error).self) {
            _ = try OpenAIStyleEvent(eventName: nil, data: "not-json")
        }
        #expect(throws: (any Error).self) {
            _ = try AnthropicStyleEvent(eventName: "message_start", data: "not-json")
        }
    }

    @Test("Default isTerminal is false when not overridden")
    func defaultIsTerminalIsFalse() {
        struct PlainEvent: SSEDecodableEvent {
            init(eventName: String?, data: String) throws {}
        }
        let event: PlainEvent = try! PlainEvent(eventName: nil, data: "")
        #expect(event.isTerminal == false)
    }
}
