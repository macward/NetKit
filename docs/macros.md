# Endpoint Macros

NetKit's `Endpoint` model is type-safe but verbose: every endpoint repeats the same
`path` / `method` / `queryParameters` / `body` plumbing. The **NetKitMacros** package removes
that boilerplate with declarative macros that generate the `Endpoint` conformance and its
derived members for you.

Macros are **additive and entirely opt-in**. The manual `Endpoint` struct stays a first-class
citizen, and consumers who never import `NetKitMacros` keep a **zero-dependency** NetKit — the
`swift-syntax` toolchain the macros need lives in a separate package and never enters the core
dependency graph.

## Before / After

### GET with a path parameter

**Before** — manual struct:

```swift
import NetKit

struct GetUserEndpoint: Endpoint {
    let id: String

    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .get }

    typealias Response = User
}
```

**After** — macro:

```swift
import NetKit
import NetKitMacros

@GET("/users/{id}")
struct GetUserEndpoint {
    typealias Response = User
    @Path var id: String
}
```

Both are used identically — the generated endpoint is observably indistinguishable from the
manual one (same resolved path, method, query, body and decoded `Response`):

```swift
let user = try await client.request(GetUserEndpoint(id: "123"))
```

### POST with a body and a query parameter

**Before** — manual struct:

```swift
struct CreateArticleEndpoint: Endpoint {
    let article: Article
    let draft: Bool

    var path: String { "/articles" }
    var method: HTTPMethod { .post }
    var queryParameters: [String: String] { ["draft": "\(draft)"] }
    var body: (any Encodable & Sendable)? { article }

    typealias Response = Article
}
```

**After** — macro:

```swift
@POST("/articles")
struct CreateArticleEndpoint {
    typealias Response = Article
    @Body var article: Article
    @Query var draft: Bool
}
```

## What the macro generates

From the annotations above, the verb macro synthesizes only the members the annotations call
for — always `path` and `method`, plus `queryParameters` when at least one `@Query` is present
and `body` when a `@Body` is present — together with the `Endpoint` conformance.
`@POST("/articles")` on the struct above expands to:

```swift
extension CreateArticleEndpoint: Endpoint {
}

// ...and these members on the type:
var path: String { "/articles" }
var method: HTTPMethod { .post }
var queryParameters: [String: String] {
    var parameters: [String: String] = [:]
    parameters["draft"] = "\(draft)"
    return parameters
}
var body: (any Encodable & Sendable)? { article }
```

You still declare the stored properties and the `Response` type. Protocol members that already
have a default (`headers`, `cacheTTL`, `cachePolicy`, `deduplicationPolicy`) are **not**
generated, so you can override any of them by hand without conflict.

## Annotations

| Macro | Applies to | Effect |
|-------|------------|--------|
| `@GET` / `@POST` / `@PUT` / `@PATCH` / `@DELETE` | the type | Declares the verb; generates `path`, `method`, `queryParameters`, `body` and the `: Endpoint` conformance. |
| `@Path` | a stored property | Substitutes the matching `{placeholder}` in the path at runtime. |
| `@Query` | a stored property | Appends the property to `queryParameters`. |
| `@Body` | a stored property | Uses the property as the request `body`. |

`@Path` and `@Query` accept a custom name when the wire key differs from the Swift property
name — `@Path("user_id") var id` resolves `{user_id}`, and `@Query("page_size") var pageSize`
emits `page_size`. Optional `@Query` values that are `nil` are omitted. For an array `@Query`,
the generated code assigns each element to the key in turn; because `queryParameters` is a
`[String: String]`, the **last element wins** at runtime — identical to a hand-written struct
with the same signature (multi-value query keys are a v1 limitation, not yet supported). Verbs
that take no body (`@GET`, `@DELETE`) report a compile-time diagnostic if you annotate a
property with `@Body`.

## Adding the dependency

The macros live in a **separate package** from the NetKit core. Manual-only consumers depend on
`NetKit` alone and resolve no extra dependencies. To opt into the macros, add `NetKitMacros`
as well. (Within this repository `NetKitMacros` is a companion package that references the core
via a local `path: ".."`; the published two-package form is shown below.)

```swift
dependencies: [
    .package(url: "https://github.com/your-username/NetKit.git", from: "1.0.0"),
    .package(url: "https://github.com/your-username/NetKitMacros.git", from: "1.0.0")
]
```

Then add the products your target needs:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "NetKit", package: "NetKit"),
        .product(name: "NetKitMacros", package: "NetKitMacros")
    ]
)
```

Import `NetKit` for the client and core types, and `NetKitMacros` for the macros:

```swift
import NetKit
import NetKitMacros
```

> The `NetKitMacros` package depends on `swift-syntax` (the Swift macro toolchain). That edge is
> confined to this package — adding it does **not** change NetKit core, which stays dependency-free
> for anyone who only uses the manual `Endpoint` model.
