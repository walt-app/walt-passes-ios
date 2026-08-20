// swift-tools-version: 6.0

import PackageDescription

// Mirrors `walt-passes-android`'s module split:
//   passes-core    -> PassesCore     (entity types, importer/parser surface)
//   passes-pdf-core -> PassesPDFCore (PDF parsing primitives)
//   passes-pdf     -> PassesPDF      (PDF importer; depends on PassesPDFCore)
//   passes-pdf-ui  -> PassesPDFUI    (PDF rendering UI)
//   passes-storage -> PassesStorage  (encrypted storage + auto-backup guards)
//   passes-barcode -> PassesBarcode  (bounded Vision barcode decode)
//   passes-image   -> PassesImage    (bounded image decode-and-retain; PassesImageDecode beneath)
//   passes-document -> PassesDocument (sniff-and-branch import + composite confirm seam)
//   passes-ui-core -> PassesUICore   (shared UI primitives: ArgbColor, BidiIsolation, faceIsTinted)
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
        .library(name: "PassesImage", targets: ["PassesImage"]),
        .library(name: "PassesDocument", targets: ["PassesDocument"]),
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
            // Shared header-gated decode mechanism (Android passes-image-decode
            // mirror); rationale in docs/adr/image-decode-1.md.
            name: "PassesImageDecode",
            dependencies: [],
            path: "Sources/PassesImageDecode"
        ),
        .target(
            name: "PassesBarcode",
            dependencies: ["PassesCore", "PassesImageDecode"],
            path: "Sources/PassesBarcode"
        ),
        .target(
            // In-process bounded image decode-and-retain (§7-approved ios-dts.2);
            // policy + terms in docs/adr/image-decode-1.md.
            name: "PassesImage",
            dependencies: ["PassesImageDecode"],
            path: "Sources/PassesImage"
        ),
        .target(
            // Sniff-and-branch import orchestration (Android passes-document
            // mirror, §7-approved ios-dts.3): the single place the PDF and image
            // peers meet — they gain no edge to each other.
            name: "PassesDocument",
            dependencies: ["PassesCore", "PassesPDFCore", "PassesPDF", "PassesImage", "PassesBarcode"],
            path: "Sources/PassesDocument"
        ),
        .target(
            name: "PassesPDFCore",
            // PassesCore edge for ScannableFormat on the composite arm (mirror of
            // Android 87e6752's pure api edge; adds no platform dependency).
            dependencies: ["PassesCore"],
            path: "Sources/PassesPDFCore"
        ),
        .target(
            name: "PassesPDF",
            dependencies: ["PassesPDFCore", "PassesCore"],
            path: "Sources/PassesPDF"
        ),
        .target(
            name: "PassesPDFUI",
            // No PassesPDF dependency (ios-dts.16 render-once): the display layer is
            // compile-time incapable of reaching a PDF parser. Pages arrive as stored
            // Walt-produced rasters via PassesPDFCore.DocumentPageSource. PassesImage
            // is the image arm's bounded decode (ios-dts.4, the Android
            // passes-document-ui -> passes-image edge).
            dependencies: ["PassesPDFCore", "PassesUICore", "PassesImage"],
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
                // mirroring swift-certificates' own CMSTests. Key generation and CMS signing live in
                // SignatureTestSupport.swift here, never in the shipped kernel.
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
            name: "PassesDocumentTests",
            // PassesStorage: the ImageFormat roster-parity guard only.
            dependencies: ["PassesDocument", "PassesCore", "PassesStorage"],
            path: "Tests/PassesDocumentTests"
        ),
        .testTarget(
            name: "PassesImageDecodeTests",
            dependencies: ["PassesImageDecode"],
            path: "Tests/PassesImageDecodeTests"
        ),
        .testTarget(
            name: "PassesImageTests",
            dependencies: ["PassesImage"],
            path: "Tests/PassesImageTests"
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
