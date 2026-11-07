// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "XtoolHarness",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(
            name: "XtoolHarness",
            targets: ["XtoolHarness"]
        ),
        .library(
            name: "XrayTunnel",
            targets: ["XrayTunnel"]
        )
    ],
    dependencies: [
        .package(name: "flutter_v2ray_client", path: "../flutter_v2ray_client")
    ],
    targets: [
        .target(
            name: "XtoolHarness",
            dependencies: [
                .product(name: "flutter_v2ray_client", package: "flutter_v2ray_client")
            ],
            path: "Sources/XtoolHarness"
        ),
        .target(
            name: "XrayTunnel",
            dependencies: [
                .product(name: "flutter_v2ray_client", package: "flutter_v2ray_client")
            ],
            path: "XrayTunnel",
            sources: ["PacketTunnelProvider.swift"]
        )
    ]
)