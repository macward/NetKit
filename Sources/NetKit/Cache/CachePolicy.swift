import Foundation

// MARK: - Cache Policy Protocol

/// Defines caching behavior for HTTP responses.
public protocol CachePolicy: Sendable {
    /// Determines if a response should be cached.
    func shouldCache(response: HTTPURLResponse) -> Bool

    /// Calculates the TTL for a cached response.
    func ttl(for response: HTTPURLResponse) -> TimeInterval?

    /// Determines if a cached entry should be revalidated.
    func shouldRevalidate(entry: CacheMetadata) -> Bool
}

// MARK: - Cache Metadata

/// Metadata stored alongside cached responses for validation and expiration.
public struct CacheMetadata: Sendable, Codable {
    /// The ETag value from the response, if present.
    public let etag: String?

    /// The Last-Modified date from the response, if present.
    public let lastModified: String?

    /// When the cache entry was created.
    public let cachedAt: Date

    /// When the cache entry expires based on headers.
    public let expiresAt: Date?

    /// The parsed Cache-Control directives.
    public let cacheControl: CacheControlDirective?

    /// Whether this entry requires revalidation before use.
    public var requiresRevalidation: Bool {
        guard let cacheControl else { return false }
        return cacheControl.noCache || cacheControl.mustRevalidate
    }

    /// Whether the entry has expired.
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() > expiresAt
    }

    /// Whether the entry is stale but potentially usable for stale-while-revalidate.
    public func isStaleButRevalidatable(within window: TimeInterval) -> Bool {
        guard let expiresAt else { return false }
        let staleDeadline: Date = expiresAt.addingTimeInterval(window)
        return Date() > expiresAt && Date() <= staleDeadline
    }

    public init(
        etag: String? = nil,
        lastModified: String? = nil,
        cachedAt: Date = Date(),
        expiresAt: Date? = nil,
        cacheControl: CacheControlDirective? = nil
    ) {
        self.etag = etag
        self.lastModified = lastModified
        self.cachedAt = cachedAt
        self.expiresAt = expiresAt
        self.cacheControl = cacheControl
    }
}

// MARK: - Cache Control Directive

/// Parsed representation of the Cache-Control HTTP header.
public struct CacheControlDirective: Sendable, Codable, Equatable {
    /// max-age directive value in seconds.
    public let maxAge: TimeInterval?

    /// s-maxage directive for shared caches (not typically used in clients).
    public let sharedMaxAge: TimeInterval?

    /// no-cache: Response can be stored but must be revalidated before use.
    public let noCache: Bool

    /// no-store: Response must not be stored in any cache.
    public let noStore: Bool

    /// private: Response is intended for a single user.
    public let isPrivate: Bool

    /// public: Response can be stored by any cache.
    public let isPublic: Bool

    /// must-revalidate: Stale responses must not be used without revalidation.
    public let mustRevalidate: Bool

    /// stale-while-revalidate: Time window to serve stale content while revalidating.
    public let staleWhileRevalidate: TimeInterval?

    /// stale-if-error: Time window to serve stale content if revalidation fails.
    public let staleIfError: TimeInterval?

    /// immutable: Response will not change during its freshness lifetime.
    public let immutable: Bool

    public init(
        maxAge: TimeInterval? = nil,
        sharedMaxAge: TimeInterval? = nil,
        noCache: Bool = false,
        noStore: Bool = false,
        isPrivate: Bool = false,
        isPublic: Bool = false,
        mustRevalidate: Bool = false,
        staleWhileRevalidate: TimeInterval? = nil,
        staleIfError: TimeInterval? = nil,
        immutable: Bool = false
    ) {
        self.maxAge = maxAge
        self.sharedMaxAge = sharedMaxAge
        self.noCache = noCache
        self.noStore = noStore
        self.isPrivate = isPrivate
        self.isPublic = isPublic
        self.mustRevalidate = mustRevalidate
        self.staleWhileRevalidate = staleWhileRevalidate
        self.staleIfError = staleIfError
        self.immutable = immutable
    }
}

// MARK: - Cache Control Parser

/// Parses Cache-Control header values into structured directives.
public enum CacheControlParser {
    /// Parses a Cache-Control header string into a directive struct.
    /// - Parameter headerValue: The raw Cache-Control header value.
    /// - Returns: Parsed directives, or nil if the header is empty or invalid.
    public static func parse(_ headerValue: String?) -> CacheControlDirective? {
        guard let headerValue, !headerValue.isEmpty else { return nil }

        var maxAge: TimeInterval?
        var sharedMaxAge: TimeInterval?
        var noCache: Bool = false
        var noStore: Bool = false
        var isPrivate: Bool = false
        var isPublic: Bool = false
        var mustRevalidate: Bool = false
        var staleWhileRevalidate: TimeInterval?
        var staleIfError: TimeInterval?
        var immutable: Bool = false

        let directives: [String] = headerValue
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        for directive in directives {
            if directive == "no-cache" {
                noCache = true
            } else if directive == "no-store" {
                noStore = true
            } else if directive == "private" {
                isPrivate = true
            } else if directive == "public" {
                isPublic = true
            } else if directive == "must-revalidate" {
                mustRevalidate = true
            } else if directive == "immutable" {
                immutable = true
            } else if directive.hasPrefix("max-age=") {
                maxAge = parseSeconds(from: directive)
            } else if directive.hasPrefix("s-maxage=") {
                sharedMaxAge = parseSeconds(from: directive)
            } else if directive.hasPrefix("stale-while-revalidate=") {
                staleWhileRevalidate = parseSeconds(from: directive)
            } else if directive.hasPrefix("stale-if-error=") {
                staleIfError = parseSeconds(from: directive)
            }
        }

        return CacheControlDirective(
            maxAge: maxAge,
            sharedMaxAge: sharedMaxAge,
            noCache: noCache,
            noStore: noStore,
            isPrivate: isPrivate,
            isPublic: isPublic,
            mustRevalidate: mustRevalidate,
            staleWhileRevalidate: staleWhileRevalidate,
            staleIfError: staleIfError,
            immutable: immutable
        )
    }

    private static func parseSeconds(from directive: String) -> TimeInterval? {
        let parts: [Substring] = directive.split(separator: "=")
        guard parts.count == 2,
              let seconds = TimeInterval(parts[1]) else {
            return nil
        }
        return seconds
    }
}

// MARK: - HTTP Date Parser

/// Parses HTTP date formats (RFC 7231).
/// Creates new DateFormatter instances per call for thread safety in concurrent contexts.
public enum HTTPDateParser {
    private static func makeRFC1123Formatter() -> DateFormatter {
        let formatter: DateFormatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }

    private static func makeRFC850Formatter() -> DateFormatter {
        let formatter: DateFormatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEEE, dd-MMM-yy HH:mm:ss zzz"
        return formatter
    }

    private static func makeAsctimeFormatter() -> DateFormatter {
        let formatter: DateFormatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }

    /// Parses an HTTP date string into a Date.
    /// Supports RFC 1123, RFC 850, and asctime formats.
    public static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }

        if let date = makeRFC1123Formatter().date(from: string) {
            return date
        }
        if let date = makeRFC850Formatter().date(from: string) {
            return date
        }
        if let date = makeAsctimeFormatter().date(from: string) {
            return date
        }
        return nil
    }

    /// Formats a Date as an HTTP date string (RFC 1123).
    public static func format(_ date: Date) -> String {
        makeRFC1123Formatter().string(from: date)
    }
}

// MARK: - Default Cache Policy

/// Default HTTP cache policy that respects standard cache headers.
public struct HTTPCachePolicy: CachePolicy {
    /// Default TTL when no cache headers are present.
    public let defaultTTL: TimeInterval

    /// Creates an HTTP cache policy.
    /// - Parameter defaultTTL: Fallback TTL when no cache headers exist. Defaults to 0 (no caching).
    public init(defaultTTL: TimeInterval = 0) {
        self.defaultTTL = defaultTTL
    }

    public func shouldCache(response: HTTPURLResponse) -> Bool {
        let cacheControl: CacheControlDirective? = CacheControlParser.parse(
            response.value(forHTTPHeaderField: "Cache-Control")
        )

        if let cacheControl {
            if cacheControl.noStore {
                return false
            }
        }

        let statusCode: Int = response.statusCode
        // Cacheable status codes per RFC 7231 Section 6.1 and RFC 7234 Section 3.
        // These are codes where caching is meaningful and safe by default.
        let cacheableStatusCodes: Set<Int> = [200, 203, 204, 206, 300, 301, 308, 404, 405, 410, 414, 501]
        return cacheableStatusCodes.contains(statusCode)
    }

    public func ttl(for response: HTTPURLResponse) -> TimeInterval? {
        let cacheControl: CacheControlDirective? = CacheControlParser.parse(
            response.value(forHTTPHeaderField: "Cache-Control")
        )

        if let maxAge = cacheControl?.maxAge {
            return maxAge
        }

        if let expiresString = response.value(forHTTPHeaderField: "Expires"),
           let expiresDate = HTTPDateParser.parse(expiresString) {
            let ttl: TimeInterval = expiresDate.timeIntervalSinceNow
            return max(0, ttl)
        }

        return defaultTTL > 0 ? defaultTTL : nil
    }

    public func shouldRevalidate(entry: CacheMetadata) -> Bool {
        if entry.requiresRevalidation {
            return true
        }
        return entry.isExpired
    }
}

// MARK: - Cache Metadata Factory

/// Factory for creating cache metadata from HTTP responses.
public enum CacheMetadataFactory {
    /// Creates cache metadata from an HTTP response.
    public static func create(from response: HTTPURLResponse, policy: CachePolicy) -> CacheMetadata {
        let etag: String? = response.value(forHTTPHeaderField: "ETag")
        let lastModified: String? = response.value(forHTTPHeaderField: "Last-Modified")
        let cacheControl: CacheControlDirective? = CacheControlParser.parse(
            response.value(forHTTPHeaderField: "Cache-Control")
        )

        let ttl: TimeInterval? = policy.ttl(for: response)
        let expiresAt: Date? = ttl.map { Date().addingTimeInterval($0) }

        return CacheMetadata(
            etag: etag,
            lastModified: lastModified,
            cachedAt: Date(),
            expiresAt: expiresAt,
            cacheControl: cacheControl
        )
    }
}
