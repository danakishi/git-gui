// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "GitGui",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "GitGui", targets: ["GitGui"]),
        .library(name: "GitCore", targets: ["GitCore"]),
    ],
    targets: [
        // Running git and parsing its output. No UI.
        .target(name: "GitCore"),
        // Laying out the commit graph into lanes. Pure functions.
        .target(name: "GraphLayout", dependencies: ["GitCore"]),
        // GitHub and GitLab: PR/MR, CI status.
        .target(name: "Hosting", dependencies: ["GitCore"]),
        // The app itself.
        .executableTarget(
            name: "GitGui",
            dependencies: ["GitCore", "GraphLayout", "Hosting"]
        ),
        .testTarget(name: "GitCoreTests", dependencies: ["GitCore"]),
        .testTarget(name: "GraphLayoutTests", dependencies: ["GraphLayout"]),
    ]
)
