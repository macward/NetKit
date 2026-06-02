import Testing
import Foundation
@testable import NetKit

// MARK: - AnthropicStreamEvent Tests

@Suite("AnthropicStreamEvent dialect preset")
struct AnthropicStreamEventTests {
    @Test("event: content_block_delta produces the delta case with decoded text")
    func contentBlockDeltaDecodesToDelta() throws {
        let json: String = #"{"delta":{"text":"Hello"}}"#
        let event: AnthropicStreamEvent = try AnthropicStreamEvent(eventName: "content_block_delta", data: json)
        guard case .contentBlockDelta(let delta) = event else {
            Issue.record("Expected .contentBlockDelta case")
            return
        }
        #expect(delta.delta.text == "Hello")
        #expect(event.isTerminal == false)
    }

    @Test("event: message_stop produces the terminal case without decoding JSON")
    func messageStopIsTerminal() throws {
        let event: AnthropicStreamEvent = try AnthropicStreamEvent(eventName: "message_stop", data: "")
        #expect(event == .messageStop)
        #expect(event.isTerminal == true)
    }

    @Test("The delta and terminal cases are distinct without manually parsing the name")
    func deltaAndStopAreDistinctCases() throws {
        let delta: AnthropicStreamEvent = try AnthropicStreamEvent(
            eventName: "content_block_delta",
            data: #"{"delta":{"text":"Hi"}}"#
        )
        let stop: AnthropicStreamEvent = try AnthropicStreamEvent(eventName: "message_stop", data: "")
        // The consumer distinguishes them purely by enum case — no name parsing.
        #expect(delta != stop)
        #expect(delta.isTerminal == false)
        #expect(stop.isTerminal == true)
    }

    @Test("event: message_start produces the non-terminal lifecycle case")
    func messageStartIsNonTerminal() throws {
        let event: AnthropicStreamEvent = try AnthropicStreamEvent(eventName: "message_start", data: #"{"type":"message_start"}"#)
        #expect(event == .messageStart)
        #expect(event.isTerminal == false)
    }

    @Test("An unknown event name maps to the benign unknown case and is non-terminal")
    func unknownEventNameMapsToUnknown() throws {
        let event: AnthropicStreamEvent = try AnthropicStreamEvent(eventName: "ping", data: "{}")
        #expect(event == .unknown(name: "ping"))
        #expect(event.isTerminal == false)
    }

    @Test("A missing event name maps to the unknown case")
    func missingEventNameMapsToUnknown() throws {
        let event: AnthropicStreamEvent = try AnthropicStreamEvent(eventName: nil, data: "{}")
        #expect(event == .unknown(name: nil))
        #expect(event.isTerminal == false)
    }

    @Test("Malformed JSON for a known content_block_delta throws SSEError.decodingFailed")
    func malformedDeltaThrows() {
        #expect(throws: SSEError.self) {
            _ = try AnthropicStreamEvent(eventName: "content_block_delta", data: "not-json")
        }
    }
}
