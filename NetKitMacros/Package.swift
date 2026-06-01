// swift-tools-version: 6.2
// Standalone macro package for NetKit.
//
// This package is intentionally separate from the core NetKit package so that the
// `swift-syntax` dependency (required by the macro compiler plugin) lives entirely
// outside the core NetKit dependency graph. Consumers that only use the manual
// `Endpoint` model depend on `NetKit` alone and never resolve or clone `swift-syntax`.
// Consumers that want the declarative macros add a dependency on this package.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "NetKitMacros",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        // Public macro declarations. Importing this product is what opts a consumer
        // into the macro tooling (and, transitively, the swift-syntax build edge).
        .library(
            name: "NetKitMacros",
            targets: ["NetKitMacros"]
        ),
    ],
    dependencies: [
        // swift-syntax is consumed ONLY by the `.macro` implementation target below.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
        // The dependency-free core package, referenced so the macros can target `Endpoint`.
        .package(name: "NetKit", path: "..")
    ],
    targets: [
        // Macro implementation — built as a compiler plugin. This is the ONLY target
        // that depends on swift-syntax.
        .macro(
            name: "NetKitMacrosImpl",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ]
        ),
        // Public macro declarations. Depends on NetKit (for the `Endpoint` protocol the
        // macros conform to) and on the plugin that implements the expansions.
        .target(
            name: "NetKitMacros",
            dependencies: [
                "NetKitMacrosImpl",
                .product(name: "NetKit", package: "NetKit")
            ]
        ),
        .testTarget(
            name: "NetKitMacrosTests",
            dependencies: [
                "NetKitMacros",
                .product(name: "NetKit", package: "NetKit"),
                // The macro implementation target + test support enable
                // `assertMacroExpansion` against the generated syntax tree. The
                // `.macro` plugin is a host (macOS) tool and cannot be linked into an
                // iOS-simulator test bundle, so these edges — and the expansion tests
                // that use them (guarded by `#if os(macOS)`) — are macOS-only. The
                // end-to-end behavior tests run on every platform.
                .target(name: "NetKitMacrosImpl", condition: .when(platforms: [.macOS])),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax", condition: .when(platforms: [.macOS])),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax", condition: .when(platforms: [.macOS]))
            ]
        ),
    ]
)
