// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Spleen",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Spleen", targets: ["Spleen"]),
        .executable(name: "SpleenReplay", targets: ["SpleenReplay"])
    ],
    targets: [
        .target(name: "SpleenCore"),
        .target(name: "SpleenEvaluation", dependencies: ["SpleenCore"]),
        .executableTarget(name: "Spleen", dependencies: ["SpleenCore"]),
        .executableTarget(name: "SpleenReplay", dependencies: ["SpleenEvaluation"]),
        .testTarget(name: "SpleenCoreTests", dependencies: ["SpleenCore"]),
        .testTarget(name: "SpleenEvaluationTests", dependencies: ["SpleenEvaluation", "SpleenCore"])
    ]
)
