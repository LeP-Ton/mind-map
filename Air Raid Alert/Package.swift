// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "AirRaidAlert",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "AirRaidAlert",
            resources: [
                .copy("Resources/air-raid-siren.wav"),
                .copy("Resources/siren-attribution.txt")
            ]
        ),
        .testTarget(name: "AirRaidAlertTests", dependencies: ["AirRaidAlert"])
    ]
)
