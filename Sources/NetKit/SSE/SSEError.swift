import Foundation

/// An error that can occur while consuming a Server-Sent Events (SSE) stream.
///
/// `SSEError` is intentionally distinct from `NetworkError`: the failure modes
/// of a persistent event stream (an undecodable payload, an unexpected
/// mid-stream disconnect) are not covered by the request/response oriented
/// kinds of `NetworkError`. Keeping it separate also lets the typed stream
/// throw a focused, stream-specific error.
///
/// A normal end of stream is *not* represented by this type. When the server
/// closes the connection cleanly the stream simply finishes; `SSEError` is only
/// thrown for the failure cases below.
public enum SSEError: Error, Sendable, Equatable {
    /// The event payload could not be decoded into the expected type.
    ///
    /// The optional `description` carries a human-readable summary of the
    /// underlying decoding failure. The raw underlying error is intentionally
    /// not stored so the case stays `Equatable` and `Sendable`; capture a
    /// description at the throw site instead.
    case decodingFailed(description: String?)

    /// The stream was cut unexpectedly before a clean end was observed.
    ///
    /// This is distinct from a normal stream end and is reconnectable: the
    /// caller can resume from `lastEventID` via the `Last-Event-ID` header.
    /// `lastEventID` is `nil` when no event with an `id:` field was seen.
    case unexpectedDisconnect(lastEventID: String?)
}

// MARK: - Convenience

public extension SSEError {
    /// Creates a `decodingFailed` error from an underlying error, capturing its
    /// localized description.
    /// - Parameter error: The underlying decoding error.
    /// - Returns: A `.decodingFailed` case carrying the error's description.
    static func decodingFailed(_ error: any Error) -> SSEError {
        .decodingFailed(description: error.localizedDescription)
    }
}

// MARK: - LocalizedError Conformance

extension SSEError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .decodingFailed(let description):
            if let description {
                return "Failed to decode the SSE event: \(description)"
            }
            return "Failed to decode the SSE event."
        case .unexpectedDisconnect(let lastEventID):
            if let lastEventID {
                return "The SSE stream disconnected unexpectedly (last event id: \(lastEventID))."
            }
            return "The SSE stream disconnected unexpectedly."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .decodingFailed:
            return nil
        case .unexpectedDisconnect:
            return "The connection can be resumed from the last received event id."
        }
    }
}
