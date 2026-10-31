// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyWizard",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MyWizard", targets: ["MyWizard"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7", traits: [])
    ],
    targets: [
        .executableTarget(name: "MyWizard", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .testTarget(name: "MyWizardTests", dependencies: ["MyWizard"])
    ]
)
