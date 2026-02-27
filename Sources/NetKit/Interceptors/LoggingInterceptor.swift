import Foundation
import OSLog

/// An interceptor that logs network requests and responses with sensitive data sanitization.
public struct LoggingInterceptor: Interceptor, Sendable {
    /// The level of detail for logging.
    public enum LogLevel: Sendable {
        /// No logging.
        case none
        /// Log only method and URL.
        case minimal
        /// Log method, URL, headers, and body.
        case verbose
    }

    private let level: LogLevel
    private let logger: Logger
    private let sanitization: SanitizationConfig

    /// Creates a logging interceptor.
    /// - Parameters:
    ///   - level: The logging detail level. Defaults to `.minimal`.
    ///   - sanitization: Configuration for sanitizing sensitive data. Defaults to `.default`.
    ///   - subsystem: The subsystem for OSLog. Defaults to bundle identifier.
    ///   - category: The category for OSLog. Defaults to "NetKit".
    public init(
        level: LogLevel = .minimal,
        sanitization: SanitizationConfig = .default,
        subsystem: String = Bundle.main.bundleIdentifier ?? "NetKit",
        category: String = "NetKit"
    ) {
        self.level = level
        self.sanitization = sanitization
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func intercept(request: URLRequest) async throws -> URLRequest {
        logRequest(request)
        return request
    }

    public func intercept(response: HTTPURLResponse, data: Data) async throws -> Data {
        logResponse(response, data: data)
        return data
    }

    // MARK: - Private Methods

    private func logRequest(_ request: URLRequest) {
        guard level != .none else { return }

        let method: String = request.httpMethod ?? "UNKNOWN"
        let sanitizedURL: String = sanitization.sanitizeURL(request.url)

        switch level {
        case .none:
            break
        case .minimal:
            logger.info("➡️ \(method) \(sanitizedURL)")
        case .verbose:
            logger.info("➡️ \(method) \(sanitizedURL)")
            logRequestHeaders(request)
            logRequestBody(request)
        }
    }

    private func logRequestHeaders(_ request: URLRequest) {
        guard let headers = request.allHTTPHeaderFields, !headers.isEmpty else { return }

        let sanitizedHeaders: [String: String] = sanitization.sanitizeHeaders(headers)
        logger.debug("   Headers: \(sanitizedHeaders)")
    }

    private func logRequestBody(_ request: URLRequest) {
        guard let body = request.httpBody, !body.isEmpty else { return }

        let contentType: String? = request.value(forHTTPHeaderField: "Content-Type")
        if let sanitizedBody = sanitization.sanitizeBody(body, contentType: contentType) {
            logger.debug("   Body: \(sanitizedBody)")
        }
    }

    private func logResponse(_ response: HTTPURLResponse, data: Data) {
        guard level != .none else { return }

        let statusCode: Int = response.statusCode
        let sanitizedURL: String = sanitization.sanitizeURL(response.url)

        switch level {
        case .none:
            break
        case .minimal:
            logger.info("⬅️ \(statusCode) \(sanitizedURL)")
        case .verbose:
            logger.info("⬅️ \(statusCode) \(sanitizedURL)")
            logResponseHeaders(response)
            logResponseBody(response, data: data)
        }
    }

    private func logResponseHeaders(_ response: HTTPURLResponse) {
        let headers: [AnyHashable: Any] = response.allHeaderFields
        guard !headers.isEmpty else { return }

        var headerDict: [String: String] = [:]
        for (key, value) in headers {
            if let keyString = key as? String, let valueString = value as? String {
                headerDict[keyString] = valueString
            }
        }

        let sanitizedHeaders: [String: String] = sanitization.sanitizeHeaders(headerDict)
        logger.debug("   Headers: \(sanitizedHeaders)")
    }

    private func logResponseBody(_ response: HTTPURLResponse, data: Data) {
        guard !data.isEmpty else { return }

        let contentType: String? = response.value(forHTTPHeaderField: "Content-Type")
        if let sanitizedBody = sanitization.sanitizeBody(data, contentType: contentType) {
            logger.debug("   Body: \(sanitizedBody)")
        }
    }
}
