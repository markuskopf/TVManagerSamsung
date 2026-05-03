// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TVSenderManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TVSenderManager",
            path: "Sources/TVSenderManager",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
