// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Quickey",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Quickey", targets: ["Quickey"])
    ],
    targets: [
        .executableTarget(
            name: "Quickey",
            path: "Sources/Quickey",
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"]),
            ]
        ),
        .testTarget(
            name: "QuickeyTests",
            dependencies: ["Quickey"],
            path: "Tests/QuickeyTests"
        )
    ]
)
