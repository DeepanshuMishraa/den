// swift-tools-version: 6.2
import PackageDescription

#if os(Linux)
// Linux builds only dend (scripts/build-dend-linux.sh), against the static
// libghostty-vt that script builds; it passes the per-arch -L.
let ghosttyVt = Target.systemLibrary(name: "GhosttyVt", path: "Frameworks/linux/GhosttyVt")
#else
// Built by scripts/build-libghostty-vt.sh from vendor/ghostty.
let ghosttyVt = Target.binaryTarget(name: "GhosttyVt", path: "Frameworks/ghostty-vt.xcframework")
#endif

let package = Package(
    name: "Den",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Den", targets: ["DenApp"]),
        .executable(name: "dend", targets: ["dend"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
    targets: [
        ghosttyVt,
        .target(name: "CDenPTY"),
        .target(name: "DenVT", dependencies: ["GhosttyVt"]),
        .target(name: "DenProtocol"),
        .target(name: "DenServer", dependencies: ["DenVT", "DenProtocol", "CDenPTY"]),
        .executableTarget(name: "dend", dependencies: ["DenServer", "DenProtocol", "CDenPTY"]),
        .executableTarget(
            name: "DenApp",
            dependencies: ["DenVT", "DenProtocol", "Sparkle"],
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
