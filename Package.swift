// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HotAppClone",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HotAppClone", targets: ["HotAppClone"])
    ],
    targets: [
        .executableTarget(
            name: "HotAppClone",
            path: "Sources/HotAppClone"
        ),
        .testTarget(
            name: "HotAppCloneTests",
            dependencies: ["HotAppClone"],
            path: "Tests/HotAppCloneTests"
        )
    ]
)
