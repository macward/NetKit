import Foundation

/// The result of looking up or creating an in-flight request task.
internal struct InFlightTaskResult: Sendable {
    /// The task to await for the request result.
    let task: Task<Data, Error>
    /// Whether this task was newly created (true) or was already in-flight (false).
    let wasCreated: Bool
}

/// A slot in the tracker: the shared network task plus how many callers are waiting for it.
private struct InFlightEntry: Sendable {
    let task: Task<Data, Error>
    var waiterCount: Int
}

/// Tracks in-flight network requests to enable deduplication.
///
/// This actor maintains a thread-safe dictionary of currently executing requests,
/// allowing multiple callers requesting the same resource to share a single network call.
///
/// Each entry tracks a waiter count. When every caller that joined a shared task cancels
/// before the task completes, the count reaches zero and the underlying task is cancelled,
/// releasing the network connection rather than completing a request nobody needs.
///
/// The tracker stores `Task<Data, Error>` rather than typed responses because the generic
/// response type varies by endpoint. Each caller decodes the shared data independently.
internal actor InFlightRequestTracker {
    private var inFlight: [SendableRequestKey: InFlightEntry] = [:]

    /// Atomically gets an existing task or registers a new one for the given request key.
    ///
    /// This method is atomic to prevent race conditions where multiple concurrent requests
    /// could both check for an existing task, find none, and both register their own tasks.
    ///
    /// The waiter count is incremented for every call, whether or not the task was created.
    /// Each caller must either call `remove(key:)` on normal completion or
    /// `decrementWaiter(for:)` on cancellation.
    ///
    /// - Parameters:
    ///   - key: The request key to look up.
    ///   - createTask: A closure that creates a new task if no existing task is found.
    /// - Returns: A result containing the task and whether it was newly created.
    func getOrCreate(for key: SendableRequestKey, createTask: () -> Task<Data, Error>) -> InFlightTaskResult {
        if var existing = inFlight[key] {
            existing.waiterCount += 1
            inFlight[key] = existing
            return InFlightTaskResult(task: existing.task, wasCreated: false)
        }
        let task: Task<Data, Error> = createTask()
        inFlight[key] = InFlightEntry(task: task, waiterCount: 1)
        return InFlightTaskResult(task: task, wasCreated: true)
    }

    /// Returns an existing task for the given request key, if one is in flight.
    /// - Parameter key: The request key to look up.
    /// - Returns: The existing task if found, nil otherwise.
    func existingTask(for key: SendableRequestKey) -> Task<Data, Error>? {
        inFlight[key]?.task
    }

    /// Registers a new task for the given request key with an initial waiter count of 1.
    /// - Note: Prefer using `getOrCreate` in production code to avoid race conditions.
    /// - Parameters:
    ///   - task: The task to register.
    ///   - key: The request key to associate with the task.
    func register(_ task: Task<Data, Error>, for key: SendableRequestKey) {
        inFlight[key] = InFlightEntry(task: task, waiterCount: 1)
    }

    /// Removes the task associated with the given request key.
    /// Call this when the request completes (success or failure) so subsequent callers
    /// for the same key start a fresh request.
    /// - Parameter key: The request key to remove.
    func remove(key: SendableRequestKey) {
        inFlight.removeValue(forKey: key)
    }

    /// Decrements the waiter count for a key.
    ///
    /// Call this when a caller is cancelled before the shared task completes.
    /// When the count reaches zero all interested callers have left, so the underlying
    /// task is cancelled and the entry is removed. A no-op if the key is not present.
    /// - Parameter key: The request key whose waiter count should be decremented.
    func decrementWaiter(for key: SendableRequestKey) {
        guard var entry = inFlight[key] else { return }
        entry.waiterCount -= 1
        if entry.waiterCount <= 0 {
            entry.task.cancel()
            inFlight.removeValue(forKey: key)
        } else {
            inFlight[key] = entry
        }
    }
}
