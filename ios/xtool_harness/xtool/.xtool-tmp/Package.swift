// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "XtoolHarness-Builder",
    platforms: [
        .iOS("15.0"),
    ],
    dependencies: [
        .package(name: "RootPackage", path: "../.."),
    ],
    targets: [
        .executableTarget(
    name: "XtoolHarness-App",
    dependencies: [
        .product(name: "XtoolHarness", package: "RootPackage"),
    ],
    linkerSettings: [
    .unsafeFlags([
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
    ]),
]
),
.executableTarget(
    name: "XrayTunnel-Extension",
    dependencies: [
        .product(name: "XrayTunnel", package: "RootPackage"),
    ],
    linkerSettings: [
    // Link to Foundation framework which implements the _NSExtensionMain entrypoint
    .linkedFramework("Foundation"),
    .unsafeFlags([
        // Set the entry point to Foundation`_NSExtensionMain
        "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
        // Include frameworks that the host app may use
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../Frameworks",
        // ...as well as our own
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
    ]),
]
)
    ]
)
