// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wink",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Wink", targets: ["Wink"]),
        .executable(
            name: "WinkFocusIntentsExtension",
            targets: ["WinkFocusIntentsExtension"]
        ),
    ],
    dependencies: [
        // 2.9.5 is the floor: 2.9.1 is affected by CVE-2026-47122 and
        // CVE-2026-47121, and 2.9.5 carries the complete fix for the latter
        // (GHSA-gmj2-gq3j-vqmj covers `<= 2.9.4`). See issue #447.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5")
    ],
    targets: [
        .executableTarget(
            name: "Wink",
            dependencies: [
                "WinkIntents",
                "WinkFocusShared",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Wink",
            exclude: [
                "Resources/Info.plist",
                "Resources/AppIcon.svg",
                "Resources/AppIcon.icns",
                "Resources/MenuBarTemplate.svg",
                "Resources/Localizable.xcstrings",
                "Resources/AppShortcuts.xcstrings",
            ],
            resources: [
                .process("Resources/MenuBarAssets.xcassets"),
                .process("Resources/MenuBarTemplate.png"),
                .process("Resources/MenuBarTemplate@2x.png"),
                .process("Resources/Localized"),
            ],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .unsafeFlags([
                    "-F/System/Library/PrivateFrameworks",
                    "-framework", "SkyLight",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../Frameworks",
                ]),
            ]
        ),
        .target(
            name: "WinkIntents",
            path: "Sources/WinkIntents"
        ),
        .target(
            name: "WinkFocusShared",
            path: "Sources/WinkFocusShared"
        ),
        .target(
            name: "WinkFocusIntents",
            dependencies: ["WinkFocusShared"],
            path: "Sources/WinkFocusIntents"
        ),
        .executableTarget(
            name: "WinkFocusIntentsExtension",
            dependencies: ["WinkFocusIntents"],
            path: "Sources/WinkFocusIntentsExtension",
            exclude: ["Info.plist", "entitlements.plist"]
        ),
        .testTarget(
            name: "WinkTests",
            dependencies: ["Wink", "WinkIntents", "WinkFocusShared", "WinkFocusIntents"],
            path: "Tests/WinkTests"
        )
    ]
)
