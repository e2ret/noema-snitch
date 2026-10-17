import AppKit
import ServiceManagement

/// Installs, updates and removes the root helper from inside the app (macOS asks
/// for the administrator password in its standard dialog), and manages "open at login".
@MainActor
final class HelperSetup: ObservableObject {
    static let shared = HelperSetup()

    enum State {
        case notInstalled, outdated, installed
    }

    @Published private(set) var state: State = .notInstalled
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled

    private static let installedPath = "/Library/PrivilegedHelperTools/com.noema.snitch.helper"

    private init() {
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.installedPath) else {
            state = .notInstalled
            return
        }
        if let bundled = Bundle.main.url(forResource: "NoemaHelper", withExtension: nil),
           let a = try? Data(contentsOf: bundled),
           let b = try? Data(contentsOf: URL(fileURLWithPath: Self.installedPath)),
           a != b {
            state = .outdated
        } else {
            state = .installed
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func install() {
        run(script: "install-helper.sh", prompt: String(localized: "helper.prompt.install"))
    }

    func uninstall() {
        run(script: "uninstall-helper.sh", prompt: String(localized: "helper.prompt.uninstall"))
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = error.localizedDescription
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func run(script: String, prompt: String) {
        guard !busy, let path = Bundle.main.url(forResource: script, withExtension: nil)?.path else { return }
        busy = true
        error = nil
        Task.detached {
            let result = Self.runAsAdministrator(scriptPath: path, prompt: prompt)
            await MainActor.run {
                self.busy = false
                if let result { self.error = result }
                self.refresh()
            }
        }
    }

    /// Runs the script as root via osascript; returns an error message or nil.
    /// Cancelling the password dialog is not reported as an error.
    nonisolated private static func runAsAdministrator(scriptPath: String, prompt: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "do shell script \"/bin/bash \" & quoted form of (item 1 of argv) with administrator privileges with prompt (item 2 of argv)",
            "-e", "end run",
            scriptPath, prompt,
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if message.contains("-128") { return nil }  // user cancelled
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
