// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fader",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "Fader", targets: ["Fader"]),
        .executable(name: "fader-probe", targets: ["FaderProbe"]),
        .library(name: "FaderCore", targets: ["FaderCore"]),
    ],
    targets: [
        .target(name: "FaderCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Fader", dependencies: ["FaderCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "FaderProbe", dependencies: ["FaderCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FaderCoreTests", dependencies: ["FaderCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
