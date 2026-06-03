import Foundation

/// A line-by-line state machine that assembles ``SSEEvent`` values from a
/// Server-Sent Events byte stream split into lines.
///
/// The parser implements the SSE wire protocol. It is fed one line at a time
/// via ``consume(line:)`` and accumulates `field: value` lines into an internal
/// buffer until a blank line closes the current event. Because the line
/// iterator is independent of TCP packet boundaries, an event may arrive
/// fragmented across several network chunks; feeding the lines in order always
/// produces the correct assembled event.
///
/// Protocol rules implemented:
/// - A blank line dispatches the buffered event only when at least one `data:`
///   field was seen, per the WHATWG spec ("if the data buffer is an empty string,
///   return without dispatching"). `event:`, `id:`, and `retry:` alone do not trigger dispatch.
/// - A line beginning with `:` is a comment (e.g. keep-alive) and is ignored.
/// - A `field: value` line splits on the first `:`; a single leading space after
///   the colon is stripped per spec. A line with no colon is a field with an
///   empty value.
/// - Multiple `data:` lines for one event are concatenated with `\n`.
/// - The last seen `id` and last `retry` are captured and propagated.
///
/// This type performs no networking and is fully testable in isolation.
struct SSELineParser {
    /// The last event identifier seen on the stream (`id:` field).
    /// Persists across events so it can feed reconnection (`Last-Event-ID`).
    private(set) var lastEventID: String?

    /// The most recent reconnection time in milliseconds seen on the stream.
    private(set) var lastRetry: Int?

    /// Buffer for the event type of the event currently being assembled.
    private var currentEvent: String?

    /// Buffered `data:` lines for the event currently being assembled.
    private var dataLines: [String] = []

    /// Creates an empty parser.
    init() {}

    /// Feeds a single line into the parser.
    ///
    /// - Parameter line: A line from the stream, without its trailing newline.
    /// - Returns: A completed ``SSEEvent`` when a blank line closes the current
    ///   event, otherwise `nil`.
    mutating func consume(line: String) -> SSEEvent? {
        // A blank line dispatches the current event.
        guard !line.isEmpty else {
            return dispatchEvent()
        }

        // Lines starting with a colon are comments (e.g. keep-alive) — ignore.
        guard !line.hasPrefix(":") else {
            return nil
        }

        let (field, value) = parseField(from: line)
        process(field: field, value: value)
        return nil
    }

    // MARK: - Field Processing

    /// Splits a line into its field name and value per the SSE spec.
    ///
    /// Splits on the first `:`. If a single space follows the colon it is
    /// stripped. A line with no colon is treated as a field with an empty value.
    private func parseField(from line: String) -> (field: String, value: String) {
        guard let colonIndex = line.firstIndex(of: ":") else {
            return (line, "")
        }

        let field: String = String(line[line.startIndex..<colonIndex])
        var valueStart: String.Index = line.index(after: colonIndex)

        // Strip exactly one leading space after the colon, per spec.
        if valueStart < line.endIndex, line[valueStart] == " " {
            valueStart = line.index(after: valueStart)
        }

        let value: String = String(line[valueStart..<line.endIndex])
        return (field, value)
    }

    /// Applies a parsed field/value pair to the event being assembled.
    private mutating func process(field: String, value: String) {
        switch field {
        case "event":
            currentEvent = value

        case "data":
            dataLines.append(value)

        case "id":
            lastEventID = value

        case "retry":
            // Per spec the retry value must be an integer count of milliseconds;
            // ignore non-numeric values.
            if let milliseconds = Int(value) {
                lastRetry = milliseconds
            }

        default:
            // Unknown fields are ignored per spec.
            break
        }
    }

    // MARK: - Dispatch

    /// Builds and returns the buffered event, then resets the per-event buffer.
    ///
    /// Per the WHATWG spec, returns `nil` when no `data:` field has been seen
    /// for the current event (data buffer is effectively empty). Fields like
    /// `event:`, `id:`, and `retry:` alone do not trigger dispatch.
    private mutating func dispatchEvent() -> SSEEvent? {
        guard !dataLines.isEmpty else {
            resetEventBuffer()
            return nil
        }

        let event = SSEEvent(
            event: currentEvent,
            data: dataLines.joined(separator: "\n"),
            id: lastEventID,
            retry: lastRetry
        )

        resetEventBuffer()
        return event
    }

    /// Clears the per-event buffer while preserving stream-level state
    /// (`lastEventID`, `lastRetry`).
    private mutating func resetEventBuffer() {
        currentEvent = nil
        dataLines.removeAll()
    }
}
