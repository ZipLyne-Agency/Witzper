// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FlowHelper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "flow-helper", targets: ["FlowHelper"])
    ],
    targets: [
        .executableTarget(
            name: "FlowHelper",
            path: "Sources/FlowHelper"
        )
    ]
)
