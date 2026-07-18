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
        .library(name: "PassesBarcode", targets: ["PassesBarcode"]),
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
        // Apple's pure-Swift X.509 + CMS. PassesCore's signature verifier uses it to
        // verify the detached PKCS#7/CMS signature over a pkpass manifest and classify the
        // chain against bundled Apple roots — the iOS analogue of Android's BouncyCastle
        // path (user-approved §7 decision 2026-06-02). Pulls swift-asn1 + swift-crypto
        // transitively. Only PassesCore links it.
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.1"),
    ],
    targets: [
        .target(
            name: "PassesCore",
            dependencies: [
                .product(name: "X509", package: "swift-certificates"),
            ],
            path: "Sources/PassesCore",
            resources: [
                // Bundled Apple trust anchors + WWDR intermediates (mirrors Android's
                // passes-core/resources/.../certs). Loaded at parse time; never fetched.
                .copy("Resources/certs"),
            ]
        ),
        .target(
            name: "PassesBarcode",
            dependencies: ["PassesCore"],
            path: "Sources/PassesBarcode"
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
            dependencies: [
                "PassesCore",
                // Signature-verifier tests synthesize a test root/leaf and CMS-sign a manifest,
                // mirroring swift-certificates' own CMSTests. Only the test target links X509;
                // P256 key generation is reached through a PassesCore test-support shim (which
                // already links Crypto transitively) so swift-crypto need not be a direct dep.
                .product(name: "X509", package: "swift-certificates"),
            ],
            path: "Tests/PassesCoreTests",
            resources: [
                // Real Apple-signed pkpass artifacts (manifest + detached CMS), copied
                // verbatim from the Android side. Regression guard for walt-passes-ios#31.
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "PassesBarcodeTests",
            dependencies: ["PassesBarcode", "PassesCore"],
            path: "Tests/PassesBarcodeTests"
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
