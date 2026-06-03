import Foundation

/// A typed event decoded from a Server-Sent Events (SSE) stream.
///
/// Conforming types own the *discrimination* of the stream: given the optional
/// SSE `event:` name and the raw `data` payload, they decide what to build.
/// This single contract covers both major dialects without any branching in the
/// client:
///
/// - **OpenAI style** discriminates by `data` content. The terminal marker is
///   the `[DONE]` sentinel, which must be modeled as a terminal case and
///   **never** decoded as JSON.
/// - **Anthropic style** discriminates by the `event:` name (for example
///   `message_start`, `content_block_delta`, `message_stop`).
///
/// The initializer `throws` when the payload cannot be decoded, which surfaces
/// naturally as the observable decoding error of the stream.
public protocol SSEDecodableEvent: Sendable {
    /// Builds a typed event from the SSE discriminators.
    ///
    /// This is the single discrimination point of the stream. Implementations
    /// inspect `eventName` (the SSE `event:` field, which may be `nil` or empty)
    /// and/or `data` (the raw concatenated `data:` payload) to decide which
    /// concrete value to produce.
    ///
    /// - Parameters:
    ///   - eventName: The SSE `event:` field. `nil` when the stream did not send
    ///     one (the most common case for OpenAI-style streams).
    ///   - data: The raw `data:` payload, exactly as received (not pre-decoded).
    /// - Throws: An error (typically `SSEError.decodingFailed`) when `data`
    ///   cannot be decoded into the expected shape.
    init(eventName: String?, data: String) throws

    /// Whether this event terminates the stream.
    ///
    /// A generic stream consumer ends iteration when it observes a terminal
    /// event, without knowing the concrete `Event` type. Model sentinels such
    /// as OpenAI's `[DONE]` or Anthropic's `message_stop` so that `isTerminal`
    /// returns `true` for them.
    ///
    /// Defaults to `false`.
    var isTerminal: Bool { get }
}

// MARK: - Default Implementations

public extension SSEDecodableEvent {
    var isTerminal: Bool { false }
}

// MARK: - SSEEndpoint

/// Defines an endpoint that produces a Server-Sent Events (SSE) stream.
///
/// `SSEEndpoint` refines `Endpoint` so that the transport surface
/// (`path`, `method`, `headers`, `queryParameters`, `body`) is reused by
/// composition rather than redeclared. The request/response oriented `Response`
/// inherited from `Endpoint` is neutralized to `EmptyResponse` by default,
/// because an SSE endpoint does not decode a single response body — it yields a
/// sequence of typed ``Event`` values instead.
///
/// The endpoint contributes its own ``Event`` associated type, which owns the
/// stream's discrimination contract (see ``SSEDecodableEvent``). The same
/// protocol covers both the OpenAI dialect (discriminating by `data` content,
/// with a terminal `[DONE]` sentinel) and the Anthropic dialect (discriminating
/// by the `event:` name) without any branching in the client.
///
/// Example (Anthropic-style discrimination by event name):
/// ```swift
/// struct ChatStreamEndpoint: SSEEndpoint {
///     var path: String { "/v1/messages" }
///     var method: HTTPMethod { .post }
///     var body: (any Encodable & Sendable)? { ChatRequest(...) }
///     typealias Event = ChatEvent
/// }
/// ```
public protocol SSEEndpoint: Endpoint {
    /// The typed event produced by this stream.
    ///
    /// The associated type owns the discrimination contract: it decides, from
    /// the SSE `event:` name and the raw `data`, what value to build and whether
    /// that value terminates the stream.
    associatedtype Event: SSEDecodableEvent
}

// MARK: - Default Implementations

public extension SSEEndpoint {
    /// Neutralizes the `Response` inherited from `Endpoint`.
    ///
    /// An SSE endpoint does not decode a single response body, so `Response`
    /// defaults to `EmptyResponse`. Conformers stream typed ``Event`` values
    /// instead and need not declare `Response` themselves.
    typealias Response = EmptyResponse
}
