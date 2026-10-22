// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MoMoFan", platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MoMoFan", targets: ["MoMoFan"]),
        .executable(name: "MoMoFanHelper", targets: ["MoMoFanHelper"]),
        .executable(name: "MoMoFanProbe", targets: ["MoMoFanProbe"])
    ],
    targets: [
        .target(name: "CSMC", publicHeadersPath: "include", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "FanCore", dependencies: ["CSMC"]),
        .executableTarget(name: "MoMoFan", dependencies: ["FanCore"], linkerSettings: [.linkedFramework("ServiceManagement"), .linkedFramework("AppKit")]),
        .executableTarget(name: "MoMoFanHelper", dependencies: ["FanCore"]),
        .executableTarget(name: "MoMoFanProbe", dependencies: ["FanCore"]),
        .testTarget(name: "FanCoreTests", dependencies: ["FanCore"])
    ]
)
