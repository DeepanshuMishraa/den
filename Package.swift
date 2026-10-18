// swift-tools-version: 6.2
import PackageDescription

#if os(Linux)
// Linux builds only dend (scripts/build-dend-linux.sh), against the static
// libtermy_engine that script builds; it passes the per-arch -L.
let termyEngine = Target.systemLibrary(name: "CTermyEngine", path: "Frameworks/linux/CTermyEngine")
#else
// Built by scripts/build-libtermy-engine.sh from vendor/termy.
let termyEngine = Target.binaryTarget(name: "CTermyEngine", path: "Frameworks/TermyEngine.xcframework")
#endif

// Absolute: the linker doesn't run from the package root.
let dendInfoPlist = String(#filePath.dropLast("Package.swift".count)) + "Sources/dend/Info.plist"

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
        termyEngine,
        .target(name: "CDenPTY"),
        .target(
            name: "DenVT",
            dependencies: ["CTermyEngine"],
            // Rust's standard library, linked statically, needs libiconv on macOS.
            linkerSettings: [.linkedLibrary("iconv", .when(platforms: [.macOS]))]
        ),
        .target(name: "DenProtocol"),
        .target(name: "DenServer", dependencies: ["DenVT", "DenProtocol", "CDenPTY"]),
        // dend runs as its own launchd job, so macOS asks it (not Den.app)
        // for Desktop/Documents/Downloads access. Without an embedded
        // Info.plist carrying usage strings it can't prompt and is denied.
        .executableTarget(
            name: "dend",
            dependencies: ["DenServer", "DenProtocol", "CDenPTY"],
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags(
                ["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", dendInfoPlist],
                .when(platforms: [.macOS])
            )]
        ),
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
        .testTarget(name: "DenAppTests", dependencies: ["DenApp", "DenVT"]),
    ]
)
