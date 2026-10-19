// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "HerHis",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CompanionCore", targets: ["CompanionCore"]), .executable(name: "HerHis", targets: ["CompanionApp"]), .executable(name: "CompanionProbe", targets: ["CompanionProbe"])],
    targets: [.target(name: "CompanionCore"), .executableTarget(name: "CompanionApp", dependencies: ["CompanionCore"], resources: [.copy("Resources/realtime.js"), .copy("Resources/doubao.js")]), .executableTarget(name: "CompanionProbe", dependencies: ["CompanionCore"]), .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore"]), .testTarget(name: "CompanionAppTests", dependencies: ["CompanionApp", "CompanionCore"])],
    swiftLanguageModes: [.v5]
)
