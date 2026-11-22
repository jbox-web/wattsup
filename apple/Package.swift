// swift-tools-version: 6.0
// The menu bar app. Run apple/build-bindings.sh first; apple/package.sh
// assembles the .app.
import PackageDescription

let package = Package(
    name: "WattsUp",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Updates from the GitHub Releases (appcast.xml, EdDSA-signed .pkg).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
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
            dependencies: ["WattsUpCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "WattsUp",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework is copied into Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
