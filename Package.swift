// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NoemaSnitch",
    // Localizations live in Resources/*.lproj and are copied by scripts/build-app.sh.
    platforms: [.macOS(.v14)],
    targets: [
        // Rules, IPC protocol and libproc socket lookup used by both processes.
        .target(name: "NoemaShared", path: "Sources/NoemaShared"),
        // SwiftUI app: connection list, rules, allow/deny prompts.
        .executableTarget(
            name: "NoemaSnitch",
            dependencies: ["NoemaShared"],
            path: "Sources/NoemaSnitch"
        ),
        // Root LaunchDaemon: pf redirection + filtering proxy.
        .executableTarget(
            name: "NoemaHelper",
            dependencies: ["NoemaShared"],
            path: "Sources/NoemaHelper"
        ),
    ]
)
