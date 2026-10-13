// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Miledge",
    defaultLocalization: "en",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "MiledgeDomain", targets: ["MiledgeDomain"]),
        .library(name: "MiledgeStorage", targets: ["MiledgeStorage"]),
        .library(name: "MiledgeApplication", targets: ["MiledgeApplication"]),
    ],
    targets: [
        .target(name: "MiledgeDomain"),
        .target(name: "MiledgeStorage", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .target(
            name: "MiledgeApplication",
            dependencies: ["MiledgeDomain", "MiledgeStorage"]
        ),
        .testTarget(name: "MiledgeDomainTests", dependencies: ["MiledgeDomain"]),
        .testTarget(name: "MiledgeStorageTests", dependencies: ["MiledgeStorage"]),
        .testTarget(
            name: "MiledgeApplicationTests",
            dependencies: ["MiledgeApplication", "MiledgeDomain", "MiledgeStorage"]
        ),
    ]
)
