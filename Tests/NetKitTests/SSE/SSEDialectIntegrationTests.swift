import Testing
import Foundation
@testable import NetKit

// MARK: - Endpoints (per dialect)

/// An OpenAI-style streaming endpoint wired to the ``OpenAIStreamEvent`` preset.
private struct OpenAIChatStreamEndpoint: SSEEndpoint {
    var path: String { "/v1/chat/completions" }
    var method: HTTPMethod { .post }
    typealias Event = OpenAIStreamEvent
}

/// An Anthropic-style streaming endpoint wired to the ``AnthropicStreamEvent``
/// preset (discriminated by `event:` name).
private struct AnthropicMessagesStreamEndpoint: SSEEndpoint {
    var path: String { "/v1/messages" }
    var method: HTTPMethod { .post }
    typealias Event = AnthropicStreamEvent
}

private struct DialectEnvironment: NetworkEnvironment {
    var baseURL: URL = URL(string: "https://api.example.com")!
    var defaultHeaders: [String: String] = [:]
    var timeout: TimeInterval = 2
}

// MARK: - Chunked Mock URLProtocol

/// A controlled byte source that delivers an SSE body in *chunks* (one
/// `didLoad` per chunk) so a single logical event can be fragmented across
/// several transport packets. It can also serve a never-ending body and record
/// `stopLoading`, letting cancellation cut the request observably.
///
/// This is the integration-test transport: it exercises the real
/// `client.stream` path (byte transport → line splitter → parser →
/// discriminator → `SSEStream`) end-to-end without a server.
private final class ChunkedSSEURLProtocol: URLProtocol, @unchecked Sendable {
    /// The ordered chunks to deliver, each via its own `didLoad`.
    nonisolated(unsafe) static var chunks: [Data] = []
    /// When `true`, the body never finishes (used to test cancellation). The
    /// chunks are still delivered, then loading hangs until `stopLoading`.
    nonisolated(unsafe) static var neverEnds: Bool = false
    /// Set to `true` once `stopLoading` runs, proving the request was cut.
    nonisolated(unsafe) static var stopWasCalled: Bool = false
    nonisolated(unsafe) static var lock: NSLock = NSLock()

    static func reset(chunks: [String], neverEnds: Bool = false) {
        lock.withLock {
            self.chunks = chunks.map { Data($0.utf8) }
            self.neverEnds = neverEnds
            self.stopWasCalled = false
        }
    }

    static var didStop: Bool {
        lock.withLock { stopWasCalled }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let (chunks, neverEnds): ([Data], Bool) = ChunkedSSEURLProtocol.lock.withLock {
            (ChunkedSSEURLProtocol.chunks, ChunkedSSEURLProtocol.neverEnds)
        }

        let response: HTTPURLResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        // Deliver each chunk as a separate packet so a single SSE event can be
        // split across multiple `didLoad` calls (fragmentation).
        for chunk in chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }

        if neverEnds {
            // Return WITHOUT finishing so the connection stays open. The protocol
            // remains "loading" until the task is cancelled, which triggers
            // `stopLoading`. The thread is not blocked, so that callback is free
            // to run.
            return
        }

        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        ChunkedSSEURLProtocol.lock.withLock {
            ChunkedSSEURLProtocol.stopWasCalled = true
        }
    }
}

// MARK: - Tests

@Suite("SSE Dialect Integration", .serialized)
struct SSEDialectIntegrationTests {
    private func makeSession() -> URLSession {
        let config: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChunkedSSEURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(interceptors: [any Interceptor] = []) -> NetworkClient {
        NetworkClient(
            environment: DialectEnvironment(),
            interceptors: interceptors,
            session: makeSession()
        )
    }

    // MARK: R1, R6 — OpenAI dialect end-to-end

    @Test("OpenAI: incremental typed deltas then [DONE] closes the loop cleanly")
    func openAIIncrementalDeltasThenDone() async throws {
        // One `data:` JSON fragment per event, terminated by the `[DONE]`
        // sentinel. Each event is delimited by a blank line (`\n\n`).
        let body: String =
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" +
            "data: {\"choices\":[{\"delta\":{\"content\":\", \"}}]}\n\n" +
            "data: {\"choices\":[{\"delta\":{\"content\":\"world\"}}]}\n\n" +
            "data: [DONE]\n\n"
        ChunkedSSEURLProtocol.reset(chunks: [body])

        let client: NetworkClient = makeClient()

        var contents: [String] = []
        var sawDone: Bool = false
        for try await event in client.stream(OpenAIChatStreamEndpoint()) {
            switch event {
            case .delta(let delta):
                if let text: String = delta.choices.first?.delta.content {
                    contents.append(text)
                }
            case .done:
                sawDone = true
            }
        }

        // Incremental, in-order delivery of typed deltas, then a clean close.
        #expect(contents == ["Hello", ", ", "world"])
        #expect(sawDone)
    }

    // MARK: R7 — Anthropic dialect end-to-end (discrimination by name)

    @Test("Anthropic: content_block_delta discriminated by name, message_stop ends the stream")
    func anthropicNamedEventsThenStop() async throws {
        let body: String =
            "event: message_start\ndata: {}\n\n" +
            "event: content_block_delta\ndata: {\"delta\":{\"text\":\"Hi\"}}\n\n" +
            "event: content_block_delta\ndata: {\"delta\":{\"text\":\" there\"}}\n\n" +
            "event: message_stop\ndata: {}\n\n"
        ChunkedSSEURLProtocol.reset(chunks: [body])

        let client: NetworkClient = makeClient()

        var texts: [String] = []
        var sawStart: Bool = false
        var sawStop: Bool = false
        for try await event in client.stream(AnthropicMessagesStreamEndpoint()) {
            switch event {
            case .messageStart:
                sawStart = true
            case .contentBlockDelta(let delta):
                texts.append(delta.delta.text)
            case .messageStop:
                sawStop = true
            case .unknown:
                break
            }
        }

        #expect(sawStart)
        #expect(texts == ["Hi", " there"])
        #expect(sawStop)
    }

    // MARK: R4, R5 — keep-alive ignored + fragmentation reassembled

    @Test("Keep-alive comments are ignored and a fragmented event is reassembled")
    func keepAliveIgnoredAndFragmentReassembled() async throws {
        // A single logical OpenAI event whose bytes are split across several
        // transport packets, interleaved with `:`-comment keep-alive lines.
        // Reassembly must produce exactly ONE delta, then close on [DONE].
        let chunks: [String] = [
            ": keep-alive\n",                            // comment only
            "data: {\"choices\":[{\"delta\":",           // start of the event
            "{\"content\":\"frag",                        // mid-payload split
            "mented\"}}]}",                               // rest of payload
            "\n\n",                                       // event delimiter
            ": still alive\n",                           // another keep-alive
            "data: [DONE]\n\n"                            // terminal
        ]
        ChunkedSSEURLProtocol.reset(chunks: chunks)

        let client: NetworkClient = makeClient()

        var contents: [String] = []
        var sawDone: Bool = false
        for try await event in client.stream(OpenAIChatStreamEndpoint()) {
            switch event {
            case .delta(let delta):
                if let text: String = delta.choices.first?.delta.content {
                    contents.append(text)
                }
            case .done:
                sawDone = true
            }
        }

        // Exactly one event reassembled from the fragments; comments ignored.
        #expect(contents == ["fragmented"])
        #expect(sawDone)
    }

    // MARK: R8 — malformed JSON surfaces as an error

    @Test("Malformed JSON ends the stream with a decodingFailed error")
    func malformedJSONThrows() async throws {
        let body: String =
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n" +
            "data: {not valid json}\n\n" +
            "data: [DONE]\n\n"
        ChunkedSSEURLProtocol.reset(chunks: [body])

        let client: NetworkClient = makeClient()

        var contents: [String] = []
        var thrown: (any Error)?
        do {
            for try await event in client.stream(OpenAIChatStreamEndpoint()) {
                if case .delta(let delta) = event,
                   let text: String = delta.choices.first?.delta.content {
                    contents.append(text)
                }
            }
        } catch {
            thrown = error
        }

        // The valid event before the corruption is delivered, then the bad
        // payload aborts the stream with a decoding error.
        #expect(contents == ["ok"])
        let error: any Error = try #require(thrown)
        guard case .decodingFailed = (error as? SSEError) else {
            Issue.record("Expected SSEError.decodingFailed, got \(error)")
            return
        }
    }

    // MARK: R9 — cancellation cuts the request

    @Test("Cancelling the consuming task cuts the underlying request")
    func cancellationCutsRequest() async throws {
        // A never-ending body: one event arrives, then the connection hangs.
        // Cancelling the task must stop iteration and trigger stopLoading.
        ChunkedSSEURLProtocol.reset(
            chunks: ["data: {\"choices\":[{\"delta\":{\"content\":\"first\"}}]}\n\n"],
            neverEnds: true
        )

        let client: NetworkClient = makeClient()
        let firstReceived: SendableBox = SendableBox()

        let task: Task<Void, any Error> = Task {
            for try await event in client.stream(OpenAIChatStreamEndpoint()) {
                if case .delta = event {
                    firstReceived.signal()
                }
            }
        }

        // Wait until the first event has been delivered before cancelling, so we
        // know the connection is genuinely open and hanging.
        try await firstReceived.wait()
        task.cancel()

        // Iteration must stop (the task completes rather than hanging forever).
        _ = await task.result

        // The transport observed the cut.
        try await waitUntil { ChunkedSSEURLProtocol.didStop }
        #expect(ChunkedSSEURLProtocol.didStop)
    }

    // MARK: - Helpers

    /// Polls a condition until it holds or a generous timeout elapses.
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @Sendable () -> Bool
    ) async throws {
        let deadline: Date = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - SendableBox

/// A tiny one-shot signal used to await the first delivered event before
/// cancelling, without races on a plain Bool.
private final class SendableBox: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var signalled: Bool = false

    func signal() {
        lock.withLock { signalled = true }
    }

    func wait(timeout: TimeInterval = 2) async throws {
        let deadline: Date = Date().addingTimeInterval(timeout)
        while true {
            let done: Bool = lock.withLock { signalled }
            if done { return }
            if Date() > deadline { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
