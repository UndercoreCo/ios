// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "UndercoreVPNCore", platforms: [.iOS(.v16), .macOS(.v14)],
    products: [.library(name: "UndercoreVPNCore", targets: ["UndercoreVPNCore"])],
    dependencies: [.package(path: "../.build-deps/AWGKit"), .package(path: "../../undercore-ios/Core")],
    targets: [
        .target(name: "UndercoreVPNCore", dependencies: [.product(name: "WireGuardConfiguration", package: "AWGKit"), .product(name: "UndercoreCore", package: "Core")]),
        .testTarget(name: "UndercoreVPNCoreTests", dependencies: ["UndercoreVPNCore"])
    ])
