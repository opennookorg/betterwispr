// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BetterWispr",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BetterWispr", targets: ["BetterWispr"]),
        .executable(name: "BetterWisprCLI", targets: ["BetterWisprCLI"]),
        .library(name: "BetterWisprCore", targets: ["BetterWisprCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(url: "https://github.com/mattt/llama.swift", exact: "2.10549.0")
    ],
    targets: [
        .target(name: "BetterWisprCore", dependencies: [
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
            .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "LlamaSwift", package: "llama.swift")
        ], resources: [.process("Localization/Resources")]),
        .executableTarget(
            name: "BetterWispr",
            dependencies: ["BetterWisprCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "BetterWisprCLI", dependencies: ["BetterWisprCore"]),
        .testTarget(name: "BetterWisprCoreTests", dependencies: ["BetterWisprCore", "BetterWispr"])
    ],
    swiftLanguageModes: [.v6]
)
