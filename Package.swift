// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SunFirebaseEventStudio",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SunFirebaseEventStudio", targets: ["SunFirebaseEventStudio"])],
    targets: [.executableTarget(name: "SunFirebaseEventStudio")]
)
