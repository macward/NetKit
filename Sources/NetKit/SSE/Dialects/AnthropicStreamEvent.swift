import Foundation

/// A minimal text delta fragment for an Anthropic-style streaming response.
///
/// This models only the transport shape of a single `content_block_delta`
/// event — the smallest slice needed to demonstrate the dialect pattern. It is
/// **not** a faithful reproduction of Anthropic's full schema: there is no
/// token usage, no message metadata, no tool use, and no stop reasons. Real
/// events nest the incremental text under `delta.text`, which is mirrored here
/// at a reduced depth.
public struct AnthropicDelta: Decodable, Sendable, Equatable {
    /// The incremental content carried by a `content_block_delta` event.
    public struct Delta: Decodable, Sendable, Equatable {
        /// The newly streamed text fragment.
        public let text: String

        public init(text: String) {
            self.text = text
        }
    }

    /// The incremental delta for this event.
    public let delta: Delta

    public init(delta: Delta) {
        self.delta = delta
    }
}

// MARK: - AnthropicStreamEvent

/// A ready-made ``SSEDecodableEvent`` preset modeling the Anthropic dialect.
///
/// Unlike the OpenAI dialect (which sends nameless `data:` lines and a literal
/// `[DONE]` sentinel), Anthropic-style streams **name** every event via the
/// SSE `event:` field, and the associated `data:` JSON has a *different shape
/// per name*. This preset's discrimination therefore switches on `eventName`
/// and decodes `data` into the type associated with that name:
///
/// - `content_block_delta` → ``contentBlockDelta(_:)`` carrying an
///   ``AnthropicDelta`` decoded from the JSON payload.
/// - `message_start` → ``messageStart`` (a non-terminal lifecycle marker; the
///   payload is intentionally ignored to keep the preset minimal).
/// - `message_stop` → ``messageStop``, the terminal event that ends the stream
///   (`isTerminal == true`). Its payload is ignored — the name alone is
///   sufficient — so this case is **never** decoded as JSON.
///
/// Because each named event maps to a distinct enum case (and the delta case
/// carries a distinct payload type), a consumer can tell `content_block_delta`
/// apart from `message_stop` simply by matching the case — without manually
/// parsing the `event:` name themselves.
///
/// **Unknown-event behavior:** any other (or missing) event name maps to the
/// benign, non-terminal ``unknown(name:)`` case rather than throwing. Streams
/// routinely add new lifecycle events (`ping`, `content_block_start`,
/// `message_delta`, …); mapping them to a quietly-ignorable case keeps the
/// stream alive and forward-compatible. A JSON decode failure for a *known*
/// payload-bearing event (i.e. `content_block_delta`) still throws
/// ``SSEError/decodingFailed(_:)`` so genuine corruption surfaces.
///
/// This is a transport preset, not an Anthropic SDK: it carries no message
/// session, accumulator, token counting, prompts, or tool calling. It exists to
/// show how the single ``SSEDecodableEvent`` contract expresses a dialect that
/// discriminates by event name.
public enum AnthropicStreamEvent: SSEDecodableEvent, Equatable {
    /// An incremental text fragment decoded from a `content_block_delta` event.
    case contentBlockDelta(AnthropicDelta)

    /// The non-terminal `message_start` lifecycle marker.
    case messageStart

    /// The terminal `message_stop` event that closes the stream.
    case messageStop

    /// Any unrecognized (or unnamed) event, kept as a benign, non-terminal case
    /// so unknown lifecycle events do not break the stream.
    case unknown(name: String?)

    public init(eventName: String?, data: String) throws {
        switch eventName {
        case "content_block_delta":
            // The only payload-bearing event modeled here: decode the JSON.
            do {
                let decoded: AnthropicDelta = try JSONDecoder().decode(AnthropicDelta.self, from: Data(data.utf8))
                self = .contentBlockDelta(decoded)
            } catch {
                throw SSEError.decodingFailed(error)
            }
        case "message_start":
            // Lifecycle marker; the name is sufficient, the payload is ignored.
            self = .messageStart
        case "message_stop":
            // Terminal marker; the name alone ends the stream, never decoded.
            self = .messageStop
        default:
            // Forward-compatible: unknown / missing names are benign.
            self = .unknown(name: eventName)
        }
    }

    public var isTerminal: Bool {
        if case .messageStop = self { return true }
        return false
    }
}
