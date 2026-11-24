// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LearningCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "LearningCore", targets: ["LearningCore"])],
    targets: [
        .target(name: "LearningCore"),
        .executableTarget(name: "LearningCoreChecks", dependencies: ["LearningCore"], path: "Checks")
    ]
)
