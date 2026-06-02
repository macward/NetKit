import Testing
import Foundation
@testable import NetKit

// MARK: - Fixtures

private struct DLUser: Decodable, Sendable, Equatable {
    let id: String
    let name: String
}

private struct GetDLUser: Endpoint {
    typealias Response = DLUser
    let id: String
    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .get }
}

// MARK: - Tests

@MainActor
struct QueryClientTests {

    private func makeClient(
        configure: @Sendable (MockNetworkClient) async -> Void
    ) async -> QueryClient {
        let mock: MockNetworkClient = MockNetworkClient()
        await configure(mock)
        return QueryClient(network: mock)
    }

    @Test("activateIfIdle loads the value into the shared entry")
    func activateLoadsValue() async throws {
        let client: QueryClient = await makeClient { mock in
            await mock.stub(GetDLUser.self) { DLUser(id: $0.id, name: "Ada") }
        }

        let entry: QueryEntry<DLUser> = client.entry(for: GetDLUser(id: "1"))
        client.activateIfIdle(GetDLUser(id: "1"), staleTime: .zero)

        try await waitUntil { entry.value != nil }
        #expect(entry.value == DLUser(id: "1", name: "Ada"))
        #expect(entry.isLoading == false)
    }

    @Test("entry(for:) returns the same instance for an equal endpoint (shared cache)")
    func sharedCacheReturnsSameEntry() async {
        let client: QueryClient = await makeClient { mock in
            await mock.stub(GetDLUser.self) { DLUser(id: $0.id, name: "Ada") }
        }

        let first: QueryEntry<DLUser> = client.entry(for: GetDLUser(id: "1"))
        let second: QueryEntry<DLUser> = client.entry(for: GetDLUser(id: "1"))
        let other: QueryEntry<DLUser> = client.entry(for: GetDLUser(id: "2"))

        #expect(first === second)
        #expect(first !== other)
    }

    @Test("concurrent activations of the same key dedupe into a single network call")
    func dedupesConcurrentActivations() async throws {
        let mock: MockNetworkClient = MockNetworkClient()
        await mock.stub(GetDLUser.self, delay: 0.05) { DLUser(id: $0.id, name: "Ada") }
        let client: QueryClient = QueryClient(network: mock)

        let entry: QueryEntry<DLUser> = client.entry(for: GetDLUser(id: "1"))
        client.activateIfIdle(GetDLUser(id: "1"), staleTime: .zero)
        client.activateIfIdle(GetDLUser(id: "1"), staleTime: .zero) // second observer, same key

        try await waitUntil { entry.value != nil }
        let calls: Int = await mock.callCount(for: GetDLUser.self)
        #expect(calls == 1)
    }

    @Test("setData writes optimistically without a network call")
    func setDataIsOptimistic() async {
        let client: QueryClient = await makeClient { mock in
            await mock.stub(GetDLUser.self) { DLUser(id: $0.id, name: "FromServer") }
        }

        client.setData(GetDLUser(id: "1"), DLUser(id: "1", name: "Optimistic"))

        let entry: QueryEntry<DLUser> = client.entry(for: GetDLUser(id: "1"))
        #expect(entry.value == DLUser(id: "1", name: "Optimistic"))
    }

    @Test("invalidate refetches and updates the shared entry")
    func invalidateRefetches() async throws {
        let mock: MockNetworkClient = MockNetworkClient()
        await mock.stubSequence(GetDLUser.self, responses: [
            DLUser(id: "1", name: "v1"),
            DLUser(id: "1", name: "v2")
        ])
        let client: QueryClient = QueryClient(network: mock)

        let key: QueryKey = QueryKey(GetDLUser(id: "1"))
        let entry: QueryEntry<DLUser> = client.entry(for: GetDLUser(id: "1"))
        client.retain(key)   // simulate a live observer
        client.activateIfIdle(GetDLUser(id: "1"), staleTime: .zero)
        try await waitUntil { entry.value == DLUser(id: "1", name: "v1") }

        client.invalidate(GetDLUser(id: "1"))
        try await waitUntil { entry.value == DLUser(id: "1", name: "v2") }

        let calls: Int = await mock.callCount(for: GetDLUser.self)
        #expect(calls == 2)
    }

    // MARK: - Garbage collection

    @Test("invalidate only marks stale (no refetch) when there are no observers")
    func invalidateWithoutObserversDoesNotRefetch() async throws {
        let mock: MockNetworkClient = MockNetworkClient()
        await mock.stub(GetDLUser.self) { DLUser(id: $0.id, name: "Ada") }
        let client: QueryClient = QueryClient(network: mock)

        let entry: QueryEntry<DLUser> = client.entry(for: GetDLUser(id: "1"))
        client.activateIfIdle(GetDLUser(id: "1"), staleTime: .zero)  // no retain → unobserved
        try await waitUntil { entry.value != nil }

        client.invalidate(GetDLUser(id: "1"))
        try await Task.sleep(for: .milliseconds(50))

        let calls: Int = await mock.callCount(for: GetDLUser.self)
        #expect(calls == 1)   // not refetched
    }

    @Test("entry is collected after gcTime once observers drop to zero")
    func gcEvictsUnobservedEntry() async throws {
        let mock: MockNetworkClient = MockNetworkClient()
        await mock.stub(GetDLUser.self) { DLUser(id: $0.id, name: "Ada") }
        let client: QueryClient = QueryClient(network: mock, gcTime: .milliseconds(30))

        let key: QueryKey = QueryKey(GetDLUser(id: "1"))
        _ = client.entry(for: GetDLUser(id: "1"))
        client.retain(key)
        #expect(client.isTracked(key))

        client.release(key)
        #expect(client.isTracked(key))            // still in grace window

        try await waitUntil { !client.isTracked(key) }   // collected after gcTime
    }

    @Test("retaining again during the grace window cancels collection")
    func gcCancelledByRetain() async throws {
        let mock: MockNetworkClient = MockNetworkClient()
        await mock.stub(GetDLUser.self) { DLUser(id: $0.id, name: "Ada") }
        let client: QueryClient = QueryClient(network: mock, gcTime: .milliseconds(30))

        let key: QueryKey = QueryKey(GetDLUser(id: "1"))
        _ = client.entry(for: GetDLUser(id: "1"))
        client.retain(key)
        client.release(key)
        client.retain(key)   // rescue before gcTime elapses

        try await Task.sleep(for: .milliseconds(90))   // > gcTime
        #expect(client.isTracked(key))
        #expect(client.observerCount(key) == 1)
    }

    @Test("two observers keep an entry alive until both release")
    func gcWaitsForAllObservers() async throws {
        let mock: MockNetworkClient = MockNetworkClient()
        await mock.stub(GetDLUser.self) { DLUser(id: $0.id, name: "Ada") }
        let client: QueryClient = QueryClient(network: mock, gcTime: .milliseconds(30))

        let key: QueryKey = QueryKey(GetDLUser(id: "1"))
        _ = client.entry(for: GetDLUser(id: "1"))
        client.retain(key)
        client.retain(key)

        client.release(key)
        try await Task.sleep(for: .milliseconds(60))
        #expect(client.isTracked(key))   // one observer remains

        client.release(key)
        try await waitUntil { !client.isTracked(key) }
    }
}

// MARK: - Helpers

/// Polls a main-actor condition until true or a timeout elapses.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline: ContinuousClock.Instant = ContinuousClock().now.advanced(by: timeout)
    while !condition() {
        if ContinuousClock().now >= deadline {
            Issue.record("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
