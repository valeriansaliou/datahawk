// swift-tools-version: 5.9
// This file exists solely for IDE / LSP support (sourcekit-lsp).
// The project is built with the Makefile — do not use `swift build`.
import PackageDescription

let package = Package(
    name: "DataHawk",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DataHawk",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Network"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreLocation"),
            ]
        )
    ]
)
