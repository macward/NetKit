#if canImport(SwiftUI)
import SwiftUI

// MARK: - Environment wiring

private struct QueryClientKey: EnvironmentKey {
    static let defaultValue: QueryClient? = nil
}

public extension EnvironmentValues {
    /// The data-layer store used by ``Resource``. Inject it once near the root.
    var queryClient: QueryClient? {
        get { self[QueryClientKey.self] }
        set { self[QueryClientKey.self] = newValue }
    }
}

public extension View {
    /// Provides a ``QueryClient`` to the view subtree so `@Resource` can resolve it.
    func queryClient(_ client: QueryClient) -> some View {
        environment(\.queryClient, client)
    }
}

// MARK: - @Resource

/// A SwiftUI property wrapper that binds a view to a server resource.
///
/// Reads the shared ``QueryEntry`` for the endpoint from the ``QueryClient`` in the
/// environment, kicks the initial fetch when the resource is first observed, and lets
/// SwiftUI re-render automatically as the entry's `phase` changes.
///
/// ```swift
/// struct ProfileView: View {
///     @Resource(GetUser(id: "123"), staleTime: .seconds(30)) var user
///
///     var body: some View {
///         switch user.phase {
///         case .idle, .loading: ProgressView()
///         case .success(let u):  Text(u.name)
///         case .failure(let e):  Text(e.localizedDescription)
///         }
///     }
/// }
/// // at the root: ContentView().queryClient(QueryClient(network: client))
/// ```
///
/// Implemented as a `DynamicProperty` (the same shape as SwiftData's `@Query`), not a
/// macro: the integration needed here is with SwiftUI's runtime lifecycle, which is
/// exactly what `DynamicProperty` provides.
@propertyWrapper
public struct Resource<E: Endpoint>: DynamicProperty {
    @Environment(\.queryClient) private var client
    @State private var token: ObserverToken = ObserverToken()

    private let endpoint: E
    private let staleTime: Duration

    public init(_ endpoint: E, staleTime: Duration = .zero) {
        self.endpoint = endpoint
        self.staleTime = staleTime
    }

    /// The shared, observable entry for this resource.
    public var wrappedValue: QueryEntry<E.Response> {
        let client: QueryClient? = self.client
        let endpoint: E = self.endpoint
        return MainActor.assumeIsolated {
            guard let client else {
                preconditionFailure(
                    "Resource requires a QueryClient in the environment. Call .queryClient(_:) near the root."
                )
            }
            return client.entry(for: endpoint)
        }
    }

    /// Called by SwiftUI on each render; performs the initial fetch when idle and keeps
    /// the observer registration in sync with the current endpoint.
    public func update() {
        let client: QueryClient? = self.client
        let endpoint: E = self.endpoint
        let staleTime: Duration = self.staleTime
        let token: ObserverToken = self.token
        MainActor.assumeIsolated {
            guard let client else { return }
            client.activateIfIdle(endpoint, staleTime: staleTime)
            token.bind(to: client.key(for: endpoint), client: client)
        }
    }
}

// MARK: - Observer Token

/// Reference type stored in `@State` so its lifetime tracks the view's identity:
/// SwiftUI keeps one instance per view and releases it (triggering `deinit`) when the
/// view leaves the hierarchy. That `deinit` is how we detect teardown — the missing
/// lifecycle hook that `DynamicProperty` does not provide.
///
/// `@unchecked Sendable` is sound here because `bind(to:client:)` is only ever called on
/// the main actor (from `Resource.update()` inside `assumeIsolated`), and `deinit` runs
/// after SwiftUI has dropped its last reference, so there is no concurrent access.
private final class ObserverToken: @unchecked Sendable {
    private var connectedKey: QueryKey?
    private var releaseConnected: (@Sendable () -> Void)?

    /// Binds the token to a key, retaining it. If the endpoint changed for the same view
    /// identity, releases the previous key first. Idempotent for an unchanged key.
    @MainActor
    func bind(to key: QueryKey, client: QueryClient) {
        guard connectedKey != key else { return }
        releaseConnected?()                       // release previous binding, if any
        client.retain(key)
        connectedKey = key
        releaseConnected = { Task { @MainActor in client.release(key) } }
    }

    deinit {
        releaseConnected?()
    }
}
#endif
