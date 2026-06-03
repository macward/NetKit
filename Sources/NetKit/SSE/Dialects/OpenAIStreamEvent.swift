import Foundation

/// A minimal delta fragment for an OpenAI-style streaming chat response.
///
/// This models only the transport shape of a single streamed JSON fragment —
/// the smallest slice needed to demonstrate the dialect pattern. It is **not**
/// a faithful reproduction of OpenAI's full schema: there is no token usage,
/// no prompt echo, and no tool-calling. Real APIs nest the incremental text
/// under `choices[].delta.content`, which is mirrored here at a reduced depth.
public struct OpenAIDelta: Decodable, Sendable, Equatable {
    /// One streamed choice carrying an incremental delta.
    public struct Choice: Decodable, Sendable, Equatable {
        /// The incremental content for this choice.
        public struct Delta: Decodable, Sendable, Equatable {
            /// The newly streamed text fragment, if any.
            public let content: String?

            public init(content: String?) {
                self.content = content
            }
        }

        /// The incremental delta for this choice.
        public let delta: Delta

        public init(delta: Delta) {
            self.delta = delta
        }
    }

    /// The streamed choices for this fragment.
    public let choices: [Choice]

    public init(choices: [Choice]) {
        self.choices = choices
    }
}

// MARK: - OpenAIStreamEvent

/// A ready-made ``SSEDecodableEvent`` preset modeling the OpenAI dialect.
///
/// OpenAI-style streams send only `data:` lines (no `event:` name), one JSON
/// fragment per event, and close the stream with the literal sentinel line
/// `data: [DONE]`. This preset's discrimination therefore **ignores**
/// `eventName` entirely and inspects the `data` payload:
///
/// - When `data` is the literal `[DONE]` sentinel it produces the terminal
///   ``done`` case and **never** attempts to decode it as JSON.
/// - Otherwise it decodes the JSON fragment into ``OpenAIDelta`` and produces
///   ``delta(_:)``. A decode failure throws ``SSEError/decodingFailed(_:)`` so
///   the stream surfaces the error.
///
/// This is a transport preset, not an OpenAI SDK: it carries no chat session,
/// accumulator, or business logic. It exists to show how the single
/// ``SSEDecodableEvent`` contract expresses the OpenAI dialect.
public enum OpenAIStreamEvent: SSEDecodableEvent, Equatable {
    /// An incremental content fragment decoded from a `data:` JSON line.
    case delta(OpenAIDelta)

    /// The terminal `[DONE]` sentinel that closes the stream.
    case done

    /// The literal sentinel that marks the end of an OpenAI-style stream.
    private static let doneSentinel: String = "[DONE]"

    public init(eventName: String?, data: String) throws {
        // The OpenAI dialect carries no `event:` name; discrimination is purely
        // by `data` content. Be lenient about surrounding whitespace.
        let trimmed: String = data.trimmingCharacters(in: .whitespaces)
        if trimmed == Self.doneSentinel {
            // The sentinel is terminal and must NEVER be decoded as JSON.
            self = .done
            return
        }
        do {
            let decoded: OpenAIDelta = try JSONDecoder().decode(OpenAIDelta.self, from: Data(data.utf8))
            self = .delta(decoded)
        } catch {
            throw SSEError.decodingFailed(error)
        }
    }

    public var isTerminal: Bool {
        if case .done = self { return true }
        return false
    }
}
