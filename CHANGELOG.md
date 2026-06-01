# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
