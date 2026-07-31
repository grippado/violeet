// swift-tools-version: 5.9
//
// This manifest is what builds the app and what runs its tests. The shipped
// .app bundle is assembled by `scripts/package.sh` from the binary this
// produces; `project.yml` still generates an Xcode project, but that is for
// debugging in the IDE, not for shipping.

import PackageDescription

let package = Package(
    name: "AITerm",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.15.0")
    ],
    targets: [
        .executableTarget(
            name: "AITerm",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/AITerm",
            // Info.plist is consumed by the Xcode target, not by SwiftPM; the
            // per-directory READMEs are orientation for humans, not resources.
            exclude: [
                "Info.plist",
                "Terminal/README.md",
                "Sidebar/README.md",
                "Daemon/README.md",
            ]
        ),
        // Tests the wire projection, and for now only the wire projection.
        //
        // That is not where the code is; it is where a mistake is *silent*.
        // Everything else in the app fails loudly — a broken PTY is a dead tab,
        // a broken socket is an offline badge. The sparse-patch decoder fails by
        // rendering a value the session no longer has, which looks like a daemon
        // bug from the outside and points nowhere near this file.
        .testTarget(
            name: "AITermTests",
            dependencies: ["AITerm"],
            path: "Tests/AITermTests"
        ),
    ]
)
