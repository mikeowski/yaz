// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "yaz",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "yaz",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist into the binary's __TEXT,__info_plist
                // section. yaz ships as a single executable with no .app
                // bundle, so this is the only way TCC can attribute the
                // microphone prompt to yaz itself — and read a usage string
                // written for the user — rather than to whatever launched it.
                // parrot omits this and pays for it under launchd.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/yaz/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "yazTests",
            dependencies: ["yaz"]
        ),
    ]
)
