// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UzDisc",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "UzDisc", targets: ["UzDisc"]),
        .executable(name: "uzdisc-helper", targets: ["uzdisc-helper"]),
        .library(name: "UzDiscCore", targets: ["UzDiscCore"]),
    ],
    targets: [
        .target(
            name: "UzDiscCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "uzdisc-helper",
            dependencies: ["UzDiscCore"]
        ),
        .executableTarget(
            name: "UzDisc",
            dependencies: ["UzDiscCore"]
        ),
        .testTarget(
            name: "UzDiscCoreTests",
            dependencies: ["UzDiscCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
