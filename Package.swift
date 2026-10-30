// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Sapu2",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sapu2", targets: ["SapuApp"]),
        .executable(name: "sapu2-cli", targets: ["SapuCLI"]),
    ],
    targets: [
        .target(name: "SapuCore"),
        .executableTarget(name: "SapuApp", dependencies: ["SapuCore"]),
        .executableTarget(name: "SapuCLI", dependencies: ["SapuCore"]),
    ]
)
