import Testing
import Foundation
@testable import NetKit

// MARK: - Sample Event & Endpoints

/// An OpenAI-style event discriminated by `data`, terminal on `[DONE]`.
private enum ClientStreamEvent: SSEDecodableEvent {
    case chunk(text: String)
    case done

    private struct Payload: Decodable {
        let text: String
    }

    init(eventName: String?, data: String) throws {
        if data == "[DONE]" {
            self = .done
            return
        }
        let decoded: Payload = try JSONDecoder().decode(Payload.self, from: Data(data.utf8))
        self = .chunk(text: decoded.text)
    }

    var isTerminal: Bool {
        if case .done = self { return true }
        return false
    }
}

private struct ClientStreamEndpoint: SSEEndpoint {
    var path: String { "/v1/chat/stream" }
    var method: HTTPMethod { .post }
    typealias Event = ClientStreamEvent
}

private struct ClientStreamEnvironment: NetworkEnvironment {
    var baseURL: URL = URL(string: "https://api.example.com")!
    var defaultHeaders: [String: String] = [:]
    var timeout: TimeInterval = 1
}

// MARK: - Capturing Mock URLProtocol

/// Captures the outgoing request and returns a fixed SSE body. Used to assert
/// header injection and to count how many transport hits occur.
private final class StreamCapturingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body: Data = Data()
    nonisolated(unsafe) static var statusCode: Int = 200
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) static var hitCount: Int = 0
    nonisolated(unsafe) static var lock = NSLock()

    static func reset(body: String, statusCode: Int = 200) {
        lock.lock()
        self.body = Data(body.utf8)
        self.statusCode = statusCode
        capturedRequests = []
        hitCount = 0
        lock.unlock()
    }

    static var captured: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    static var hits: Int {
        lock.lock()
        defer { lock.unlock() }
        return hitCount
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        StreamCapturingURLProtocol.lock.lock()
        StreamCapturingURLProtocol.capturedRequests.append(request)
        StreamCapturingURLProtocol.hitCount += 1
        let data: Data = StreamCapturingURLProtocol.body
        let code: Int = StreamCapturingURLProtocol.statusCode
        StreamCapturingURLProtocol.lock.unlock()

        let response: HTTPURLResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Response-interceptor spy

/// Records every `intercept(response:data:)` call so tests can assert the
/// response interceptor chain runs on a stream connection.
private actor ResponseInterceptorSpy: Interceptor {
    private var _calls: [(statusCode: Int, dataLength: Int)] = []

    var calls: [(statusCode: Int, dataLength: Int)] { _calls }

    nonisolated func intercept(request: URLRequest) async throws -> URLRequest { request }

    func intercept(response: HTTPURLResponse, data: Data) async throws -> Data {
        _calls.append((statusCode: response.statusCode, dataLength: data.count))
        return data
    }
}

// MARK: - Tests

@Suite("SSE Client Stream", .serialized)
struct SSEClientStreamTests {
    // Each SSE event is terminated by a blank line (`\n\n`), including the
    // final terminal event. Building the body with explicit terminators avoids
    // the triple-quoted-literal pitfall where the closing delimiter swallows the
    // last newline, leaving the terminal event undispatched.
    private static let sseBody: String =
        "data: {\"text\":\"hello\"}\n\n" +
        "data: {\"text\":\"world\"}\n\n" +
        "data: [DONE]\n\n"

    private func makeSession() -> URLSession {
        let config: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamCapturingURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("client.stream yields typed events consumable with for try await")
    func streamYieldsTypedEvents() async throws {
        StreamCapturingURLProtocol.reset(body: Self.sseBody)
        let client: NetworkClient = NetworkClient(
            environment: ClientStreamEnvironment(),
            session: makeSession()
        )

        var received: [String] = []
        for try await event in client.stream(ClientStreamEndpoint()) {
            switch event {
            case .chunk(let text):
                received.append(text)
            case .done:
                received.append("DONE")
            }
        }

        #expect(received == ["hello", "world", "DONE"])
    }

    @Test("Outgoing request has Accept: text/event-stream and AuthInterceptor Bearer")
    func injectsAcceptAndBearer() async throws {
        StreamCapturingURLProtocol.reset(body: Self.sseBody)
        let auth: AuthInterceptor = AuthInterceptor(tokenProvider: { "secret-token" })
        let client: NetworkClient = NetworkClient(
            environment: ClientStreamEnvironment(),
            interceptors: [auth],
            session: makeSession()
        )

        // Consume fully so the request actually goes out.
        for try await _ in client.stream(ClientStreamEndpoint()) {}

        let captured: [URLRequest] = StreamCapturingURLProtocol.captured
        #expect(captured.count == 1)
        let request: URLRequest = try #require(captured.first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    }

    @Test("Stream bypasses cache and deduplication: concurrent identical streams both hit transport")
    func bypassesCacheAndDeduplication() async throws {
        StreamCapturingURLProtocol.reset(body: Self.sseBody)
        // Provide a real cache; a cached/deduped path would coalesce or short-circuit.
        let cache: ResponseCache = ResponseCache()
        let client: NetworkClient = NetworkClient(
            environment: ClientStreamEnvironment(),
            cache: cache,
            session: makeSession()
        )

        // Run two identical streams concurrently and fully consume both.
        async let first: Int = consumeCount(client.stream(ClientStreamEndpoint()))
        async let second: Int = consumeCount(client.stream(ClientStreamEndpoint()))
        let counts: (Int, Int) = try await (first, second)

        // Both streams delivered events (no error/short-circuit).
        #expect(counts.0 == 3)
        #expect(counts.1 == 3)
        // No coalescing: the transport was hit once per stream.
        #expect(StreamCapturingURLProtocol.hits == 2)
    }

    @Test("Non-2xx HTTP status throws NetworkError before any events are emitted")
    func nonSuccessStatusThrows() async throws {
        StreamCapturingURLProtocol.reset(body: "", statusCode: 401)
        let client: NetworkClient = NetworkClient(
            environment: ClientStreamEnvironment(),
            session: makeSession()
        )

        await #expect(throws: NetworkError.self) {
            for try await _ in client.stream(ClientStreamEndpoint()) {}
        }
    }

    @Test("Response interceptors are invoked with the initial HTTP response")
    func responseInterceptorsAreInvoked() async throws {
        StreamCapturingURLProtocol.reset(body: Self.sseBody)
        let spy: ResponseInterceptorSpy = ResponseInterceptorSpy()
        let client: NetworkClient = NetworkClient(
            environment: ClientStreamEnvironment(),
            interceptors: [spy],
            session: makeSession()
        )

        for try await _ in client.stream(ClientStreamEndpoint()) {}

        let calls: [(statusCode: Int, dataLength: Int)] = await spy.calls
        #expect(calls.count == 1)
        #expect(calls.first?.statusCode == 200)
    }

    private func consumeCount(_ stream: SSEStream<ClientStreamEndpoint>) async throws -> Int {
        var count: Int = 0
        for try await _ in stream {
            count += 1
        }
        return count
    }
}
