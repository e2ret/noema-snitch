import AppKit
import NoemaShared

/// `--demo` fills the UI with sample data; `--snapshot <dir>` saves every
/// window of this app as PNG (no Screen Recording permission needed).
@MainActor
enum Demo {
    static var isEnabled: Bool { CommandLine.arguments.contains("--demo") }

    static var snapshotDirectory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func load(model: NetworkModel, helper: HelperClient) {
        // Real, well-known addresses so the globe shows arcs all over the world.
        let ips = ["8.8.8.8", "151.101.1.140", "185.199.108.153", "91.198.174.192", "77.88.55.88",
                   "13.107.42.14", "31.13.72.36", "52.95.110.1", "202.12.27.33", "104.16.132.229",
                   "1.0.0.1", "203.208.40.1", "195.82.146.214", "185.15.59.224", "142.250.74.46"]
        let apps: [(String, String, [(String, Int64)])] = [
            ("/System/Applications/Music.app/Contents/MacOS/Music", "Music",
             [("amp-api.music.apple.com", 900_000), ("play.itunes.apple.com", 300_000)]),
            ("/Applications/Safari.app/Contents/MacOS/Safari", "Safari",
             [("www.apple.com", 2_400_000), ("obdev.at", 400_000), ("ads-network.com", 0),
              ("youtube.com", 5_000_000), ("i.ytimg.com", 800_000), ("fonts.gstatic.com", 90_000),
              ("github.com", 300_000)]),
            ("/System/Applications/App Store.app/Contents/MacOS/App Store", "App Store",
             [("apps.apple.com", 150_000)]),
            ("/System/Applications/Weather.app/Contents/MacOS/Weather", "Weather",
             [("weatherkit.apple.com", 40_000)]),
            ("/System/Applications/Messages.app/Contents/MacOS/Messages", "Messages",
             [("init.ess.apple.com", 20_000)]),
            ("/System/Applications/Mail.app/Contents/MacOS/Mail", "Mail",
             [("imap.mail.com", 600_000)]),
        ]
        let now = Int(Date().timeIntervalSince1970)
        for second in stride(from: now - 600, through: now, by: 1) {
            var entries: [TrafficEntry] = []
            for (a, (path, name, hosts)) in apps.enumerated() {
                for (h, (host, weight)) in hosts.enumerated() where weight > 0 && Int.random(in: 0..<6) == 0 {
                    entries.append(TrafficEntry(
                        executablePath: path, appName: name, pid: 400, host: host,
                        ip: ips[(a * 3 + h) % ips.count], port: 443,
                        sent: Int64.random(in: 0...(weight / 20)), received: Int64.random(in: 0...weight / 4), active: 1))
                }
            }
            model.ingest(date: Date(timeIntervalSince1970: TimeInterval(second)), entries: entries)
        }
        model.ingest(event: TrafficEvent(pid: 401, executablePath: apps[1].0, appName: "Safari",
                                         remoteIP: "203.0.113.7", remotePort: 443, host: "ads-network.com",
                                         action: .deny, reason: .rule))

        let rules = [
            Rule(executablePath: apps[0].0, appName: "Music", action: .allow),
            Rule(executablePath: apps[1].0, appName: "Safari", action: .allow, host: "*.obdev.at"),
            Rule(executablePath: apps[1].0, appName: "Safari", action: .deny, host: "*.ads-network.com"),
            Rule(executablePath: apps[1].0, appName: "Safari", action: .allow, host: "*.apple.com",
                 lifetime: .untilQuit),
            Rule(executablePath: "*", appName: "", action: .allow, host: "*.icloud.com", port: 443),
            Rule(executablePath: apps[5].0, appName: "Mail", action: .allow, host: "*.mail.com"),
        ]
        let prompt = PromptRequest(pid: 402, executablePath: apps[5].0, appName: "Mail",
                                   remoteIP: "74.208.5.20", remotePort: 993, host: "imap.mail.com",
                                   deadline: nil)
        helper.loadDemo(rules: rules, prompts: [prompt])
    }

    static func snapshot(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window.title.isEmpty ? "window-\(i)" : window.title
            let url = directory.appendingPathComponent("\(i)-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
