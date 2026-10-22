// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NC700LikeKit",
    platforms: [
        // アプリの最低OSは iOS 17。CryptoKit(SHA256)は macOS 10.15+ なので macOS 側は 12 を宣言。
        .iOS(.v17),
        .macOS(.v12),
    ],
    products: [
        .library(name: "NC700LikeKit", targets: ["NC700LikeKit"])
    ],
    targets: [
        .target(name: "NC700LikeKit"),
        .testTarget(name: "NC700LikeKitTests", dependencies: ["NC700LikeKit"])
    ]
)
