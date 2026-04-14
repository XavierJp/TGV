// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TGV",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TGV", targets: ["TGV"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.8.0"),
    ],
    targets: [
        .target(
            name: "Core",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
            ],
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "TGV",
            dependencies: [
                "Core",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/TGV"
        ),
    ]
)
