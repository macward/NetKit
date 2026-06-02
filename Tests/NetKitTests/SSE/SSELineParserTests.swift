import Testing
import Foundation
@testable import NetKit

// MARK: - Test Helpers

private extension SSELineParser {
    /// Feeds an ordered sequence of lines, returning every event dispatched.
    mutating func consumeAll(_ lines: [String]) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for line in lines {
            if let event = consume(line: line) {
                events.append(event)
            }
        }
        return events
    }
}

// MARK: - SSELineParser Tests

@Suite("SSELineParser")
struct SSELineParserTests {
    @Test("Assembles a single event from fragmented line deliveries")
    func consumeFragmentedEventProducesSingleEvent() {
        var parser = SSELineParser()

        // Simulate an event arriving across several separate line deliveries.
        #expect(parser.consume(line: "event: message") == nil)
        #expect(parser.consume(line: "data: hello world") == nil)
        #expect(parser.consume(line: "id: 1") == nil)

        // The blank line closes and dispatches the event.
        let event = parser.consume(line: "")

        #expect(event == SSEEvent(event: "message", data: "hello world", id: "1", retry: nil))
    }

    @Test("Ignores comment lines starting with a colon")
    func consumeCommentLineProducesNoEvent() {
        var parser = SSELineParser()

        #expect(parser.consume(line: ": this is a keep-alive comment") == nil)
        #expect(parser.consume(line: ":") == nil)

        // A blank line after only comments dispatches nothing.
        #expect(parser.consume(line: "") == nil)
    }

    @Test("Concatenates multiple data lines with a newline")
    func consumeMultipleDataLinesConcatenatesWithNewline() {
        var parser = SSELineParser()
        let events = parser.consumeAll([
            "data: first",
            "data: second",
            "data: third",
            ""
        ])

        #expect(events.count == 1)
        #expect(events.first?.data == "first\nsecond\nthird")
    }

    @Test("Exposes event, id and retry fields on the emitted event")
    func consumeNamedEventExposesAllFields() {
        var parser = SSELineParser()
        let events = parser.consumeAll([
            "event: update",
            "data: payload",
            "id: abc-123",
            "retry: 5000",
            ""
        ])

        let event = events.first
        #expect(event?.event == "update")
        #expect(event?.data == "payload")
        #expect(event?.id == "abc-123")
        #expect(event?.retry == 5000)
    }

    @Test("Strips exactly one leading space after the colon")
    func parseFieldStripsSingleLeadingSpace() {
        var parser = SSELineParser()
        // Two spaces after the colon: only the first is stripped.
        let events = parser.consumeAll([
            "data:  spaced",
            ""
        ])

        #expect(events.first?.data == " spaced")
    }

    @Test("Treats a line with no colon as a field with empty value")
    func parseFieldWithoutColonHasEmptyValue() {
        var parser = SSELineParser()
        // A bare "data" line contributes an empty data segment.
        let events = parser.consumeAll([
            "data",
            "data: value",
            ""
        ])

        #expect(events.first?.data == "\nvalue")
    }

    @Test("Ignores non-numeric retry values per spec")
    func consumeNonNumericRetryIsIgnored() {
        var parser = SSELineParser()
        let events = parser.consumeAll([
            "data: x",
            "retry: not-a-number",
            ""
        ])

        #expect(events.first?.retry == nil)
        #expect(parser.lastRetry == nil)
    }

    @Test("Captures last seen id and retry across multiple events")
    func consumeCapturesLastIdAndRetryAcrossEvents() {
        var parser = SSELineParser()
        let events = parser.consumeAll([
            "data: one",
            "id: 1",
            "retry: 1000",
            "",
            "data: two",
            ""
        ])

        #expect(events.count == 2)
        // The second event inherits the last seen id and retry from the stream.
        #expect(events[1].id == "1")
        #expect(events[1].retry == 1000)
        #expect(parser.lastEventID == "1")
        #expect(parser.lastRetry == 1000)
    }

    @Test("Dispatches separate events on consecutive blank-line boundaries")
    func consumeMultipleEventsDispatchedSeparately() {
        var parser = SSELineParser()
        let events = parser.consumeAll([
            "data: a",
            "",
            "data: b",
            "",
            "data: c",
            ""
        ])

        #expect(events.map { $0.data } == ["a", "b", "c"])
    }

    @Test("Ignores extra blank lines that carry no buffered fields")
    func consumeExtraBlankLinesProduceNoEvent() {
        var parser = SSELineParser()
        let events = parser.consumeAll([
            "",
            "",
            "data: only",
            "",
            ""
        ])

        #expect(events.count == 1)
        #expect(events.first?.data == "only")
    }
}
