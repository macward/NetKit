# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `SSELineParser` no longer dispatches events whose data buffer is empty, matching the WHATWG SSE
  spec ("if the data buffer is an empty string, return"). Previously any `event:`, `id:`, or
  `retry:` field alone caused a dispatch with `data = ""`, which reached the discriminator's
  `init(eventName:data:)` and typically threw a decoding error that killed the stream. The fix
  replaces the `hasBufferedField` guard with `!dataLines.isEmpty`: a blank line only dispatches
  when at least one `data:` field was accumulated for the current event. An explicit `data:` line
  with an empty value still dispatches (data buffer is non-empty per spec).

- SSE streaming now validates the HTTP response status code and runs the response interceptor chain
  at connection time. Previously `SSEByteTransport` discarded the `URLResponse` returned by
  `URLSession.bytes(for:)`, so non-2xx responses (401, 403, 500, …) silently streamed garbage bytes
  instead of throwing. Response interceptors (logging, auth) were also never called on the initial
  response. The fix captures the `HTTPURLResponse`, runs interceptors with the response headers
  (empty body — SSE has no buffered response body), then calls `validateResponse` before any lines
  are emitted. `NetworkError` propagates through `SSEStream.nextFromLines` unchanged so callers
  receive the structured error rather than `SSEError.unexpectedDisconnect`.

- SSE streaming now inherits certificate pinning from the client's `URLSession`. Previously
  `SSEByteTransport` created a new `URLSession` using only the session's configuration, silently
  discarding its `URLSessionDelegate` (e.g. `CertificatePinningDelegate`). A MITM certificate that
  `request(_:)` would have rejected was therefore accepted by `stream(_:)`. The fix passes the full
  session (via `SSEStreamDependencies.session`) through to `makeLineSource`, which now constructs
  the streaming session with `URLSession(configuration:delegate:delegateQueue:)` reusing the
  original delegate.

### Added

- Server-Sent Events (SSE) streaming: type-safe, incremental consumption of `text/event-stream`
  endpoints. Declare an `SSEEndpoint` (refines `Endpoint`, defaults `Response` to `EmptyResponse`)
  whose `associatedtype Event: SSEDecodableEvent` owns discrimination via
  `init(eventName:data:) throws` and a generic `isTerminal` flag. Consume with
  `for try await event in client.stream(endpoint)`: the client opens `URLSession.bytes` with a
  long timeout, forces `Accept: text/event-stream`, runs request interceptors (so `AuthInterceptor`
  injects the Bearer), and bypasses cache and deduplication. `SSEStream<E>` delivers typed events
  as they arrive, ends on a terminal event, surfaces decode failures as `SSEError.decodingFailed`
  and mid-stream cuts as `SSEError.unexpectedDisconnect(lastEventID:)`, cancels the underlying
  request when the consuming task is cancelled, and exposes raw `SSEEvent`s via `rawEvents`. Public
  surface: `SSEEndpoint`, `SSEDecodableEvent`, `SSEEvent`, `SSEStream`, `SSEError`,
  `SSEConfiguration`, and `NetworkClient.stream(_:)` / `NetworkClientProtocol`.
- SSE dialect presets (transport modeling only, not SDKs): `OpenAIStreamEvent` (discriminates by
  `data` content, `[DONE]` sentinel as a terminal case without JSON decode) and
  `AnthropicStreamEvent` (discriminates by event name — `content_block_delta`, `message_stop`,
  …— into distinct typed cases).
- SSE testing support: `MockNetworkClient.stubStream(_:events:error:)` injects a pre-cooked
  sequence of typed events (and an optional error) so consumers can test stream-consuming code
  with no network.
- SwiftUI-native data layer (`@Resource`): a small observable query cache layered on
  `NetworkClientProtocol`, in the spirit of TanStack Query. A view declares the resource it
  needs and receives observable state (`phase` with `value`/`error`/`isLoading`), a cache
  shared by `QueryKey`, query-level deduplication, and stale-while-revalidate. Inject the
  store via `EnvironmentValues.queryClient` / `View.queryClient(_:)`. Public surface:
  `@Resource(_:staleTime:)`, `QueryEntry` (+ `refetch()`), and `QueryClient`
  (`entry(for:)`, `invalidate(_:)`, optimistic `setData(_:_:)`).
- Data layer revalidation driven by lifecycle, never per render: observed, stale resources
  revalidate on app foreground and when a view reappears past its `staleTime`, reusing the
  per-key dedup and keeping the previous value visible (SWR).
- Data layer garbage collection by observer count: an unobserved entry is collected after
  `gcTime` (default 60s, configurable), rescued if re-observed within the window, and its
  in-flight request is cancelled on collection.
- Data layer auth isolation: the active session (via a `authContext` resolver) is folded
  into `QueryKey`, so a value decoded under one session is never served to another after a
  session switch — mirroring how the HTTP cache scopes bytes by `Authorization`.
- Documentation: a new [Data Layer](docs/data-layer.md) guide covering `@Resource`,
  `QueryClient` injection, invalidation, optimistic writes, freshness/revalidation and GC,
  surfaced from the README docs index and feature list.

- Standalone `NetKitMacros` package scaffold (separate `Package.swift`) for the
  upcoming declarative `@Endpoint` macros. The `swift-syntax` dependency lives only
  in this package's `.macro` implementation target (`NetKitMacrosImpl`), keeping the
  core `NetKit` package dependency-free for consumers of the manual `Endpoint` model.
- Compiler plugin skeleton registering all eight macro types, plus public macro
  declarations for the verb macros `@GET`/`@POST`/`@PUT`/`@PATCH`/`@DELETE`
  (attached member + extension, conforming to `Endpoint`) and the property markers
  `@Path`/`@Query`/`@Body` (no-op peer macros). No generation logic yet — annotating
  a type compiles cleanly with no members emitted.
- Verb macros now generate the core `Endpoint` conformance: a computed `path` that
  interpolates each `{placeholder}` with its homonymous `@Path` property at runtime,
  a `method` returning the verb's `HTTPMethod`, and the `: Endpoint` conformance via a
  generated extension. The developer-declared `Response` typealias is preserved.
  `@GET("/users/{id}")` now resolves to `/users/123` for `id == "123"`, indistinguishable
  from a hand-written struct.
- Verb macros now also generate `queryParameters` from `@Query` properties and `body`
  from a `@Body` property. Optional `@Query` values that are `nil` are omitted, array
  values repeat the key per element, and a custom name maps a property to a different
  query key (`@Query("page_size") var pageSize`). `@Path` gains the same custom-name
  support for placeholder overrides. `body` is type-erased to `(any Encodable & Sendable)?`
  and is only generated when a `@Body` exists; otherwise the protocol default `nil` is
  inherited. `queryParameters` is likewise only generated when at least one `@Query` is
  present.
- Verb macros now cross-validate the route template against the type's markers and emit
  clear, node-anchored compile-time diagnostics instead of generic macro failures: a
  `{placeholder}` with no matching `@Path` (anchored to the route annotation), an orphan
  `@Path` with no matching placeholder (anchored to the property, with a FixIt that
  removes the marker), a `@Body` under a bodiless verb such as `GET` (anchored to the
  verb annotation, with a FixIt that removes the marker), and more than one HTTP verb on
  the same type (a single diagnostic anchored to the first verb).
- Completed the verb matrix: `@POST`/`@PUT`/`@PATCH`/`@DELETE` each generate their
  matching `HTTPMethod` and share GET's path/query/body generation. Verb macros now also
  honor manual overrides — when the type already declares a member the macro would
  generate (`path`/`method`/`queryParameters`/`body`) or any protocol-default member such
  as `cachePolicy`/`headers`, the macro skips generating it so the hand-written member is
  respected without a redeclaration conflict.
- Documentation: a new [Endpoint Macros](docs/macros.md) guide with a before/after example
  (manual `Endpoint` struct vs the `@GET`/`@POST` macro form), the annotation reference, and
  how to opt into the separate `NetKitMacros` package — noting the manual model stays
  first-class and the core `NetKit` package remains dependency-free. The macros are now also
  surfaced from the README (Features, Installation, docs index) and the Getting Started guide.
