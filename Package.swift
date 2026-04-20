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
    targets: [
        .executableTarget(
            name: "Wink",
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
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"]),
            ]
        ),
        .testTarget(
            name: "WinkTests",
            dependencies: ["Wink"],
            path: "Tests/WinkTests"
        )
    ]
)
