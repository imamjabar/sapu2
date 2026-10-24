// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Sapu",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sapu", targets: ["SapuApp"]),
        .executable(name: "sapu-cli", targets: ["SapuCLI"]),
    ],
    targets: [
        .target(name: "SapuCore"),
        .executableTarget(name: "SapuApp", dependencies: ["SapuCore"]),
        .executableTarget(name: "SapuCLI", dependencies: ["SapuCore"]),
    ]
)
