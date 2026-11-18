// swift-tools-version: 6.0
// The menu bar app. Run apple/build-bindings.sh first; apple/package.sh
// assembles the .app.
import PackageDescription

let package = Package(
    name: "WattsUp",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "WattsUpCoreFFI", path: "Generated/WattsUpCoreFFI.xcframework"),
        .target(
            name: "WattsUpCore",
            dependencies: ["WattsUpCoreFFI"],
            path: "Generated/Swift",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "WattsUp",
            dependencies: ["WattsUpCore"],
            path: "WattsUp",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(name: "Smoke", dependencies: ["WattsUpCore"], path: "Smoke"),
        .testTarget(
            name: "WattsUpTests",
            dependencies: ["WattsUp"],
            path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
