// swift-tools-version:6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "StudyTracker",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "StudyTracker", targets: ["StudyTracker"]),
        .executable(name: "study-mcp", targets: ["study-mcp"]),
        .library(name: "StudyCore", targets: ["StudyCore"]),
        .library(name: "StudyAI", targets: ["StudyAI"]),
    ],
    targets: [
        // Framework-free domain logic, SQLite repositories, parsers, prompts.
        .target(
            name: "StudyCore",
            swiftSettings: swift5,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // MCP protocol + tool handlers, kept as a library so tests can drive it in-process.
        .target(name: "StudyMCPCore", dependencies: ["StudyCore"], swiftSettings: swift5),
        .executableTarget(name: "study-mcp", dependencies: ["StudyMCPCore"], swiftSettings: swift5),
        // AI engines (cloud, local, Apple), pipelines, chat loop and AI-app connectors. Portable: Apple-only code is
        // behind canImport so the Windows/Linux build can use the rest.
        .target(name: "StudyAI", dependencies: ["StudyCore", "StudyMCPCore"], swiftSettings: swift5),
        // The macOS app.
        .executableTarget(name: "StudyTracker", dependencies: ["StudyCore", "StudyMCPCore", "StudyAI"], swiftSettings: swift5),
        .testTarget(
            name: "StudyCoreTests",
            dependencies: ["StudyCore", "StudyMCPCore", "StudyAI"],
            resources: [.copy("Fixtures")],
            swiftSettings: swift5
        ),
    ]
)
