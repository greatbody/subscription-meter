// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SubscriptionMeter",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SubscriptionMeter", targets: ["SubscriptionMeter"])],
    targets: [.executableTarget(name: "SubscriptionMeter", path: "Sources")]
)
