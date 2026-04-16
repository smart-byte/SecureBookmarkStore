// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SecureBookmarkStore",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "SecureBookmarkStore",
            targets: ["SecureBookmarkStore"]
        ),
    ],
    targets: [
        .target(
            name: "SecureBookmarkStore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "SecureBookmarkStoreTests",
            dependencies: ["SecureBookmarkStore"]
        ),
    ]
)
