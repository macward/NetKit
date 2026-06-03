import Testing
import Foundation
@testable import NetKit

// MARK: - OpenAIStreamEvent Tests

@Suite("OpenAIStreamEvent dialect preset")
struct OpenAIStreamEventTests {
    @Test("A valid JSON fragment decodes to the delta case")
    func validFragmentDecodesToDelta() throws {
        let json: String = #"{"choices":[{"delta":{"content":"Hello"}}]}"#
        let event: OpenAIStreamEvent = try OpenAIStreamEvent(eventName: nil, data: json)
        guard case .delta(let delta) = event else {
            Issue.record("Expected .delta case")
            return
        }
        #expect(delta.choices.first?.delta.content == "Hello")
        #expect(event.isTerminal == false)
    }

    @Test("The [DONE] sentinel produces the terminal case without decoding JSON")
    func doneSentinelIsTerminal() throws {
        let event: OpenAIStreamEvent = try OpenAIStreamEvent(eventName: nil, data: "[DONE]")
        #expect(event == .done)
        #expect(event.isTerminal == true)
    }

    @Test("The [DONE] sentinel is detected leniently with surrounding whitespace")
    func doneSentinelToleratesWhitespace() throws {
        let event: OpenAIStreamEvent = try OpenAIStreamEvent(eventName: nil, data: "  [DONE] ")
        #expect(event == .done)
        #expect(event.isTerminal == true)
    }

    @Test("The event: name is ignored; discrimination is by data content")
    func ignoresEventName() throws {
        // Even with a non-nil event name, the preset discriminates by data.
        let event: OpenAIStreamEvent = try OpenAIStreamEvent(eventName: "chunk", data: "[DONE]")
        #expect(event == .done)
    }

    @Test("A malformed JSON fragment throws SSEError.decodingFailed")
    func malformedFragmentThrows() {
        #expect(throws: SSEError.self) {
            _ = try OpenAIStreamEvent(eventName: nil, data: "not-json")
        }
    }
}
