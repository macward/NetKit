import Foundation

extension URLRequest {
    /// Creates a URLRequest from an endpoint and environment.
    /// - Parameters:
    ///   - endpoint: The endpoint defining the request.
    ///   - environment: The environment providing base URL and defaults.
    ///   - additionalHeaders: Extra headers to merge (highest priority).
    ///   - timeoutOverride: Optional timeout override.
    ///   - encoder: The JSON encoder for body encoding.
    /// - Throws: `NetworkError.invalidURL` if URL construction fails,
    ///           `NetworkError.encodingError` if body encoding fails.
    public init<E: Endpoint>(
        endpoint: E,
        environment: NetworkEnvironment,
        additionalHeaders: [String: String] = [:],
        timeoutOverride: TimeInterval? = nil,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        // Build URL with path
        let url = try Self.buildURL(
            base: environment.baseURL,
            path: endpoint.path,
            queryParameters: endpoint.queryParameters
        )

        self.init(url: url)

        // Set HTTP method
        self.httpMethod = endpoint.method.rawValue

        // Set timeout
        self.timeoutInterval = timeoutOverride ?? environment.timeout

        // Merge headers: environment defaults < endpoint headers < additional headers
        var mergedHeaders = environment.defaultHeaders
        for (key, value) in endpoint.headers {
            mergedHeaders[key] = value
        }
        for (key, value) in additionalHeaders {
            mergedHeaders[key] = value
        }

        for (key, value) in mergedHeaders {
            self.setValue(value, forHTTPHeaderField: key)
        }

        // Encode body if present
        if let body = endpoint.body {
            do {
                self.httpBody = try Self.encodeBody(body, encoder: encoder)
                // Set Content-Type if not already set
                if self.value(forHTTPHeaderField: "Content-Type") == nil {
                    self.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            } catch {
                throw NetworkError.encodingError(error)
            }
        }
    }

    /// Builds a URL from base URL, path, and query parameters.
    private static func buildURL(
        base: URL,
        path: String,
        queryParameters: [String: String]
    ) throws -> URL {
        // Append path to base URL
        var url = base.appendingPathComponent(path)

        // Add query parameters if present
        if !queryParameters.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
                throw NetworkError.invalidURL
            }

            components.queryItems = queryParameters.map { key, value in
                URLQueryItem(name: key, value: value)
            }

            guard let finalURL = components.url else {
                throw NetworkError.invalidURL
            }
            url = finalURL
        }

        return url
    }

    /// Encodes an Encodable body to Data.
    private static func encodeBody(_ body: any Encodable, encoder: JSONEncoder) throws -> Data {
        try encoder.encode(AnyEncodable(body))
    }
}

/// Type-erased Encodable wrapper.
private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        self._encode = { encoder in
            try value.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
