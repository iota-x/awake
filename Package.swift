// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Awake",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Awake",
            path: "Sources/Awake",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]
        ),
    ]
)
