// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Singluse",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Закреплено точной версией: стороннее обновление не попадёт в сборку без проверки.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        // Parakeet от NVIDIA через FluidAudio (Apache 2.0): вторая модель распознавания, быстрее Whisper и точнее на русском.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3"),
    ],
    targets: [
        .target(name: "SingluseCore"),
        .executableTarget(
            name: "Singluse",
            dependencies: [
                "SingluseCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(name: "SingluseCoreTests", dependencies: ["SingluseCore"]),
    ]
)
