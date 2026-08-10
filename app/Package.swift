// swift-tools-version: 6.0
//
// 6.0 and not 5.9 because swift-testing is only wired into the test target from
// 6.0 onward. Under 5.9 `import Testing` does not resolve at all, and the suite
// sat in the repository uncompiled and unrun for several rounds — which is worse
// than having no tests, because it reads as coverage.
//
// This manifest is what builds the app and what runs its tests. The shipped
// .app bundle is assembled by `scripts/package.sh` from the binary this
// produces; `project.yml` still generates an Xcode project, but that is for
// debugging in the IDE, not for shipping.

import PackageDescription

let package = Package(
    name: "Violeet",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.15.0")
        // No swift-testing package here: `Testing` comes from the toolchain.
        //
        // It used to be taken as a package because Command Line Tools shipped
        // only `libTestingMacros.dylib` and not the `Testing` library itself, so
        // `import Testing` did not resolve without a full Xcode install. That is
        // no longer the trade being made: the package has since started warning
        // on every single `@Test` and `@Suite` in the suite — 381 deprecations,
        // measured — telling us to drop it because Swift 6 bundles its own.
        //
        // CI is the machine that runs the tests, and it selects Xcode 16.4
        // (`.github/workflows/app-ci.yml`), whose toolchain has `Testing`. The
        // cost is that a contributor with only Command Line Tools can build and
        // package but cannot `swift test` — which is what the CI comment on the
        // test step already says about `XCTest`, and CI is where that gate runs.
    ],
    targets: [
        .executableTarget(
            name: "Violeet",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/Violeet",
            // Info.plist is consumed by the Xcode target, not by SwiftPM; the
            // per-directory READMEs are orientation for humans, not resources.
            exclude: [
                "Info.plist",
                "Terminal/README.md",
                "Sidebar/README.md",
                "Daemon/README.md",
            ],
            // The manifest is 6.0 only so the test target gets swift-testing.
            // The *language mode* stays 5: Swift 6 strict concurrency rejects
            // three places in `DaemonClient` where `self` crosses onto the
            // reader thread, and migrating that is real work with real risk to
            // the reconnect path — not something to smuggle in alongside a
            // change whose whole point was to make the tests runnable.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Tests the wire projection, and for now only the wire projection.
        //
        // That is not where the code is; it is where a mistake is *silent*.
        // Everything else in the app fails loudly — a broken PTY is a dead tab,
        // a broken socket is an offline badge. The sparse-patch decoder fails by
        // rendering a value the session no longer has, which looks like a daemon
        // bug from the outside and points nowhere near this file.
        .testTarget(
            name: "VioleetTests",
            dependencies: [
                "Violeet",
            ],
            path: "Tests/VioleetTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
