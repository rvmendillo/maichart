// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MaiCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "MaiCore", targets: ["MaiCore"]),
        .executable(name: "maicli", targets: ["maicli"]),
    ],
    targets: [
        .target(
            name: "CLAME",
            path: "Sources/CLAME",
            exclude: ["LICENSE-LGPL.txt"],
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "CMiniMP3",
            path: "Sources/CMiniMP3",
            exclude: ["LICENSE-CC0.txt"]
        ),
        .target(
            name: "MaiCore",
            dependencies: ["CLAME", "CMiniMP3"],
            path: "Sources/MaiCore"
        ),
        .executableTarget(
            name: "maicli",
            dependencies: ["MaiCore"],
            path: "Sources/maicli"
        ),
        .testTarget(
            name: "MaiCoreTests",
            dependencies: ["MaiCore"],
            path: "Tests/MaiCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
