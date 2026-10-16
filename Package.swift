// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mora",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Mora", targets: ["Mora"]), .executable(name: "MoraBridge", targets: ["MoraBridge"]), .library(name: "FinanceCore", targets: ["FinanceCore"])],
    targets: [
        .target(name: "FinanceCore", resources: [.copy("Resources/Localization")]),
        .executableTarget(name: "Mora", dependencies: ["FinanceCore"]),
        .executableTarget(name: "MoraBridge", dependencies: ["FinanceCore"]),
        .testTarget(name: "FinanceCoreTests", dependencies: ["FinanceCore"])
    ],
    swiftLanguageModes: [.v5]
)
