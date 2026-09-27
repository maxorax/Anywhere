// swift-tools-version: 6.0
import PackageDescription

// The VK TURN proxy core, built from ~/Desktop/vk-turn-core (branch `mobile`,
// Moroka8/vk-turn-proxy plus the mobile bridge) via
//   scripts/build-mobile.sh ios
// It exposes `IosTurn` (see pkg/vkturn): start the proxy, wait for its local
// listener, read structured state. Only the Network Extension links it — the
// tunnel process is where the proxy has to live.
let package = Package(
    name: "TurnCore",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "Mobile", targets: ["Mobile"])
    ],
    targets: [
        .binaryTarget(name: "Mobile", path: "Frameworks/Mobile.xcframework")
    ]
)
