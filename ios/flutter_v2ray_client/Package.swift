// swift-tools-version: 5.9
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let libXrayXCFrameworkPath = packageDir
    .appendingPathComponent("Frameworks/LibXray.xcframework")
    .standardizedFileURL
    .path
let hasLibXrayXCFramework = FileManager.default.fileExists(atPath: libXrayXCFrameworkPath)

var targetDependencies: [Target.Dependency] = []
var packageTargets: [Target] = []

if hasLibXrayXCFramework {
    packageTargets.append(
        .binaryTarget(
            name: "LibXray",
            path: "Frameworks/LibXray.xcframework"
        )
    )
    targetDependencies.append("LibXray")
}
packageTargets.append(
    .target(
        name: "flutter_v2ray_client",
        dependencies: targetDependencies,
        path: "Classes",
        resources: [
            .copy("Assets/geoip.dat"),
            .copy("Assets/geosite.dat")
        ],
        linkerSettings: [
            .linkedFramework("NetworkExtension"),
            .linkedFramework("SystemConfiguration"),
            .linkedLibrary("resolv"),
            .linkedLibrary("c++")
        ]
    )
)

let package = Package(
    name: "flutter_v2ray_client",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(
            name: "flutter-v2ray-client",
            targets: ["flutter_v2ray_client"]
        ),
        .library(
            name: "flutter_v2ray_client",
            targets: ["flutter_v2ray_client"]
        )
    ],
    targets: packageTargets
)