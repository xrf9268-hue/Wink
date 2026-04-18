// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Quickey",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1")
    ],
    products: [
        .executable(name: "Quickey", targets: ["Quickey"])
    ],
    targets: [
        .executableTarget(
            name: "Quickey",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Quickey",
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
                    "-rpath", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .testTarget(
            name: "QuickeyTests",
            dependencies: ["Quickey"],
            path: "Tests/QuickeyTests"
        )
    ]
)
