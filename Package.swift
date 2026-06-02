// swift-tools-version: 6.0

import PackageDescription

// Mirrors `walt-passes-android`'s 7-module split 1:1:
//   passes-core    -> PassesCore     (entity types, importer/parser surface)
//   passes-pdf-core -> PassesPDFCore (PDF parsing primitives)
//   passes-pdf     -> PassesPDF      (PDF importer; depends on PassesPDFCore)
//   passes-pdf-ui  -> PassesPDFUI    (PDF rendering UI)
//   passes-storage -> PassesStorage  (encrypted storage + auto-backup guards)
//   passes-ui-core -> PassesUICore   (shared UI primitives: ArgbColor, BidiIsolation)
//   passes-ui      -> PassesUI       (pass list/detail UI)
//
// Targets are scaffold-level; the per-module ports flesh them out.

let package = Package(
    name: "walt-passes-ios",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PassesCore", targets: ["PassesCore"]),
        .library(name: "PassesPDFCore", targets: ["PassesPDFCore"]),
        .library(name: "PassesPDF", targets: ["PassesPDF"]),
        .library(name: "PassesPDFUI", targets: ["PassesPDFUI"]),
        .library(name: "PassesStorage", targets: ["PassesStorage"]),
        .library(name: "PassesUICore", targets: ["PassesUICore"]),
        .library(name: "PassesUI", targets: ["PassesUI"]),
    ],
    dependencies: [
        // Vanilla GRDB over Apple's built-in SQLite. Encryption-at-rest is provided by
        // iOS Data Protection (FileProtectionType.complete) on the DB file, NOT SQLCipher
        // (ios-b1f epic decision 2026-06-02). Only PassesStorage links it.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
    ],
    targets: [
        .target(
            name: "PassesCore",
            dependencies: [],
            path: "Sources/PassesCore"
        ),
        .target(
            name: "PassesPDFCore",
            dependencies: [],
            path: "Sources/PassesPDFCore"
        ),
        .target(
            name: "PassesPDF",
            dependencies: ["PassesPDFCore", "PassesCore"],
            path: "Sources/PassesPDF"
        ),
        .target(
            name: "PassesPDFUI",
            dependencies: ["PassesPDFCore", "PassesPDF", "PassesUICore"],
            path: "Sources/PassesPDFUI"
        ),
        .target(
            name: "PassesStorage",
            dependencies: [
                "PassesCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/PassesStorage"
        ),
        .target(
            name: "PassesUICore",
            dependencies: [],
            path: "Sources/PassesUICore"
        ),
        .target(
            name: "PassesUI",
            dependencies: ["PassesCore", "PassesUICore"],
            path: "Sources/PassesUI"
        ),
        .testTarget(
            name: "PassesCoreTests",
            dependencies: ["PassesCore"],
            path: "Tests/PassesCoreTests"
        ),
        .testTarget(
            name: "PassesPDFCoreTests",
            dependencies: ["PassesPDFCore"],
            path: "Tests/PassesPDFCoreTests"
        ),
        .testTarget(
            name: "PassesPDFTests",
            dependencies: ["PassesPDF", "PassesPDFCore", "PassesCore"],
            path: "Tests/PassesPDFTests"
        ),
        .testTarget(
            name: "PassesPDFUITests",
            dependencies: ["PassesPDFUI"],
            path: "Tests/PassesPDFUITests"
        ),
        .testTarget(
            name: "PassesStorageTests",
            dependencies: ["PassesStorage", "PassesCore"],
            path: "Tests/PassesStorageTests"
        ),
        .testTarget(
            name: "PassesUICoreTests",
            dependencies: ["PassesUICore"],
            path: "Tests/PassesUICoreTests"
        ),
        .testTarget(
            name: "PassesUITests",
            dependencies: ["PassesUI", "PassesCore", "PassesUICore"],
            path: "Tests/PassesUITests"
        ),
    ]
)
