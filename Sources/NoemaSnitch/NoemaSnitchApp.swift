import Combine
import NoemaShared
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = ConnectionMonitor()
    let helper = HelperClient()
    let model = NetworkModel()
    let deviceProxy = DeviceProxyModel()
    private var presenter: PromptPresenter?
    private var subscriptions = Set<AnyCancellable>()
    private var ticker: Timer?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { WindowOpener.open("main") }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        presenter = PromptPresenter(helper: helper)
        helper.onTraffic = { [model] date, entries in model.ingest(date: date, entries: entries) }
        helper.onEvent = { [model] event in model.ingest(event: event) }
        // The device proxy connects out on the phone's behalf: allow that without prompts.
        deviceProxy.onStart = { [helper] in
            guard let path = Bundle.main.executablePath,
                  !helper.rules(forApp: path).contains(where: { $0.host == nil && $0.action == .allow }) else { return }
            helper.setRule(.allow, executablePath: path, appName: "Noema Snitch", hostPattern: nil)
        }
        // Without the helper, fall back to what libproc shows for the current user.
        monitor.$connections
            .sink { [weak self] connections in
                guard let self, !self.helper.isConnected, !Demo.isEnabled else { return }
                self.model.ingest(connections: connections, hostnames: self.monitor.hostnames)
            }
            .store(in: &subscriptions)
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.tick() }
        }
        if Demo.isEnabled {
            Demo.load(model: model, helper: helper)
            deviceProxy.loadDemo()
        }
        // SwiftUI may skip opening the main window when a menu bar extra exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
            if !hasWindow { WindowOpener.open("main") }
        }
        if let directory = Demo.snapshotDirectory {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                Demo.snapshot(to: directory)
                guard CommandLine.arguments.contains("--cycle-sections") else { return NSApp.terminate(nil) }
                // Switch sections inside one session to check the window keeps its size.
                for (i, section) in MainSection.allCases.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i + 1)) {
                        UserDefaults.standard.set(section.rawValue, forKey: MainSection.storageKey)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            Demo.snapshot(to: directory.appendingPathComponent(section.rawValue))
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { NSApp.terminate(nil) }
            }
        }
    }
}

@main
struct NoemaSnitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("app.name", id: "main") {
            MainView()
                .environmentObject(delegate.model)
                .environmentObject(delegate.helper)
                .environmentObject(delegate.monitor)
                .environmentObject(delegate.deviceProxy)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 720)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            StatusMenuView()
                .environmentObject(delegate.model)
                .environmentObject(delegate.helper)
        } label: {
            MenuBarIcon()
                .environmentObject(delegate.helper)
        }
        .menuBarExtraStyle(.window)
    }
}
