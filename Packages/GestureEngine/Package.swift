// swift-tools-version: 6.0
// The gesture maths lives in its own package, apart from the app, so it can be
// tested with `swift test` in a second, against made-up sensor data, without
// AirPods, without a signed app and without launching any window.
import PackageDescription

let package = Package(
    name: "GestureEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GestureEngine", targets: ["GestureEngine"]),
        .executable(name: "compare-approaches", targets: ["CompareApproaches"]),
    ],
    targets: [
        .target(name: "GestureEngine"),
        // Trains every approach on the same recordings and writes score
        // traces for the comparison notebook. Separate from the library so the
        // app never links Create ML's training code.
        .executableTarget(name: "CompareApproaches", dependencies: ["GestureEngine"]),
        .testTarget(name: "GestureEngineTests", dependencies: ["GestureEngine"]),
    ]
)
