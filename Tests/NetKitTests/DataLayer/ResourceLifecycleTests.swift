#if canImport(SwiftUI) && canImport(UIKit)
import Testing
import Foundation
import SwiftUI
import UIKit
@testable import NetKit

// MARK: - Fixtures

private struct LCUser: Decodable, Sendable, Equatable {
    let id: String
    let name: String
}

private struct GetLCUser: Endpoint {
    typealias Response = LCUser
    let id: String
    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .get }
}

/// A minimal SwiftUI view that observes a resource via `@Resource`. Reading `user.value`
/// in `body` subscribes the view and drives `@Resource.update()` (activation + observer
/// binding) when the view is hosted and rendered.
private struct ProbeView: View {
    @Resource<GetLCUser> private var user: QueryEntry<LCUser>

    init(id: String = "1", staleTime: Duration = .seconds(60)) {
        _user = Resource(GetLCUser(id: id), staleTime: staleTime)
    }

    var body: some View {
        Text(user.value?.name ?? "none")
    }
}

/// Hosts a SwiftUI view in a real key window so SwiftUI manages its lifecycle (`update()`,
/// `@State` storage, and `ObserverToken.deinit` on teardown). `unmount()` releases the
/// hosting controller and drains the run loop so ARC and SwiftUI tear down synchronously,
/// firing `ObserverToken.deinit` before assertions run.
@MainActor
private final class ViewHarness {
    private var window: UIWindow?

    init<V: View>(_ view: V) {
        let window: UIWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.rootViewController?.view.setNeedsLayout()
        window.rootViewController?.view.layoutIfNeeded()
        self.window = window
    }

    func unmount() {
        window?.rootViewController = nil
        window?.isHidden = true
        window = nil
        // Force ARC + SwiftUI to drain synchronously so ObserverToken.deinit fires before
        // we assert on observerCount, rather than relying on incidental run-loop yields.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}

// MARK: - Tests

@MainActor
struct ResourceLifecycleTests {

    @Test("mounting a @Resource view registers an observer; unmounting collects it after gcTime")
    func mountRegistersUnmountCollects() async throws {
        let mock: MockNetworkClient = MockNetworkClient()
        await mock.stub(GetLCUser.self) { LCUser(id: $0.id, name: "Ada") }
        let client: QueryClient = QueryClient(network: mock, gcTime: .milliseconds(80))
        let key: QueryKey = client.key(for: GetLCUser(id: "1"))

        var harness: ViewHarness? = ViewHarness(ProbeView().queryClient(client))
        defer { harness?.unmount(); harness = nil }

        try await waitUntilLC { client.observerCount(key) == 1 }   // update() bound an observer

        harness?.unmount()
        harness = nil

        try await waitUntilLC { client.observerCount(key) == 0 }   // ObserverToken.deinit released it
        try await waitUntilLC { !client.isTracked(key) }           // collected after gcTime
    }

    @Test("reappearing within gcTime cancels collection and reuses the value without refetch")
    func reappearWithinGraceRescuesEntry() async throws {
        let mock: MockNetworkClient = MockNetworkClient()
        await mock.stub(GetLCUser.self) { LCUser(id: $0.id, name: "Ada") }
        let client: QueryClient = QueryClient(network: mock, gcTime: .seconds(3))
        let key: QueryKey = client.key(for: GetLCUser(id: "1"))

        var first: ViewHarness? = ViewHarness(ProbeView().queryClient(client))
        var second: ViewHarness? = nil
        defer {
            first?.unmount(); first = nil
            second?.unmount(); second = nil
        }

        try await waitUntilLC { client.observerCount(key) == 1 }
        try await waitUntilLC { client.entry(for: GetLCUser(id: "1")).value != nil }
        let callsAfterFirst: Int = await mock.callCount(for: GetLCUser.self)
        #expect(callsAfterFirst == 1)

        first?.unmount()
        first = nil
        try await waitUntilLC { client.observerCount(key) == 0 }
        #expect(client.isTracked(key))   // still within the grace window

        second = ViewHarness(ProbeView().queryClient(client))
        try await waitUntilLC { client.observerCount(key) == 1 }
        #expect(client.isTracked(key))   // rescued, not collected

        let callsAfterSecond: Int = await mock.callCount(for: GetLCUser.self)
        #expect(callsAfterSecond == 1)   // fresh value reused, no refetch
    }

    @Test("an in-flight request is cancelled when the entry is collected (R17)")
    func inflightCancelledOnCollect() async throws {
        let mock: MockNetworkClient = MockNetworkClient()
        // A delay long enough to be reliably in flight at collection, short enough that the
        // test can wait *past* it to prove the response never lands.
        await mock.stub(GetLCUser.self, delay: 0.3) { LCUser(id: $0.id, name: "Ada") }
        let client: QueryClient = QueryClient(network: mock, gcTime: .milliseconds(50))
        let key: QueryKey = client.key(for: GetLCUser(id: "1"))
        let entry: QueryEntry<LCUser> = client.entry(for: GetLCUser(id: "1"))   // hold a ref to inspect phase

        var harness: ViewHarness? = ViewHarness(ProbeView().queryClient(client))
        defer { harness?.unmount(); harness = nil }

        try await waitUntilLC { client.observerCount(key) == 1 }
        try await waitUntilLC { entry.isLoading }   // the 0.3s fetch is in flight

        harness?.unmount()
        harness = nil
        try await waitUntilLC { !client.isTracked(key) }   // collected → cancelInflight()

        // Wait well past the stub delay. Had the task NOT been cancelled, it would have
        // resolved by now and written `.success("Ada")` to the (still-referenced) entry.
        // That it remains value-less proves the in-flight request was cancelled (R17).
        try await Task.sleep(for: .milliseconds(500))
        #expect(entry.value == nil)
    }
}

// MARK: - Helpers

private struct LifecycleTimeoutError: Error {}

/// Polls a main-actor condition until true, or **throws** on timeout so the failure is
/// hard (a timed-out poll must not let later assertions pass vacuously). Between polls it
/// awaits a short sleep, yielding to the main run loop so SwiftUI can render and ARC drain.
@MainActor
private func waitUntilLC(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline: ContinuousClock.Instant = ContinuousClock().now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock().now < deadline else {
            throw LifecycleTimeoutError()
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(10))
    }
}
#endif
