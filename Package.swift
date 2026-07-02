// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OpenPathTrace",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenPathTraceCore", targets: ["OpenPathTraceCore"]),
        .executable(name: "OpenPathTrace", targets: ["OpenPathTrace"]),
        .executable(name: "OpenPathTraceCoreChecks", targets: ["OpenPathTraceCoreChecks"])
    ],
    targets: [
        .target(name: "OpenPathTraceCore"),
        .executableTarget(
            name: "OpenPathTrace",
            dependencies: ["OpenPathTraceCore"]
        ),
        .executableTarget(
            name: "OpenPathTraceCoreChecks",
            dependencies: ["OpenPathTraceCore"]
        )
    ]
)
