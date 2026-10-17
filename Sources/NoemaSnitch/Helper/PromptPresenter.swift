import AppKit
import Combine
import NoemaShared
import SwiftUI

/// Shows the connection alert while the helper has unanswered prompts.
@MainActor
final class PromptPresenter {
    private let helper: HelperClient
    private var panel: NSPanel?
    private var subscription: AnyCancellable?

    init(helper: HelperClient) {
        self.helper = helper
        subscription = helper.$prompts
            .receive(on: RunLoop.main)
            .sink { [weak self] prompts in self?.update(hasPrompts: !prompts.isEmpty) }
    }

    private func update(hasPrompts: Bool) {
        guard hasPrompts else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            panel.center()
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
                            styleMask: [.titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        let host = NSHostingController(rootView: ConnectionAlertView().environmentObject(helper))
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        return panel
    }
}
