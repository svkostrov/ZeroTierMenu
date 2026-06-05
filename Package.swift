// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZeroTierMenu",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ZeroTierMenu", targets: ["ZeroTierMenu"])
    ],
    targets: [
        .executableTarget(
            name: "ZeroTierMenu",
            path: "Sources/ZeroTierMenu"
        )
    ]
)
