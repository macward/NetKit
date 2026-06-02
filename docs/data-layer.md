# Data Layer (`@Resource`)

NetKit's request API is imperative: you call `client.request(_:)` and manage the `loading`
/ `value` / `error` state by hand with `@State` and `.task`. For screens that just need to
*read* a server resource, the **data layer** does that plumbing for you. It is a small,
observable cache — the Swift equivalent of TanStack Query's `QueryClient` — layered on top
of `NetworkClientProtocol`: a view declares the resource it needs and gets back observable
state, a cache shared by key, request deduplication, and stale-while-revalidate, with no
manual wiring.

The data layer is **additive**. It does no transport itself; it consumes `request(_:)`
(auth interceptors and all), and it does not replace `ResponseCache` — the two are
complementary caches (HTTP bytes vs. decoded values + UI state).

## Setup

Create one `QueryClient` near the root of your app and inject it into the environment with
`.queryClient(_:)`:

```swift
import SwiftUI
import NetKit

@main
struct MyApp: App {
    private let client = NetworkClient(environment: APIEnvironment())

    var body: some Scene {
        WindowGroup {
            ContentView()
                .queryClient(QueryClient(network: client))
        }
    }
}
```

(`APIEnvironment` is your `NetworkEnvironment` conformance — see
[Getting Started](getting-started.md).)

Every `@Resource` in the subtree resolves this store from the environment.

## Reading a resource with `@Resource`

Declare the resource a view needs as a property. `@Resource` kicks off the initial fetch the
first time the view is observed and re-renders the view as the resource's `phase` changes:

```swift
struct ProfileView: View {
    @Resource(GetUser(id: "123")) var user

    var body: some View {
        switch user.phase {
        case .idle, .loading:
            ProgressView()
        case .success(let user):
            Text(user.name)
        case .failure(let error):
            Text(error.localizedDescription)
        }
    }
}
```

`phase` is a `QueryEntry<Value>.Phase` — `idle`, `loading`, `success(value)`, or
`failure(error)`. For the common cases there are convenience accessors so you can avoid the
full `switch`:

| Accessor | Meaning |
|----------|---------|
| `user.value` | The decoded value if loaded successfully, else `nil`. |
| `user.error` | The error from the last failed load, else `nil`. |
| `user.isLoading` | `true` when `phase == .loading`. The phase only enters `.loading` while there is no value yet, so a stale-while-revalidate refresh (which keeps the previous value on screen) does **not** flip `isLoading` to `true`. |

```swift
var body: some View {
    if let user = user.value {
        Text(user.name)
    } else if user.isLoading {
        ProgressView()
    } else if let error = user.error {
        Text(error.localizedDescription)
    }
}
```

## Manual refetch

Force a fresh fetch — e.g. from a pull-to-refresh or a "retry" button — with `refetch()`:

```swift
List { /* ... */ }
.refreshable {
    user.refetch()
}
```

`refetch()` ignores `staleTime` and keeps the current value visible while revalidating. It
**no-ops if a fetch is already in flight** (the in-flight request is left to complete and its
result still reaches the view); it does not issue a duplicate.

## Shared cache and deduplication

Resources are identified by a `QueryKey` derived from the endpoint (method, path, sorted
query, the decoded `Response` type, and a body fingerprint). Every `@Resource` that addresses
the same key reads the **same** `QueryEntry`:

- Two views showing `GetUser(id: "123")` share one cached value — the second mounts with no
  extra request.
- Concurrent activations of the same key **dedupe** into a single network call.

You can reach the shared entry directly from the client when you need it outside a view:

```swift
let entry = queryClient.entry(for: GetUser(id: "123"))
```

## Invalidation

After a mutation, mark a resource stale so its observers refresh. `invalidate(_:)` refetches
immediately **only if the resource is currently observed**; an unobserved resource is just
marked stale and revalidates lazily the next time a view observes it.

```swift
try await client.request(UpdateUser(id: "123", name: "Ada"))
queryClient.invalidate(GetUser(id: "123"))   // observing views refresh
```

## Optimistic writes

Write a value straight into the cache with `setData(_:_:)`. Every view observing that key
updates immediately, before any network round-trip:

```swift
queryClient.setData(GetUser(id: "123"), updatedUser)
```

This is the optimistic-update primitive; formal mutations with rollback are out of scope (see
[Not covered](#not-covered)).

## Freshness and revalidation

Each `@Resource` accepts a `staleTime` — how long a loaded value is considered fresh:

```swift
@Resource(GetUser(id: "123"), staleTime: .seconds(30)) var user
```

Revalidation is driven by lifecycle transitions, **never** per render (which would cause a
refetch storm):

- **App foreground** — when the app returns to the foreground, every *observed* resource
  whose `staleTime` has elapsed revalidates.
- **View reappear** — when a view re-observes a resource (re-mount / reappear) that already
  has a value but has aged past its `staleTime`, it revalidates.

In both cases the revalidation reuses the per-key dedup (at most one request in flight) and
keeps the previous value on screen while it refreshes (stale-while-revalidate).

The default `staleTime` is `.zero`, meaning a value is immediately stale and revalidates on
every foreground and reappear. Pass a positive duration to opt into a freshness window that
suppresses those revalidations until it elapses.

## Garbage collection

An entry is kept alive while at least one view observes it. When the last observer goes away,
the entry lingers for `gcTime` (default 60s) before being collected — a grace window so a
brief navigation (pop-and-push back to the same screen) reuses the value without a refetch.
If a view re-observes within the window, collection is cancelled. On collection, any in-flight
request for the entry is cancelled.

Tune the window on the client:

```swift
QueryClient(network: client, gcTime: .seconds(120))
```

## Auth isolation

A value decoded under one session must never be served to another. The `QueryClient` folds
an **auth context** into every `QueryKey` (mirroring how the HTTP cache scopes bytes by the
`Authorization` header), so two sessions produce distinct keys for the same endpoint. Provide
a stable identifier for the active session — for example the user id, or a token fingerprint:

```swift
QueryClient(network: client, authContext: { session.currentUserID })
```

With this in place, after a session switch a view never receives the previous session's
decoded value. When omitted, the context is `nil` and no auth scoping is applied.

## Not covered

The data layer is deliberately focused. The following are **not** part of it:

- Formal mutations with optimistic rollback (only `setData`).
- Non-GET resources as first-class cacheables (the supported contract is idempotent endpoints).
- On-disk persistence of the query cache (the store is in-memory only).
- Typed SSE/streaming, typed per-endpoint error bodies, and pagination.

## Surface summary

| API | Purpose |
|-----|---------|
| `@Resource(_:staleTime:)` | Bind a view to a resource; returns its observable `QueryEntry`. |
| `QueryEntry.phase` / `value` / `error` / `isLoading` | Observe lifecycle state. |
| `QueryEntry.refetch()` | Force a manual refetch from the view. |
| `QueryClient(network:gcTime:authContext:)` | Create the store. |
| `QueryClient.entry(for:)` | Get the shared entry for an endpoint. |
| `QueryClient.invalidate(_:)` | Mark stale; refetch if observed. |
| `QueryClient.setData(_:_:)` | Optimistic write into the cache. |
| `EnvironmentValues.queryClient` / `View.queryClient(_:)` | Inject the store. |

See also: [Getting Started](getting-started.md), [Endpoints](endpoints.md),
[Testing](testing.md).
