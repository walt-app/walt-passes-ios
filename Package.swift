// swift-tools-version: 6.0

import PackageDescription

// Mirrors `walt-passes-android`'s module split:
//   passes-core    -> PassesCore     (entity types, importer/parser surface)
//   passes-pdf     -> PassesPDF      (PDF importer + bounded renderer)
//   passes-storage -> PassesStorage  (encrypted storage + auto-backup guards)
//
// All targets are intentionally minimal scaffolding for the repo standup
// (ios-382.10). The Passes feature epic (ios-382.11) fleshes them out.

let package = Package(
    name: "passes-iOS",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PassesCore", targets: ["PassesCore"]),
        .library(name: "PassesPDF", targets: ["PassesPDF"]),
        .library(name: "PassesStorage", targets: ["PassesStorage"]),
    ],
    targets: [
        .target(
            name: "PassesCore",
            dependencies: [],
            path: "Sources/PassesCore"
        ),
        .target(
            name: "PassesPDF",
            dependencies: ["PassesCore"],
            path: "Sources/PassesPDF"
        ),
        .target(
            name: "PassesStorage",
            dependencies: ["PassesCore"],
            path: "Sources/PassesStorage"
        ),
        .testTarget(
            name: "PassesCoreTests",
            dependencies: ["PassesCore"],
            path: "Tests/PassesCoreTests"
        ),
        .testTarget(
            name: "PassesPDFTests",
            dependencies: ["PassesPDF", "PassesCore"],
            path: "Tests/PassesPDFTests"
        ),
        .testTarget(
            name: "PassesStorageTests",
            dependencies: ["PassesStorage", "PassesCore"],
            path: "Tests/PassesStorageTests"
        ),
    ]
)
