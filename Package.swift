// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Touchward",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic: no IOKit, no AppKit. Runs under `swift test` with no TCC grants.
        .target(name: "TouchwardCore"),
        // System integration: IOHIDManager, CGEvent, AppKit panel.
        // Language mode v5: the IOKit/AX callback bridges are C function pointers that
        // strict concurrency cannot reason about.
        .executableTarget(
            name: "touchward",
            dependencies: ["TouchwardCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "TouchwardCoreTests", dependencies: ["TouchwardCore"]),
    ]
)
