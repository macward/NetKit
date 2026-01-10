import Foundation
import OSLog

/// An interceptor that logs network requests and responses.
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

    /// Creates a logging interceptor.
    /// - Parameters:
    ///   - level: The logging detail level. Defaults to `.minimal`.
    ///   - subsystem: The subsystem for OSLog. Defaults to bundle identifier.
    ///   - category: The category for OSLog. Defaults to "NetKit".
    public init(
        level: LogLevel = .minimal,
        subsystem: String = Bundle.main.bundleIdentifier ?? "NetKit",
        category: String = "NetKit"
    ) {
        self.level = level
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

    private func logRequest(_ request: URLRequest) {
        guard level != .none else { return }

        let method = request.httpMethod ?? "UNKNOWN"
        let url = request.url?.absoluteString ?? "nil"

        switch level {
        case .none:
            break
        case .minimal:
            logger.info("➡️ \(method) \(url)")
        case .verbose:
            logger.info("➡️ \(method) \(url)")
            if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
                logger.debug("   Headers: \(headers)")
            }
            if let body = request.httpBody, let bodyString = String(data: body, encoding: .utf8) {
                logger.debug("   Body: \(bodyString)")
            }
        }
    }

    private func logResponse(_ response: HTTPURLResponse, data: Data) {
        guard level != .none else { return }

        let statusCode = response.statusCode
        let url = response.url?.absoluteString ?? "nil"

        switch level {
        case .none:
            break
        case .minimal:
            logger.info("⬅️ \(statusCode) \(url)")
        case .verbose:
            logger.info("⬅️ \(statusCode) \(url)")
            let headers = response.allHeaderFields
            if !headers.isEmpty {
                logger.debug("   Headers: \(headers)")
            }
            if let bodyString = String(data: data, encoding: .utf8) {
                let truncated = bodyString.prefix(1000)
                logger.debug("   Body: \(truncated)\(bodyString.count > 1000 ? "..." : "")")
            }
        }
    }
}
