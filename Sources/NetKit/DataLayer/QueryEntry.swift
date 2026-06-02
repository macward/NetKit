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

    /// The freshness window remembered from the resource's `staleTime`, used by lifecycle
    /// revalidation to decide whether this entry needs refreshing.
    var staleTime: Duration { get set }

    /// Whether the cached value is stale as of `now`: `true` if it was never loaded (or
    /// explicitly marked stale), otherwise `true` once `staleTime` has elapsed since the
    /// last successful load.
    func isStale(asOf now: ContinuousClock.Instant) -> Bool

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

    /// Freshness window for this resource, set on activation from the `@Resource`'s
    /// `staleTime`. Drives stale-driven revalidation on lifecycle events.
    @ObservationIgnored var staleTime: Duration = .zero

    /// The fetch closure wired by ``QueryClient`` when the entry is created. Internal
    /// mechanics; views drive refetching through the public ``refetch()`` instead.
    @ObservationIgnored var refetchHandler: @MainActor () -> Void = {}

    /// Entries are created exclusively by ``QueryClient/entry(for:)``; consumers never
    /// construct one directly.
    internal init() {}

    // MARK: Convenience accessors for the view

    /// The decoded value if the resource has loaded successfully, otherwise `nil`.
    public var value: Value? {
        if case .success(let value) = phase { return value }
        return nil
    }

    /// The error from the last failed load, or `nil` if the resource has not failed.
    public var error: (any Error)? {
        if case .failure(let error) = phase { return error }
        return nil
    }

    /// `true` while an initial load is in flight (no value yet). Stays `false` during a
    /// stale-while-revalidate refresh, when a previous value is still being shown.
    public var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    // MARK: Manual refetch

    /// Forces a fresh fetch of this resource, ignoring `staleTime`.
    ///
    /// Intended to be called from the view — e.g. a pull-to-refresh or a "retry" button.
    /// No-ops if a fetch is already in flight (query-level dedup drops the duplicate
    /// rather than coalescing), and keeps the current value visible while revalidating
    /// (stale-while-revalidate). Has no effect on an entry not yet registered with a
    /// ``QueryClient`` (which cannot happen for entries obtained via `@Resource`).
    public func refetch() {
        triggerRefetch()
    }

    var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    // MARK: AnyQueryEntry

    func isStale(asOf now: ContinuousClock.Instant) -> Bool {
        guard let updatedAt else { return true }   // never loaded, or explicitly marked stale
        return now - updatedAt >= staleTime
    }

    func markStale() {
        updatedAt = nil
    }

    func triggerRefetch() {
        refetchHandler()
    }

    func cancelInflight() {
        inflight?.cancel()
        inflight = nil
    }
}
