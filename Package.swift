// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Den",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Den", targets: ["DenApp"]),
        .executable(name: "dend", targets: ["dend"]),
    ],
    targets: [
        // Built by scripts/build-libghostty-vt.sh from vendor/ghostty.
        .binaryTarget(name: "GhosttyVt", path: "Frameworks/ghostty-vt.xcframework"),
        .target(name: "CDenPTY"),
        .target(name: "DenVT", dependencies: ["GhosttyVt"]),
        .target(name: "DenProtocol"),
        .target(name: "DenServer", dependencies: ["DenVT", "DenProtocol", "CDenPTY"]),
        .executableTarget(name: "dend", dependencies: ["DenServer"]),
        .executableTarget(
            name: "DenApp",
            dependencies: ["DenVT", "DenProtocol"],
            resources: [.copy("Resources/Fonts"), .copy("Resources/ProgramIcons")],
            swiftSettings: [.define("DEBUG", .when(configuration: .debug))],
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("MetalKit")]
        ),
        .testTarget(name: "DenProtocolTests", dependencies: ["DenProtocol"]),
        .testTarget(name: "DenVTTests", dependencies: ["DenVT"]),
        .testTarget(name: "DenServerTests", dependencies: ["DenServer", "DenProtocol", "DenVT"]),
        .testTarget(name: "DenAppTests", dependencies: ["DenApp"]),
    ]
)
