import Foundation

// MARK: - Request Snapshot

/// A snapshot of the request that was made when an error occurred.
public struct RequestSnapshot: Sendable, Equatable {
    /// The URL that was requested.
    public let url: URL?

    /// The HTTP method used.
    public let method: String?

    /// Sanitized headers (sensitive values are redacted).
    public let headers: [String: String]

    /// The size of the request body in bytes, if any.
    public let bodySize: Int?

    /// Creates a request snapshot from a URLRequest.
    /// - Parameter request: The URLRequest to snapshot.
    public init(request: URLRequest) {
        self.url = request.url
        self.method = request.httpMethod
        self.headers = sanitizeHeadersWithDefaultConfig(request.allHTTPHeaderFields)
        self.bodySize = request.httpBody?.count
    }

    /// Creates a request snapshot with explicit values.
    public init(
        url: URL?,
        method: String?,
        headers: [String: String] = [:],
        bodySize: Int? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = sanitizeHeadersWithDefaultConfig(headers)
        self.bodySize = bodySize
    }
}

// MARK: - Response Snapshot

/// A snapshot of the response received when an error occurred.
public struct ResponseSnapshot: Sendable, Equatable {
    /// The HTTP status code.
    public let statusCode: Int

    /// Sanitized response headers.
    public let headers: [String: String]

    /// A preview of the response body (first 512 bytes as UTF-8 string).
    public let bodyPreview: String?

    /// The total size of the response body in bytes.
    public let bodySize: Int?

    /// Maximum bytes to include in body preview.
    private static let maxPreviewSize: Int = 512

    /// Extracts a UTF-8 safe body preview from data.
    /// If truncation breaks a multi-byte character, progressively reduces size
    /// until a valid UTF-8 boundary is found.
    private static func extractBodyPreview(from data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }

        var validPrefix: Data = data.prefix(maxPreviewSize)
        while !validPrefix.isEmpty {
            if let preview = String(data: validPrefix, encoding: .utf8) {
                return preview
            }
            validPrefix = validPrefix.dropLast()
        }
        return nil
    }

    /// Creates a response snapshot from an HTTPURLResponse and optional data.
    /// - Parameters:
    ///   - response: The HTTP response.
    ///   - data: The response body data, if available.
    public init(response: HTTPURLResponse, data: Data? = nil) {
        self.statusCode = response.statusCode

        var headerDict: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let keyString = key as? String, let valueString = value as? String {
                headerDict[keyString] = valueString
            }
        }
        self.headers = sanitizeHeadersWithDefaultConfig(headerDict)

        self.bodySize = data?.count

        self.bodyPreview = Self.extractBodyPreview(from: data)
    }

    /// Creates a response snapshot with explicit values.
    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        bodyPreview: String? = nil,
        bodySize: Int? = nil
    ) {
        self.statusCode = statusCode
        self.headers = sanitizeHeadersWithDefaultConfig(headers)
        self.bodyPreview = bodyPreview
        self.bodySize = bodySize
    }
}

// MARK: - Error Kind

/// The specific kind of network error that occurred.
public enum ErrorKind: Sendable, Equatable {
    /// The URL was invalid or malformed.
    case invalidURL

    /// No network connection is available.
    case noConnection

    /// The request timed out.
    case timeout

    /// Authentication is required (HTTP 401).
    case unauthorized

    /// Access is forbidden (HTTP 403).
    case forbidden

    /// The resource was not found (HTTP 404).
    case notFound

    /// The server returned no content (HTTP 204).
    case noContent

    /// Too many requests, rate limited (HTTP 429).
    case rateLimited

    /// Bad gateway error (HTTP 502).
    case badGateway

    /// Service temporarily unavailable (HTTP 503).
    case serviceUnavailable

    /// Gateway timeout (HTTP 504).
    case gatewayTimeout

    /// Other server error with status code (HTTP 5xx).
    case serverError(statusCode: Int)

    /// Other client error with status code (HTTP 4xx).
    case clientError(statusCode: Int)

    /// Failed to decode the response.
    case decodingFailed

    /// Failed to encode the request body.
    case encodingFailed

    /// An unknown error occurred.
    case unknown

    /// Returns `true` if this is a server-side error (5xx).
    public var isServerError: Bool {
        switch self {
        case .serverError, .badGateway, .serviceUnavailable, .gatewayTimeout:
            return true
        default:
            return false
        }
    }

    /// Returns `true` if this is a client-side error (4xx).
    public var isClientError: Bool {
        switch self {
        case .clientError, .unauthorized, .forbidden, .notFound, .rateLimited:
            return true
        default:
            return false
        }
    }

    /// Returns `true` if this error type is typically retryable.
    public var isRetryable: Bool {
        switch self {
        case .timeout, .noConnection, .serverError, .badGateway, .serviceUnavailable, .gatewayTimeout:
            return true
        default:
            return false
        }
    }

    /// Returns the HTTP status code associated with this error kind, if any.
    public var statusCode: Int? {
        switch self {
        case .noContent: return 204
        case .unauthorized: return 401
        case .forbidden: return 403
        case .notFound: return 404
        case .rateLimited: return 429
        case .badGateway: return 502
        case .serviceUnavailable: return 503
        case .gatewayTimeout: return 504
        case .serverError(let code), .clientError(let code): return code
        default: return nil
        }
    }
}

// MARK: - Network Error

/// An error that occurred during a network operation, with full context.
public struct NetworkError: Error, Sendable, Equatable {
    /// The specific kind of error.
    public let kind: ErrorKind

    /// Snapshot of the request that failed.
    public let request: RequestSnapshot?

    /// Snapshot of the response, if one was received.
    public let response: ResponseSnapshot?

    /// The underlying error that caused this error.
    public let underlyingError: (any Error)?

    /// When the error occurred.
    public let timestamp: Date

    /// Which retry attempt this error occurred on (0-based).
    public let retryAttempt: Int?

    // MARK: - Initializers

    /// Creates a network error with full context.
    public init(
        kind: ErrorKind,
        request: RequestSnapshot? = nil,
        response: ResponseSnapshot? = nil,
        underlyingError: (any Error)? = nil,
        timestamp: Date = Date(),
        retryAttempt: Int? = nil
    ) {
        self.kind = kind
        self.request = request
        self.response = response
        self.underlyingError = underlyingError
        self.timestamp = timestamp
        self.retryAttempt = retryAttempt
    }

    /// Creates a network error from a URLRequest.
    public init(
        kind: ErrorKind,
        request: URLRequest,
        response: ResponseSnapshot? = nil,
        underlyingError: (any Error)? = nil,
        timestamp: Date = Date(),
        retryAttempt: Int? = nil
    ) {
        self.kind = kind
        self.request = RequestSnapshot(request: request)
        self.response = response
        self.underlyingError = underlyingError
        self.timestamp = timestamp
        self.retryAttempt = retryAttempt
    }

    // MARK: - Convenience Factory Methods

    /// Creates an invalidURL error.
    public static func invalidURL(
        request: RequestSnapshot? = nil,
        underlyingError: (any Error)? = nil
    ) -> NetworkError {
        NetworkError(kind: .invalidURL, request: request, underlyingError: underlyingError)
    }

    /// Creates a noConnection error.
    public static func noConnection(
        request: RequestSnapshot? = nil,
        underlyingError: (any Error)? = nil
    ) -> NetworkError {
        NetworkError(kind: .noConnection, request: request, underlyingError: underlyingError)
    }

    /// Creates a timeout error.
    public static func timeout(
        request: RequestSnapshot? = nil,
        underlyingError: (any Error)? = nil
    ) -> NetworkError {
        NetworkError(kind: .timeout, request: request, underlyingError: underlyingError)
    }

    /// Creates an unauthorized error.
    public static func unauthorized(
        request: RequestSnapshot? = nil,
        response: ResponseSnapshot? = nil
    ) -> NetworkError {
        NetworkError(kind: .unauthorized, request: request, response: response)
    }

    /// Creates a forbidden error.
    public static func forbidden(
        request: RequestSnapshot? = nil,
        response: ResponseSnapshot? = nil
    ) -> NetworkError {
        NetworkError(kind: .forbidden, request: request, response: response)
    }

    /// Creates a notFound error.
    public static func notFound(
        request: RequestSnapshot? = nil,
        response: ResponseSnapshot? = nil
    ) -> NetworkError {
        NetworkError(kind: .notFound, request: request, response: response)
    }

    /// Creates a noContent error.
    public static func noContent(
        request: RequestSnapshot? = nil,
        response: ResponseSnapshot? = nil
    ) -> NetworkError {
        NetworkError(kind: .noContent, request: request, response: response)
    }

    /// Creates a rateLimited error.
    public static func rateLimited(
        request: RequestSnapshot? = nil,
        response: ResponseSnapshot? = nil
    ) -> NetworkError {
        NetworkError(kind: .rateLimited, request: request, response: response)
    }

    /// Creates a decodingFailed error.
    public static func decodingFailed(
        request: RequestSnapshot? = nil,
        response: ResponseSnapshot? = nil,
        underlyingError: (any Error)? = nil
    ) -> NetworkError {
        NetworkError(
            kind: .decodingFailed,
            request: request,
            response: response,
            underlyingError: underlyingError
        )
    }

    /// Creates an encodingFailed error.
    public static func encodingFailed(underlyingError: (any Error)? = nil) -> NetworkError {
        NetworkError(kind: .encodingFailed, underlyingError: underlyingError)
    }

    /// Creates an unknown error.
    public static func unknown(
        request: RequestSnapshot? = nil,
        underlyingError: (any Error)? = nil
    ) -> NetworkError {
        NetworkError(kind: .unknown, request: request, underlyingError: underlyingError)
    }

    /// Creates a server error from an HTTP status code.
    public static func fromStatusCode(
        _ statusCode: Int,
        request: RequestSnapshot? = nil,
        response: ResponseSnapshot? = nil
    ) -> NetworkError {
        let kind: ErrorKind = switch statusCode {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 429: .rateLimited
        case 502: .badGateway
        case 503: .serviceUnavailable
        case 504: .gatewayTimeout
        case 500..<600: .serverError(statusCode: statusCode)
        case 400..<500: .clientError(statusCode: statusCode)
        default: .serverError(statusCode: statusCode)
        }

        return NetworkError(kind: kind, request: request, response: response)
    }

    // MARK: - Equatable

    /// Compares two NetworkError instances for equality.
    ///
    /// Note: The `timestamp` field is intentionally excluded from equality comparison
    /// since semantically equal errors may occur at different times.
    /// The `underlyingError` is compared using NSError domain and code only.
    public static func == (lhs: NetworkError, rhs: NetworkError) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        guard lhs.request == rhs.request else { return false }
        guard lhs.response == rhs.response else { return false }
        guard lhs.retryAttempt == rhs.retryAttempt else { return false }

        switch (lhs.underlyingError, rhs.underlyingError) {
        case (nil, nil):
            return true
        case (let lhsError?, let rhsError?):
            let lhsNS: NSError = lhsError as NSError
            let rhsNS: NSError = rhsError as NSError
            return lhsNS.domain == rhsNS.domain && lhsNS.code == rhsNS.code
        default:
            return false
        }
    }
}

// MARK: - LocalizedError Conformance

extension NetworkError: LocalizedError {
    public var errorDescription: String? {
        switch kind {
        case .invalidURL:
            return "The URL is invalid or malformed."
        case .noConnection:
            return "No network connection is available."
        case .timeout:
            return "The request timed out."
        case .unauthorized:
            return "Authentication is required."
        case .forbidden:
            return "Access to the resource is forbidden."
        case .notFound:
            return "The requested resource was not found."
        case .noContent:
            return "The server returned no content."
        case .rateLimited:
            return "Too many requests. Please try again later."
        case .badGateway:
            return "Bad gateway error."
        case .serviceUnavailable:
            return "The service is temporarily unavailable."
        case .gatewayTimeout:
            return "The gateway timed out."
        case .serverError(let statusCode):
            return "Server error (HTTP \(statusCode))."
        case .clientError(let statusCode):
            return "Client error (HTTP \(statusCode))."
        case .decodingFailed:
            return "Failed to decode the response."
        case .encodingFailed:
            return "Failed to encode the request body."
        case .unknown:
            return "An unknown error occurred."
        }
    }

    public var failureReason: String? {
        if let response {
            return "Server responded with status code \(response.statusCode)."
        }
        if let underlyingError {
            return underlyingError.localizedDescription
        }
        return nil
    }

    public var recoverySuggestion: String? {
        switch kind {
        case .noConnection:
            return "Check your internet connection and try again."
        case .timeout:
            return "The server may be slow. Please try again."
        case .unauthorized:
            return "Please log in and try again."
        case .rateLimited:
            return "Wait a moment before retrying."
        case .serviceUnavailable, .badGateway, .gatewayTimeout:
            return "The service may be temporarily down. Please try again later."
        default:
            return nil
        }
    }
}

// MARK: - CustomDebugStringConvertible

extension NetworkError: CustomDebugStringConvertible {
    public var debugDescription: String {
        var parts: [String] = ["NetworkError(\(kind))"]

        if let request {
            parts.append("request: \(request.method ?? "?") \(request.url?.absoluteString ?? "?")")
        }

        if let response {
            parts.append("response: \(response.statusCode)")
            if let preview = response.bodyPreview {
                let truncated: String = preview.prefix(100) + (preview.count > 100 ? "..." : "")
                parts.append("body: \(truncated)")
            }
        }

        if let retryAttempt {
            parts.append("attempt: \(retryAttempt)")
        }

        if let underlyingError {
            parts.append("underlying: \(underlyingError)")
        }

        return parts.joined(separator: ", ")
    }
}
