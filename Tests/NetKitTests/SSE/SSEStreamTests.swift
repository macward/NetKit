import Testing
import Foundation
@testable import NetKit

// MARK: - Sample Event & Endpoint

/// An OpenAI-style event used to exercise the stream. It discriminates by `data`
/// content and treats the `[DONE]` sentinel as terminal without decoding JSON.
private enum StreamEvent: SSEDecodableEvent {
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

private struct StreamEndpoint: SSEEndpoint {
    var path: String { "/v1/chat/completions" }
    var method: HTTPMethod { .post }
    typealias Event = StreamEvent
}

// MARK: - Test Helpers

/// A `Sendable` flag used to assert the cancellation hook fired.
private actor CancelSpy {
    private(set) var didCancel: Bool = false

    func markCancelled() {
        didCancel = true
    }

    func wasCancelled() -> Bool {
        didCancel
    }
}

/// Builds a line source that yields the given lines in order, then finishes
/// cleanly (without throwing).
private func makeLineSource(
    _ lines: [String]
) -> @Sendable () -> AsyncThrowingStream<String, any Error> {
    {
        AsyncThrowingStream { continuation in
            for line in lines {
                continuation.yield(line)
            }
            continuation.finish()
        }
    }
}

/// Builds a line source that yields the given lines then finishes with an error,
/// simulating a mid-stream transport cut.
private func makeLineSource(
    _ lines: [String],
    throwing error: any Error
) -> @Sendable () -> AsyncThrowingStream<String, any Error> {
    {
        AsyncThrowingStream { continuation in
            for line in lines {
                continuation.yield(line)
            }
            continuation.finish(throwing: error)
        }
    }
}

// MARK: - SSEStream Tests

@Suite("SSEStream")
struct SSEStreamTests {
    @Test("Delivers typed events incrementally as lines arrive")
    func incrementalDelivery() async throws {
        // Two complete events followed by a terminal sentinel.
        let lines: [String] = [
            "data: {\"text\":\"hello\"}",
            "",
            "data: {\"text\":\"world\"}",
            "",
            "data: [DONE]",
            ""
        ]
        let stream: SSEStream<StreamEndpoint> = SSEStream(lineSource: makeLineSource(lines))

        var received: [String] = []
        for try await event in stream {
            switch event {
            case .chunk(let text):
                received.append(text)
            case .done:
                received.append("DONE")
            }
        }

        #expect(received == ["hello", "world", "DONE"])
    }

    @Test("Terminal event ends iteration without throwing")
    func terminalEventEndsCleanly() async throws {
        let lines: [String] = [
            "data: {\"text\":\"hi\"}",
            "",
            "data: [DONE]",
            ""
        ]
        let stream: SSEStream<StreamEndpoint> = SSEStream(lineSource: makeLineSource(lines))

        var sawTerminal: Bool = false
        // Must not throw even though the source finishes after the terminal.
        for try await event in stream {
            if case .done = event {
                sawTerminal = true
            }
        }

        #expect(sawTerminal)
    }

    @Test("Malformed JSON ends the stream with SSEError.decodingFailed")
    func malformedJSONThrowsDecodingFailed() async {
        let lines: [String] = [
            "data: {\"text\":\"ok\"}",
            "",
            "data: not-json",
            ""
        ]
        let stream: SSEStream<StreamEndpoint> = SSEStream(lineSource: makeLineSource(lines))

        var thrown: (any Error)?
        do {
            for try await _ in stream {}
        } catch {
            thrown = error
        }

        guard let sseError = thrown as? SSEError else {
            Issue.record("Expected SSEError, got \(String(describing: thrown))")
            return
        }
        guard case .decodingFailed = sseError else {
            Issue.record("Expected .decodingFailed, got \(sseError)")
            return
        }
    }

    @Test("Mid-stream cut with no terminal throws unexpectedDisconnect exposing last id")
    func midStreamCutThrowsUnexpectedDisconnect() async {
        // An event with an id, then the source finishes without a terminal.
        let lines: [String] = [
            "id: 42",
            "data: {\"text\":\"partial\"}",
            ""
        ]
        let stream: SSEStream<StreamEndpoint> = SSEStream(lineSource: makeLineSource(lines))

        var thrown: (any Error)?
        do {
            for try await _ in stream {}
        } catch {
            thrown = error
        }

        #expect(thrown as? SSEError == .unexpectedDisconnect(lastEventID: "42"))
    }

    @Test("Source error mid-stream surfaces as unexpectedDisconnect")
    func sourceErrorThrowsUnexpectedDisconnect() async {
        struct TransportError: Error {}
        let lines: [String] = [
            "id: 7",
            "data: {\"text\":\"partial\"}",
            ""
        ]
        let stream: SSEStream<StreamEndpoint> = SSEStream(
            lineSource: makeLineSource(lines, throwing: TransportError())
        )

        var thrown: (any Error)?
        do {
            for try await _ in stream {}
        } catch {
            thrown = error
        }

        #expect(thrown as? SSEError == .unexpectedDisconnect(lastEventID: "7"))
    }

    @Test("Cancelling the consuming task stops iteration and fires the cancellation hook")
    func cancellationFiresHook() async {
        let spy: CancelSpy = CancelSpy()

        // An effectively unbounded, slow source so the consumer is suspended
        // waiting for the next line when we cancel.
        let lineSource: @Sendable () -> AsyncThrowingStream<String, any Error> = {
            AsyncThrowingStream { continuation in
                let task = Task {
                    var index: Int = 0
                    while !Task.isCancelled {
                        continuation.yield("data: {\"text\":\"\(index)\"}")
                        continuation.yield("")
                        index += 1
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        let stream: SSEStream<StreamEndpoint> = SSEStream(
            lineSource: lineSource,
            onCancel: { Task { await spy.markCancelled() } }
        )

        let consumer = Task {
            do {
                for try await _ in stream {
                    // Keep consuming until cancelled.
                }
            } catch {
                // Errors after cancellation are acceptable.
            }
        }

        // Let a few events flow, then cancel.
        try? await Task.sleep(nanoseconds: 120_000_000)
        consumer.cancel()
        _ = await consumer.value

        // Allow the detached hook task to run.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let fired: Bool = await spy.wasCancelled()
        #expect(fired)
    }

    @Test("rawEvents yields raw SSEEvents without typed decoding")
    func rawEventsYieldsRawEvents() async throws {
        let lines: [String] = [
            "event: ping",
            "data: hello",
            "",
            ": keep-alive comment",
            "data: [DONE]",
            ""
        ]
        let stream: SSEStream<StreamEndpoint> = SSEStream(lineSource: makeLineSource(lines))

        var collected: [SSEEvent] = []
        for try await event in stream.rawEvents {
            collected.append(event)
        }

        #expect(collected.count == 2)
        #expect(collected.first?.event == "ping")
        #expect(collected.first?.data == "hello")
        // The [DONE] sentinel is delivered raw, not interpreted as terminal.
        #expect(collected.last?.data == "[DONE]")
    }

    @Test("rawEvents propagates a source error")
    func rawEventsPropagatesError() async {
        struct TransportError: Error {}
        let stream: SSEStream<StreamEndpoint> = SSEStream(
            lineSource: makeLineSource(["data: hi", ""], throwing: TransportError())
        )

        var thrown: (any Error)?
        do {
            for try await _ in stream.rawEvents {}
        } catch {
            thrown = error
        }

        #expect(thrown is TransportError)
    }
}
