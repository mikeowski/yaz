// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "yaz",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "yaz",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Sparkle", package: "Sparkle"),
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
                    // Sparkle is weak-linked. The same binary is also
                    // installed on its own as a CLI (scripts/install.sh),
                    // where no Sparkle.framework sits next to it; a strong
                    // link would stop it at launch with a dyld error. Only
                    // the .app embeds the framework, and only the .app
                    // touches Sparkle (see Updates.swift).
                    "-Xlinker", "-weak_framework",
                    "-Xlinker", "Sparkle",
                    // Where the .app keeps it.
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .testTarget(
            name: "yazTests",
            dependencies: ["yaz"]
        ),
    ]
)
