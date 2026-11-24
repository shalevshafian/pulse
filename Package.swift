// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pulse",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PulseSMART", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "PulseCore", dependencies: ["PulseSMART"]),
        .executableTarget(name: "Pulse", dependencies: ["PulseCore"]),
        .testTarget(name: "PulseCoreTests", dependencies: ["PulseCore"]),
    ]
)
