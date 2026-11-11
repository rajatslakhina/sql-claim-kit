// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SQLClaimKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(name: "SQLClaimKit", targets: ["SQLClaimKit"]),
        .executable(name: "SQLClaimDemo", targets: ["SQLClaimDemo"])
    ],
    targets: [
        .target(name: "SQLClaimKit"),
        .executableTarget(
            name: "SQLClaimDemo",
            dependencies: ["SQLClaimKit"]
        ),
        .testTarget(
            name: "SQLClaimKitTests",
            dependencies: ["SQLClaimKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)
