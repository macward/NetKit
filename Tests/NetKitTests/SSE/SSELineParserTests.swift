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

    // MARK: - Data-only dispatch rule (WHATWG spec §9.2.6)

    @Test("event: field alone does not dispatch — no data buffer")
    func eventFieldWithoutDataDoesNotDispatch() {
        var parser = SSELineParser()
        // A server-sent ping using only the event field must be silently absorbed.
        let events = parser.consumeAll([
            "event: ping",
            ""
        ])

        #expect(events.isEmpty)
    }

    @Test("id: field alone does not dispatch — no data buffer")
    func idFieldWithoutDataDoesNotDispatch() {
        var parser = SSELineParser()
        let events = parser.consumeAll([
            "id: 42",
            ""
        ])

        #expect(events.isEmpty)
        // The id is still captured for reconnection purposes.
        #expect(parser.lastEventID == "42")
    }

    @Test("retry: field alone does not dispatch — no data buffer")
    func retryFieldWithoutDataDoesNotDispatch() {
        var parser = SSELineParser()
        let events = parser.consumeAll([
            "retry: 3000",
            ""
        ])

        #expect(events.isEmpty)
        #expect(parser.lastRetry == 3000)
    }

    @Test("event: + id: together without data: do not dispatch")
    func eventAndIdWithoutDataDoNotDispatch() {
        var parser = SSELineParser()
        let events = parser.consumeAll([
            "event: ping",
            "id: 7",
            ""
        ])

        #expect(events.isEmpty)
    }

    @Test("data: with empty value dispatches with empty data string")
    func explicitEmptyDataFieldDispatches() {
        var parser = SSELineParser()
        // Per spec: the data buffer is "\n" (non-empty), so an event IS dispatched
        // with data = "" after the trailing LF is stripped.
        let events = parser.consumeAll([
            "data:",
            ""
        ])

        #expect(events.count == 1)
        #expect(events.first?.data == "")
    }

    @Test("Non-data fields before a real event do not bleed into it")
    func nonDataFieldsBeforeRealEventAreAbsorbed() {
        var parser = SSELineParser()
        // A server that sends heartbeat pings (event-only) between real events
        // must not poison the next real event.
        let events = parser.consumeAll([
            "event: ping",   // heartbeat — no data, should not dispatch
            "",
            "event: message",
            "data: hello",
            ""
        ])

        #expect(events.count == 1)
        #expect(events.first?.event == "message")
        #expect(events.first?.data == "hello")
    }
}
