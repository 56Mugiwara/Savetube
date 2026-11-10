// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SaveTube", platforms: [.macOS(.v13)], products: [.executable(name: "SaveTube", targets: ["SaveTube"])], targets: [.executableTarget(name: "SaveTube")], swiftLanguageVersions: [.v5])
