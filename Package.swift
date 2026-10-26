// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "free-the-icloud",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FreeTheICloud", targets: ["FreeTheICloud"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "FreeTheICloudCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "FreeTheICloud", dependencies: ["FreeTheICloudCore"]),
        .executableTarget(name: "CoreChecks", dependencies: ["FreeTheICloudCore"], path: "Tests/FreeTheICloudCoreTests")
    ]
)
