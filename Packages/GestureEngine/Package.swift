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
        .library(name: "GestureLearning", targets: ["GestureLearning"]),
        .executable(name: "compare-approaches", targets: ["CompareApproaches"]),
    ],
    targets: [
        .target(name: "GestureEngine"),
        // The four approaches being compared, shared by the comparison tool
        // and the app's live test so both run exactly the same code.
        .target(name: "GestureLearning", dependencies: ["GestureEngine"]),
        // Trains every approach on the same recordings and writes score
        // traces for the comparison notebook.
        .executableTarget(name: "CompareApproaches", dependencies: ["GestureEngine", "GestureLearning"]),
        .testTarget(name: "GestureEngineTests", dependencies: ["GestureEngine"]),
    ]
)
