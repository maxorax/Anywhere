// swift-tools-version: 6.0
import PackageDescription

// The VK TURN proxy core, built from moroka8/vk-turn-proxy-ios via
//   gomobile bind -target=ios -o Mobile.xcframework ./mobile/ios
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
