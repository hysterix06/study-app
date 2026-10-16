// swift-tools-version:6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "StudyTracker",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "StudyTracker", targets: ["StudyTracker"]),
        .library(name: "StudyCore", targets: ["StudyCore"]),
    ],
    targets: [
        // Everything but the UI: SQLite, Moodle, calendar files, course files, the book's prompts and chapter parser,
        // Claude Code and the Anthropic API, flashcard scheduling.
        .target(
            name: "StudyCore",
            swiftSettings: swift5,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The macOS app.
        .executableTarget(name: "StudyTracker", dependencies: ["StudyCore"], swiftSettings: swift5),
        .testTarget(
            name: "StudyCoreTests",
            dependencies: ["StudyCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: swift5
        ),
    ]
)
