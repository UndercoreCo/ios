// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "UndercoreCore", platforms: [.iOS(.v16), .macOS(.v13)], products: [.library(name: "UndercoreCore", targets: ["UndercoreCore"])], targets: [.target(name: "UndercoreCore"), .testTarget(name: "UndercoreCoreTests", dependencies: ["UndercoreCore"])])
