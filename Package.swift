// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wink",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Wink", targets: ["Wink"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1")
    ],
    targets: [
        .executableTarget(
            name: "Wink",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Wink",
            exclude: [
                "Resources/Info.plist",
                "Resources/AppIcon.svg",
                "Resources/AppIcon.icns",
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
        .testTarget(
            name: "WinkTests",
            dependencies: ["Wink"],
            path: "Tests/WinkTests"
        )
    ]
)
