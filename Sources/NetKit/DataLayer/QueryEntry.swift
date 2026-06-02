import Foundation
import Observation

// MARK: - Type-erased entry

/// Type-erased handle to a ``QueryEntry`` so the store can hold a heterogeneous
/// registry (`[QueryKey: any AnyQueryEntry]`) and downcast on read.
@MainActor
protocol AnyQueryEntry: AnyObject {
    /// Number of live views currently observing this entry. The hook for
    /// observer-count garbage collection (evict when this reaches zero).
    var observerCount: Int { get set }

    /// Marks the cached value as stale so the next activation revalidates it.
    func markStale()

    /// Forces a refetch (used by manual `refetch()` and `invalidate`).
    func triggerRefetch()

    /// Cancels any in-flight request. Called when the entry is garbage-collected.
    func cancelInflight()
}

// MARK: - Query Entry

/// The observable, shared state for a single resource.
///
/// One entry exists per ``QueryKey`` in the ``QueryClient``. Every ``Resource`` that
/// addresses the same key reads the *same* entry, so a value fetched for one view is
/// instantly visible to all others, and an invalidation fans out to every observer —
/// this is what the Observation framework gives us for free.
@MainActor
@Observable
public final class QueryEntry<Value: Sendable>: AnyQueryEntry {
    /// The lifecycle phase of the resource. This is the only observed property —
    /// reading it in a SwiftUI view subscribes that view to updates.
    public enum Phase: Sendable {
        case idle
        case loading
        case success(Value)
        case failure(any Error)
    }

    public internal(set) var phase: Phase = .idle

    // MARK: Internal mechanics (not part of the observed UI surface)

    @ObservationIgnored var updatedAt: ContinuousClock.Instant?
    @ObservationIgnored var inflight: Task<Void, Never>?
    @ObservationIgnored var observerCount: Int = 0
    @ObservationIgnored var refetch: @MainActor () -> Void = {}

    init() {}

    // MARK: Convenience accessors for the view

    public var value: Value? {
        if case .success(let value) = phase { return value }
        return nil
    }

    public var error: (any Error)? {
        if case .failure(let error) = phase { return error }
        return nil
    }

    public var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    // MARK: AnyQueryEntry

    func markStale() {
        updatedAt = nil
    }

    func triggerRefetch() {
        refetch()
    }

    func cancelInflight() {
        inflight?.cancel()
        inflight = nil
    }
}
