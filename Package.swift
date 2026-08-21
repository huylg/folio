// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.4.0"),
    ],
    targets: [
        .target(
            name: "FolioKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/FolioKit"
        ),
        .executableTarget(
            name: "Folio",
            dependencies: ["FolioKit"],
            path: "Sources/Folio"
        ),
        .testTarget(
            name: "FolioKitTests",
            dependencies: ["FolioKit"],
            path: "Tests/FolioKitTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
