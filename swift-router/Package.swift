// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SwiftRouter",
    products: [
        .library(name: "RouterLib", targets: ["RouterLib"]),
        .executable(name: "RouterCLI", targets: ["RouterCLI"]),
    ],
    targets: [
        .target(name: "RouterLib"),
        .executableTarget(name: "RouterCLI", dependencies: ["RouterLib"]),
    ]
)
