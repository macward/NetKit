import Foundation
import Observation

// MARK: - Query Client

/// The data-layer store: the Swift equivalent of TanStack Query's `QueryClient`.
///
/// It sits *on top* of ``NetworkClientProtocol`` (it does no transport itself) and owns:
/// - a registry of ``QueryEntry`` keyed by ``QueryKey`` (the decoded-value cache),
/// - query-level deduplication (one in-flight `Task` per key, sharing the decoded value),
/// - activation (initial fetch), invalidation, and optimistic writes.
///
/// `@MainActor` is deliberate: UI state lives on the main actor, fetches hop to the
/// network actor and back. This mirrors TanStack's single-threaded model and removes
/// data races by construction.
///
/// - Note: Initial load, shared cache, query-level dedup, invalidation, optimistic
///   writes, and observer-count garbage collection are all wired. Stale-driven
///   revalidation on lifecycle events (app foreground, view reappear) is handled at the
///   ``Resource`` layer rather than per render, to avoid a refetch storm.
@MainActor
@Observable
public final class QueryClient {
    @ObservationIgnored private let network: any NetworkClientProtocol
    @ObservationIgnored private let clock: ContinuousClock = ContinuousClock()
    @ObservationIgnored private var entries: [QueryKey: any AnyQueryEntry] = [:]

    /// How long an unobserved entry lingers in the cache before being collected.
    /// Mirrors TanStack Query's `gcTime`. A grace window lets a value survive brief
    /// navigations (pop-and-push to the same screen) without a refetch.
    @ObservationIgnored private let gcTime: Duration

    /// Pending collection tasks, keyed so a new observer can cancel one in flight.
    @ObservationIgnored private var pendingGC: [QueryKey: Task<Void, Never>] = [:]

    /// Resolves a stable identifier for the active session, folded into every key so a
    /// value decoded under one session is never served to another (R12). Mirrors how
    /// ``CacheKeyGenerator`` scopes cached bytes by `Authorization`. Returns `nil` when
    /// there is no active session (the default), which disables auth scoping.
    @ObservationIgnored private let authContext: @MainActor () -> String?

    /// Foreground-revalidation observer token, registered lazily by the SwiftUI layer and
    /// torn down on deinit. Held here (rather than per-view) so there is a single
    /// subscription for the whole store. `nil` until the first `@Resource` binds.
    @ObservationIgnored internal var foregroundObserver: (any NSObjectProtocol)?

    public init(
        network: any NetworkClientProtocol,
        gcTime: Duration = .seconds(60),
        authContext: @escaping @MainActor () -> String? = { nil }
    ) {
        self.network = network
        self.gcTime = gcTime
        self.authContext = authContext
    }

    // `isolated deinit` runs on the MainActor so it can touch `foregroundObserver`. The
    // store is created and released from the SwiftUI/main-actor side, so this holds.
    isolated deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    // MARK: Key derivation

    /// Builds the auth-scoped key for an endpoint. The single source of truth for keying:
    /// both the store and ``Resource`` route through here so the active session is always
    /// part of the identity (R12).
    internal func key<E: Endpoint>(for endpoint: E) -> QueryKey {
        QueryKey(endpoint, authContext: authContext())
    }

    // MARK: Entry registry

    /// Returns the shared entry for an endpoint, creating and wiring it on first use.
    public func entry<E: Endpoint>(for endpoint: E) -> QueryEntry<E.Response> {
        let key: QueryKey = key(for: endpoint)
        if let existing = entries[key] as? QueryEntry<E.Response> {
            return existing
        }

        let fresh: QueryEntry<E.Response> = QueryEntry<E.Response>()
        fresh.refetchHandler = { [weak self, weak fresh] in
            guard let self, let fresh else { return }
            self.performFetch(endpoint, into: fresh)
        }
        entries[key] = fresh
        return fresh
    }

    // MARK: Activation

    /// Triggers the initial fetch the first time a resource is observed.
    ///
    /// Subsequent renders are no-ops, and a second view mounting the same key sees the
    /// already-loaded value with no extra request. Stale-driven revalidation (when
    /// `staleTime` elapses) is the TODO that belongs to lifecycle events, not to every
    /// render — wiring it here would cause a refetch storm.
    internal func activateIfIdle<E: Endpoint>(_ endpoint: E, staleTime: Duration) {
        let entry: QueryEntry<E.Response> = entry(for: endpoint)
        guard entry.isIdle else { return }
        // Fixed at first activation (first-writer-wins): if two views share a key with
        // different staleTimes, revalidation timing stays deterministic rather than
        // depending on render order.
        entry.staleTime = staleTime
        performFetch(endpoint, into: entry)
    }

    // MARK: Lifecycle revalidation

    /// Revalidates every *observed* entry whose `staleTime` has elapsed. Wired to app
    /// foreground events by the SwiftUI layer (see `startForegroundRevalidationIfNeeded`).
    ///
    /// Unobserved entries are skipped — they revalidate lazily the next time a view
    /// observes them. ``QueryEntry/triggerRefetch()`` dedups against any in-flight request,
    /// so at most one revalidation per key is issued, and the current value stays visible
    /// while it refreshes (stale-while-revalidate). Fresh entries are left untouched.
    internal func revalidateStaleObservers() {
        let now: ContinuousClock.Instant = clock.now
        // Safe to mutate entries in this loop: `triggerRefetch` only mutates entry state
        // in place (never adds/removes registry keys), and everything is on the MainActor.
        for entry in entries.values where entry.observerCount > 0 {
            guard entry.isStale(asOf: now) else { continue }
            entry.triggerRefetch()
        }
    }

    // MARK: Observer lifecycle (garbage collection)

    /// Registers a live observer for a key. Cancels any pending collection so an entry
    /// being observed again is rescued from the grace window.
    ///
    /// Called by ``Resource`` when a view starts observing. The entry is expected to
    /// already exist (the resource creates it via ``entry(for:)`` first).
    internal func retain(_ key: QueryKey) {
        pendingGC[key]?.cancel()
        pendingGC[key] = nil
        entries[key]?.observerCount += 1
    }

    /// Deregisters an observer. When the count reaches zero, schedules collection after
    /// ``gcTime``; if an observer returns within that window, ``retain(_:)`` cancels it.
    internal func release(_ key: QueryKey) {
        guard let entry = entries[key] else { return }
        entry.observerCount = max(0, entry.observerCount - 1)
        guard entry.observerCount == 0 else { return }

        pendingGC[key]?.cancel()
        pendingGC[key] = Task { [weak self, gcTime] in
            try? await Task.sleep(for: gcTime)
            guard !Task.isCancelled else { return }
            self?.collect(key)
        }
    }

    /// Evicts an unobserved entry: cancels its in-flight request and drops it from the
    /// registry. Re-checks the observer count to stay safe against races.
    private func collect(_ key: QueryKey) {
        pendingGC[key] = nil
        guard let entry = entries[key], entry.observerCount == 0 else { return }
        entry.cancelInflight()
        entries[key] = nil
    }

    // MARK: Mutations / cache control

    /// Invalidates a resource: marks it stale, and refetches only if it is currently
    /// observed. Unobserved entries revalidate lazily the next time a view observes them.
    public func invalidate<E: Endpoint>(_ endpoint: E) {
        guard let entry = entries[key(for: endpoint)] else { return }
        entry.markStale()
        if entry.observerCount > 0 {
            entry.triggerRefetch()
        }
    }

    /// Writes a value directly into the cache (optimistic update). Every view observing
    /// this key updates immediately, before any network round-trip.
    public func setData<E: Endpoint>(_ endpoint: E, _ value: E.Response) {
        let entry: QueryEntry<E.Response> = entry(for: endpoint)
        entry.phase = .success(value)
        entry.updatedAt = clock.now
    }

    // MARK: Inspection (internal)

    /// Whether an entry for this key is currently held in the registry.
    internal func isTracked(_ key: QueryKey) -> Bool {
        entries[key] != nil
    }

    /// The number of live observers for a key, or zero if untracked.
    internal func observerCount(_ key: QueryKey) -> Int {
        entries[key]?.observerCount ?? 0
    }

    // MARK: Fetch

    /// Runs the request through the underlying client, with query-level dedup and SWR.
    private func performFetch<E: Endpoint>(_ endpoint: E, into entry: QueryEntry<E.Response>) {
        guard entry.inflight == nil else { return }   // dedup: one in-flight per key

        // Stale-while-revalidate: keep showing the old value while refreshing.
        if entry.value == nil {
            entry.phase = .loading
        }

        entry.inflight = Task { [network, clock] in
            do {
                let value: E.Response = try await network.request(endpoint)
                entry.phase = .success(value)
                entry.updatedAt = clock.now
            } catch {
                if entry.value == nil {
                    entry.phase = .failure(error)
                }
                // If we had a stale value, we keep it on failure (SWR semantics).
            }
            entry.inflight = nil
        }
    }
}
