// swift-tools-version: 6.0
import PackageDescription

// Local stand-in for the upstream `TurnRules` package, which lives at
// https://github.com/hiDandelion/TurnRules.git and is not public (404).
// Upstream ships a prebuilt `Rules.db` — the built-in routing rule sets,
// country-bypass lists and service catalog. This package reproduces only the
// API surface the app actually uses (`TurnRules.databaseURL`) plus a
// schema-correct, empty database, so the project builds from source.
let package = Package(
    name: "TurnRules",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v18), .watchOS(.v11)],
    products: [
        .library(name: "TurnRules", targets: ["TurnRules"])
    ],
    targets: [
        .target(
            name: "TurnRules",
            path: "Sources/TurnRules",
            resources: [.copy("Resources/Rules.db")]
        )
    ]
)
