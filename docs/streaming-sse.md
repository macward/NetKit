# SSE Streaming

NetKit supports Server-Sent Events (SSE) for consuming real-time, incremental text streams —
the protocol used by OpenAI, Anthropic, and most LLM APIs. A single persistent HTTP connection
delivers typed events as they arrive, with the full NetKit request pipeline (auth interceptors,
certificate pinning, custom environments) applying transparently.

## Define an SSE Endpoint

Implement `SSEEndpoint` and declare an associated `Event` type that knows how to discriminate
raw wire events into typed cases:

```swift
struct ChatStreamEndpoint: SSEEndpoint {
    let prompt: String

    var path: String { "/v1/chat/completions" }
    var method: HTTPMethod { .post }
    var body: Encodable? { ChatRequest(prompt: prompt) }

    typealias Event = OpenAIStreamEvent   // built-in preset, or your own type
}
```

`SSEEndpoint` refines `Endpoint`. Its `Response` associated type defaults to `EmptyResponse` —
you do not decode a single response body; instead, you iterate events.

## Consume the Stream

```swift
let stream = client.stream(ChatStreamEndpoint(prompt: "Hello"))

for try await event in stream {
    switch event {
    case .delta(let delta):
        print(delta.choices.first?.delta.content ?? "")
    case .done:
        break
    }
}
```

The loop ends when:
- The discriminator produces a terminal event (`isTerminal == true`) — that event is delivered
  as the last element, then iteration returns `nil`.
- The consuming task is cancelled.
- The transport closes cleanly after a terminal event.

It throws:
- `SSEError.decodingFailed` — discriminator `init` threw.
- `SSEError.unexpectedDisconnect(lastEventID:)` — transport ended before a terminal event.
- Any `NetworkError` from the response interceptor chain (e.g. `401`, `403`).

## Write a Discriminator (`SSEDecodableEvent`)

The `Event` type bridges the wire format to Swift cases. It receives the raw `event:` name and
`data:` payload and must produce a typed value or throw:

```swift
enum ChatEvent: SSEDecodableEvent {
    case delta(String)
    case done

    init(eventName: String?, data: String) throws {
        if data == "[DONE]" { self = .done; return }
        // decode JSON, map to case…
        self = .delta(data)
    }

    var isTerminal: Bool { self == .done }
}
```

## Built-in Dialect Presets

Two presets ship out of the box as transport models (not SDKs — no session, accumulator, or
tool-calling logic):

### OpenAI

```swift
struct MyChatEndpoint: SSEEndpoint {
    typealias Event = OpenAIStreamEvent
    // …
}

for try await event in client.stream(MyChatEndpoint()) {
    if case .delta(let d) = event {
        print(d.choices.first?.delta.content ?? "")
    }
}
// .done is terminal — loop ends automatically
```

`OpenAIStreamEvent` discriminates by `data` content. `[DONE]` maps to `.done` (terminal)
without any JSON decode; everything else is decoded as `OpenAIDelta` into `.delta(_:)`.

### Anthropic

```swift
struct ClaudeEndpoint: SSEEndpoint {
    typealias Event = AnthropicStreamEvent
    // …
}

for try await event in client.stream(ClaudeEndpoint()) {
    if case .contentBlockDelta(let d) = event {
        print(d.delta.text)
    }
}
// .messageStop is terminal — loop ends automatically
```

`AnthropicStreamEvent` discriminates by `event:` name. Unknown names map to `.unknown(name:)`
rather than throwing, keeping the stream alive as the API adds new lifecycle events.

## Configuration

```swift
// Default: 3600 s timeout (suitable for long-running LLM responses)
let stream = client.stream(endpoint)

// Custom timeout
let stream = client.stream(endpoint, configuration: .init(timeout: 120))
```

## Raw Events

Access the untyped wire events for debugging or custom post-processing:

```swift
for try await raw in client.stream(endpoint).rawEvents {
    print(raw.event ?? "unnamed", raw.data)
}
```

`rawEvents` opens a **new connection** — do not access it while a typed `for try await` over
the same `SSEStream` is active.

## Cancellation

The stream respects Swift structured concurrency. Cancel the task to cut the connection:

```swift
let task = Task {
    for try await event in client.stream(endpoint) {
        handle(event)
    }
}

task.cancel()   // closes the underlying HTTP connection immediately
```

Breaking out of the loop early also cleans up the connection:

```swift
for try await event in client.stream(endpoint) {
    if isFinished(event) { break }   // connection is cancelled on break
}
```

## Error Handling

```swift
do {
    for try await event in client.stream(endpoint) {
        handle(event)
    }
} catch SSEError.unexpectedDisconnect(let lastID) {
    // server closed before a terminal event — reconnect using lastID
    reconnect(after: lastID)
} catch SSEError.decodingFailed(let description) {
    // discriminator threw — log and skip or abort
    logger.error("SSE decode error: \(description)")
} catch let error as NetworkError {
    // HTTP-level error (401, 500, …) from the response interceptor chain
    handle(error)
}
```

## Testing

Use `MockNetworkClient` to test stream consumers without a real server:

```swift
// Elements mode: fast path for consumer logic, bypasses parser
await mock.stubStream(ChatStreamEndpoint.self, events: [
    .delta(OpenAIDelta(choices: [.init(delta: .init(content: "Hi"))])),
    .done
])

// Lines mode: exercises the real parser, terminal, and disconnect semantics
await mock.stubStreamLines(ChatStreamEndpoint.self, lines: [
    "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}",
    "",
    "data: [DONE]",
    ""
])
```

See [Testing](testing.md) for the full difference between the two modes.
