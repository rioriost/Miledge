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
    dependencies: [
        .package(url: "https://github.com/PhoneNumberKit/PhoneNumberKit", exact: "5.0.12"),
    ],
    targets: [
        .target(name: "MiledgeDomain"),
        .target(name: "MiledgeStorage", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .target(
            name: "MiledgeApplication",
            dependencies: ["MiledgeDomain", "MiledgeStorage", .product(name: "PhoneNumberKit", package: "PhoneNumberKit")],
            resources: [.copy("Resources/PostalRules.json"), .copy("Resources/ThirdPartyNotices.txt")]
        ),
        .testTarget(name: "MiledgeDomainTests", dependencies: ["MiledgeDomain"]),
        .testTarget(name: "MiledgeStorageTests", dependencies: ["MiledgeStorage"]),
        .testTarget(
            name: "MiledgeApplicationTests",
            dependencies: ["MiledgeApplication", "MiledgeDomain", "MiledgeStorage"]
        ),
    ]
)
