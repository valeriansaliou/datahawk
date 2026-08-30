// swift-tools-version: 6.0
// This file backs IDE / LSP support (sourcekit-lsp) and the incremental
// `make app-dev` build. Shipping builds go through `make app`, which uses a
// single optimised `swiftc` invocation — don't call `swift build` by hand.
import PackageDescription

let package = Package(
    name: "DataHawk",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "DataHawk",
            path: "Sources",
            swiftSettings: [
                // Match the Makefile's `swiftc` invocation, which defaults to
                // the Swift 5 language mode.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Network"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("MapKit"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ]
)
