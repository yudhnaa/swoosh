// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Swoosh",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "swoosh", targets: ["SwooshApp"]),
        .executable(name: "geometry-trial", targets: ["GeometryTrial"]),
        .executable(name: "lifecycle-trial", targets: ["LifecycleTrial"]),
        .executable(name: "gesture-probe", targets: ["GestureProbe"]),
        .library(name: "SwooshCore", targets: ["SwooshCore"])
    ],
    targets: [
        .target(
            name: "SwooshCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "SwooshApp",
            dependencies: ["SwooshCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "GestureProbe",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "GeometryTrial",
            dependencies: ["SwooshCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .executableTarget(
            name: "LifecycleTrial",
            dependencies: ["SwooshCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .testTarget(
            name: "SwooshCoreTests",
            dependencies: ["SwooshCore"]
        )
    ]
)
