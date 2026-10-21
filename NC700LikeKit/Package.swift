// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NC700LikeKit",
    products: [
        .library(name: "NC700LikeKit", targets: ["NC700LikeKit"])
    ],
    targets: [
        .target(name: "NC700LikeKit"),
        .testTarget(name: "NC700LikeKitTests", dependencies: ["NC700LikeKit"])
    ]
)
