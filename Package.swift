// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ssclipboard",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ssclipboard",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "ssclipboardTests",
            dependencies: ["ssclipboard"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
