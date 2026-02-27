# Long Polling

NetKit supports long polling for real-time updates. Long polling keeps a connection open until the server has data to send or a timeout occurs.

## Define a Long Polling Endpoint

```swift
struct MessagesEndpoint: LongPollingEndpoint {
    var path: String { "/messages/poll" }
    var method: HTTPMethod { .get }

    // Optional: customize polling behavior
    var pollingTimeout: TimeInterval { 30 }  // Default: 30s
    var retryInterval: TimeInterval { 1 }     // Default: 1s

    typealias Response = [Message]

    // Optional: stop polling based on response
    func shouldContinuePolling(after response: [Message]) -> Bool {
        // Continue polling until we receive a specific message
        !response.contains { $0.type == "disconnect" }
    }
}
```

## Start Polling

```swift
// Basic polling
for await messages in client.poll(MessagesEndpoint()) {
    print("New messages: \(messages)")
}

// With custom configuration
for await messages in client.poll(MessagesEndpoint(), configuration: .realtime) {
    handleMessages(messages)
}

// Limit to first N responses
for await messages in client.poll(MessagesEndpoint()).first(10) {
    print("Got batch: \(messages)")
}

// Stop based on condition
for await messages in client.poll(MessagesEndpoint()).while({ !$0.isEmpty }) {
    process(messages)
}
```

## Configuration Presets

```swift
// Short: 10s timeout, 0.5s retry (real-time critical)
let config = LongPollingConfiguration.short

// Standard: 30s timeout, 1s retry (balanced)
let config = LongPollingConfiguration.standard

// Long: 60s timeout, 2s retry (low server load)
let config = LongPollingConfiguration.long

// Realtime: 15s timeout, 0.1s retry (aggressive)
let config = LongPollingConfiguration.realtime

// Custom
let config = LongPollingConfiguration(
    timeout: 45,
    retryInterval: 2.0,
    maxConsecutiveErrors: 10
)
```

## Cancellation

Polling respects Swift's structured concurrency. Cancel the task to stop polling:

```swift
let pollingTask = Task {
    for await messages in client.poll(MessagesEndpoint()) {
        handleMessages(messages)
    }
}

// Later: stop polling
pollingTask.cancel()
```

## Error Handling

The polling stream automatically handles transient errors:

| Error | Behavior |
|-------|----------|
| Timeout | Reconnect immediately |
| 204 No Content | Wait `retryInterval`, poll again |
| 408 Request Timeout | Reconnect immediately |
| 5xx Server Error | Wait `retryInterval`, retry |
| Connection Lost | Wait `retryInterval * 2`, retry |
| 401/403/404 | Stop polling |
| Max consecutive errors | Stop polling |
