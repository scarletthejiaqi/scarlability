// swift-tools-version: 6.2
import PackageDescription

// Platform-independent pieces shared by the iPad and Mac apps: the ink engine, paper drawing,
// and the note files that sync through iCloud Drive.
let package = Package(
    name: "ScarlabilityKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ScarlabilityKit", targets: ["ScarlabilityKit"]),
    ],
    targets: [
        .target(name: "ScarlabilityKit"),
        .testTarget(name: "ScarlabilityKitTests", dependencies: ["ScarlabilityKit"]),
    ]
)
