import Foundation

// MARK: - Sanitization Configuration

/// Configuration for sanitizing sensitive data in logs and error snapshots.
public struct SanitizationConfig: Sendable, Equatable {
    /// Headers that should have their values redacted.
    public var sensitiveHeaders: Set<String>

    /// Query parameter names that should have their values redacted.
    public var sensitiveQueryParams: Set<String>

    /// JSON body field names that should have their values redacted.
    public var sensitiveBodyFields: Set<String>

    /// The string to replace sensitive values with.
    public var redactionString: String

    /// Maximum body size in bytes to attempt JSON sanitization.
    /// Bodies larger than this will be truncated without parsing.
    public var maxBodySizeForSanitization: Int

    /// Creates a sanitization configuration.
    /// - Parameters:
    ///   - sensitiveHeaders: Header names to redact (case-insensitive).
    ///   - sensitiveQueryParams: Query parameter names to redact (case-insensitive).
    ///   - sensitiveBodyFields: JSON field names to redact (case-sensitive).
    ///   - redactionString: The replacement string for sensitive values.
    ///   - maxBodySizeForSanitization: Max body size for JSON parsing.
    public init(
        sensitiveHeaders: Set<String> = Self.defaultSensitiveHeaders,
        sensitiveQueryParams: Set<String> = Self.defaultSensitiveQueryParams,
        sensitiveBodyFields: Set<String> = Self.defaultSensitiveBodyFields,
        redactionString: String = "[REDACTED]",
        maxBodySizeForSanitization: Int = 10_240
    ) {
        self.sensitiveHeaders = sensitiveHeaders
        self.sensitiveQueryParams = sensitiveQueryParams
        self.sensitiveBodyFields = sensitiveBodyFields
        self.redactionString = redactionString
        self.maxBodySizeForSanitization = maxBodySizeForSanitization
    }

    // MARK: - Default Values

    /// Default set of sensitive header names (lowercase for comparison).
    public static let defaultSensitiveHeaders: Set<String> = [
        "authorization",
        "x-api-key",
        "api-key",
        "x-auth-token",
        "cookie",
        "set-cookie",
        "x-csrf-token",
        "x-xsrf-token",
        "proxy-authorization",
        "x-access-token"
    ]

    /// Default set of sensitive query parameter names (lowercase for comparison).
    public static let defaultSensitiveQueryParams: Set<String> = [
        "token",
        "api_key",
        "apikey",
        "password",
        "secret",
        "access_token",
        "refresh_token",
        "auth",
        "key",
        "credential"
    ]

    /// Default set of sensitive body field names (case-sensitive for JSON).
    public static let defaultSensitiveBodyFields: Set<String> = [
        "password",
        "secret",
        "token",
        "api_key",
        "apiKey",
        "access_token",
        "accessToken",
        "refresh_token",
        "refreshToken",
        "credential",
        "credentials",
        "private_key",
        "privateKey"
    ]

    // MARK: - Presets

    /// Default configuration with all sanitization enabled.
    public static let `default`: SanitizationConfig = SanitizationConfig()

    /// Configuration with no sanitization (for debugging).
    public static let none: SanitizationConfig = SanitizationConfig(
        sensitiveHeaders: [],
        sensitiveQueryParams: [],
        sensitiveBodyFields: [],
        redactionString: "",
        maxBodySizeForSanitization: 0
    )

    /// Strict configuration with additional sensitive fields.
    public static let strict: SanitizationConfig = SanitizationConfig(
        sensitiveHeaders: defaultSensitiveHeaders.union([
            "x-client-secret",
            "x-signature",
            "x-hmac"
        ]),
        sensitiveQueryParams: defaultSensitiveQueryParams.union([
            "signature",
            "sig",
            "hmac"
        ]),
        sensitiveBodyFields: defaultSensitiveBodyFields.union([
            "ssn",
            "socialSecurityNumber",
            "creditCard",
            "credit_card",
            "cardNumber",
            "card_number",
            "cvv",
            "pin"
        ])
    )
}

// MARK: - Sanitization Functions

extension SanitizationConfig {
    /// Sanitizes headers by redacting sensitive values.
    /// - Parameter headers: The original headers dictionary.
    /// - Returns: Headers with sensitive values replaced by redaction string.
    public func sanitizeHeaders(_ headers: [String: String]?) -> [String: String] {
        guard let headers, !sensitiveHeaders.isEmpty else {
            return headers ?? [:]
        }

        var sanitized: [String: String] = [:]
        for (key, value) in headers {
            if sensitiveHeaders.contains(key.lowercased()) {
                sanitized[key] = redactionString
            } else {
                sanitized[key] = value
            }
        }
        return sanitized
    }

    /// Sanitizes a URL by redacting sensitive query parameter values.
    /// - Parameter url: The original URL.
    /// - Returns: URL string with sensitive query params redacted.
    public func sanitizeURL(_ url: URL?) -> String {
        guard let url else { return "nil" }
        guard !sensitiveQueryParams.isEmpty else { return url.absoluteString }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems, !queryItems.isEmpty else {
            return url.absoluteString
        }

        let sanitizedItems: [URLQueryItem] = queryItems.map { item in
            if sensitiveQueryParams.contains(item.name.lowercased()) {
                return URLQueryItem(name: item.name, value: redactionString)
            }
            return item
        }

        components.queryItems = sanitizedItems
        return components.url?.absoluteString ?? url.absoluteString
    }

    /// Sanitizes a JSON body by redacting sensitive field values.
    /// - Parameters:
    ///   - data: The body data.
    ///   - contentType: The Content-Type header value.
    /// - Returns: Sanitized body string, or truncated string if not JSON or too large.
    public func sanitizeBody(_ data: Data?, contentType: String?, maxLength: Int = 1000) -> String? {
        guard let data, !data.isEmpty else { return nil }

        let isJSON: Bool = contentType?.lowercased().contains("application/json") ?? false

        if isJSON && data.count <= maxBodySizeForSanitization && !sensitiveBodyFields.isEmpty {
            if let sanitized = sanitizeJSONBody(data) {
                return truncateString(sanitized, maxLength: maxLength)
            }
        }

        guard let bodyString = String(data: data, encoding: .utf8) else {
            return "<binary data: \(data.count) bytes>"
        }

        return truncateString(bodyString, maxLength: maxLength)
    }

    /// Sanitizes JSON data by redacting sensitive fields recursively.
    private func sanitizeJSONBody(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return String(data: data, encoding: .utf8)
        }

        let sanitized: Any = recursiveSanitize(json)

        guard let sanitizedData = try? JSONSerialization.data(
            withJSONObject: sanitized,
            options: [.sortedKeys]
        ) else {
            return String(data: data, encoding: .utf8)
        }

        return String(data: sanitizedData, encoding: .utf8)
    }

    /// Recursively sanitizes JSON values, handling nested objects and arrays.
    private func recursiveSanitize(_ value: Any) -> Any {
        if var dict = value as? [String: Any] {
            for key in dict.keys {
                if sensitiveBodyFields.contains(key) {
                    dict[key] = redactionString
                } else if let nestedValue = dict[key] {
                    dict[key] = recursiveSanitize(nestedValue)
                }
            }
            return dict
        } else if let array = value as? [Any] {
            return array.map { recursiveSanitize($0) }
        }
        return value
    }

    /// Truncates a string to the specified maximum length.
    private func truncateString(_ string: String, maxLength: Int) -> String {
        if string.count <= maxLength {
            return string
        }
        return String(string.prefix(maxLength)) + "..."
    }
}

// MARK: - Module-Level Function for Backward Compatibility

/// Sanitizes headers using the default configuration.
/// Used by RequestSnapshot and ResponseSnapshot for backward compatibility.
internal func sanitizeHeadersWithDefaultConfig(_ headers: [String: String]?) -> [String: String] {
    SanitizationConfig.default.sanitizeHeaders(headers)
}
