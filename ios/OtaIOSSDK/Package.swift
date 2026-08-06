// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OtaIOSSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v14)
    ],
    products: [
        .library(name: "OtaIOSSDK", targets: ["OtaIOSSDK"])
    ],
    targets: [
        .target(
            name: "OtaIOSSDK",
            path: "Sources/OtaIOSSDK"
        ),
        .testTarget(
            name: "OtaIOSSDKTests",
            dependencies: ["OtaIOSSDK"],
            path: "Tests/OtaIOSSDKTests"
        )
    ]
)
