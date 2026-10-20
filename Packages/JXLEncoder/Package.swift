// swift-tools-version: 6.0
// The JPEG XL encoder that Smart Previews use: libjxl, built by Scripts/build-libjxl.sh into libjxl.xcframework (one
// static arm64 library), and a small C function that encodes a DNG tile with it. Only encoding is bundled; Apple's
// RAW engine decodes JPEG XL itself.
import PackageDescription

let package = Package(
    name: "JXLEncoder",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "JXLEncoder", targets: ["JXLEncoder"]),
    ],
    targets: [
        .binaryTarget(name: "libjxl", path: "libjxl.xcframework"),
        // libjxl is C++, so the app links the C++ standard library for it.
        .target(name: "JXLEncoder", dependencies: ["libjxl"], linkerSettings: [.linkedLibrary("c++")]),
    ]
)
