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
        // Apple platforms import the SDK's `SQLite3` module; Linux links the system library through this one.
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [.apt(["libsqlite3-dev"]), .yum(["sqlite-devel"])]
        ),
        .target(
            name: "SQLClaimKit",
            dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux]))]
        ),
        .executableTarget(
            name: "SQLClaimDemo",
            dependencies: ["SQLClaimKit"]
        ),
        .testTarget(
            name: "SQLClaimKitTests",
            dependencies: [
                "SQLClaimKit",
                .target(name: "CSQLite", condition: .when(platforms: [.linux]))
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
