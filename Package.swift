// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Singluse",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Закреплено точной версией: стороннее обновление не попадёт в сборку без проверки.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .target(name: "SingluseCore"),
        .executableTarget(
            name: "Singluse",
            dependencies: [
                "SingluseCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .testTarget(name: "SingluseCoreTests", dependencies: ["SingluseCore"]),
    ]
)
