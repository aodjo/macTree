// swift-tools-version:6.0
import PackageDescription

/**
 * MacTree: one macOS 15+ executable built as the app binary.
 *
 * Release builds use -Ounchecked for the scanner's hot loops. The target links
 * AppKit, Quartz (Quick Look) and UniformTypeIdentifiers (file icons).
 * scripts/build-app.sh wraps the binary into MacTree.app.
 */
let package = Package(
    name: "MacTree",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MacTree",
            path: "Sources/MacTree",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Quartz"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
