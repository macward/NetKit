import Foundation

/// The result of looking up or creating an in-flight request task.
internal struct InFlightTaskResult: Sendable {
    /// The task to await for the request result.
    let task: Task<Data, Error>
    /// Whether this task was newly created (true) or was already in-flight (false).
    let wasCreated: Bool
}

/// Tracks in-flight network requests to enable deduplication.
///
/// This actor maintains a thread-safe dictionary of currently executing requests,
/// allowing multiple callers requesting the same resource to share a single network call.
///
/// The tracker stores `Task<Data, Error>` rather than typed responses because the generic
/// response type varies by endpoint. Each caller decodes the shared data independently.
internal actor InFlightRequestTracker {
    private var inFlight: [RequestKey: Task<Data, Error>] = [:]

    /// Atomically gets an existing task or registers a new one for the given request key.
    ///
    /// This method is atomic to prevent race conditions where multiple concurrent requests
    /// could both check for an existing task, find none, and both register their own tasks.
    ///
    /// - Parameters:
    ///   - key: The request key to look up.
    ///   - createTask: A closure that creates a new task if no existing task is found.
    /// - Returns: A result containing the task and whether it was newly created.
    func getOrCreate(for key: RequestKey, createTask: () -> Task<Data, Error>) -> InFlightTaskResult {
        if let existing = inFlight[key] {
            return InFlightTaskResult(task: existing, wasCreated: false)
        }
        let task: Task<Data, Error> = createTask()
        inFlight[key] = task
        return InFlightTaskResult(task: task, wasCreated: true)
    }

    /// Returns an existing task for the given request key, if one is in flight.
    /// - Parameter key: The request key to look up.
    /// - Returns: The existing task if found, nil otherwise.
    func existingTask(for key: RequestKey) -> Task<Data, Error>? {
        inFlight[key]
    }

    /// Registers a new task for the given request key.
    /// - Note: Prefer using `getOrCreate` in production code to avoid race conditions.
    /// - Parameters:
    ///   - task: The task to register.
    ///   - key: The request key to associate with the task.
    func register(_ task: Task<Data, Error>, for key: RequestKey) {
        inFlight[key] = task
    }

    /// Removes the task associated with the given request key.
    /// Call this when the request completes (success or failure).
    /// - Parameter key: The request key to remove.
    func remove(key: RequestKey) {
        inFlight.removeValue(forKey: key)
    }
}
