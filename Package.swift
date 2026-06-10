// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ProxyManager",
    platforms: [
        .macOS(.v13) // MenuBarExtra requires macOS 13+
    ],
    targets: [
        .executableTarget(
            name: "ProxyManager",
            path: "Sources/ProxyManager"
        )
    ]
)
