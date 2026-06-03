import Foundation

/// A single Server-Sent Event as defined by the SSE protocol.
///
/// An SSE event is assembled from one or more `field: value` lines that the
/// server sends, terminated by a blank line. The fields map directly to the
/// standard SSE fields:
///
/// - `event`: The event type name (the `event:` field). `nil` when omitted.
/// - `data`: The event payload (the `data:` field). Multiple `data:` lines for
///   a single event are concatenated with `\n` (newline) separators.
/// - `id`: The last event identifier seen on the stream (the `id:` field). Used
///   to resume a stream via the `Last-Event-ID` header on reconnection.
/// - `retry`: The reconnection time in milliseconds suggested by the server
///   (the `retry:` field). `nil` when not provided or non-numeric.
///
/// Example:
/// ```
/// event: message
/// data: hello
/// data: world
/// id: 42
///
/// ```
/// produces `SSEEvent(event: "message", data: "hello\nworld", id: "42", retry: nil)`.
public struct SSEEvent: Sendable, Equatable {
    /// The event type name (`event:` field), or `nil` if not specified.
    public let event: String?

    /// The event payload (`data:` field). Multiple `data:` lines are joined with `\n`.
    public let data: String

    /// The last seen event identifier (`id:` field), or `nil` if not specified.
    public let id: String?

    /// The reconnection time in milliseconds (`retry:` field), or `nil` if not specified.
    public let retry: Int?

    /// Creates a Server-Sent Event.
    /// - Parameters:
    ///   - event: The event type name. Defaults to `nil`.
    ///   - data: The event payload. Defaults to an empty string.
    ///   - id: The last seen event identifier. Defaults to `nil`.
    ///   - retry: The reconnection time in milliseconds. Defaults to `nil`.
    public init(
        event: String? = nil,
        data: String = "",
        id: String? = nil,
        retry: Int? = nil
    ) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}
