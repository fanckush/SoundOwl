import AppKit
import SwiftUI

/// Settings in an AppKit window with toolbar tabs. SwiftUI's Settings scene can only be opened
/// from inside a SwiftUI scene, and SoundOwl's front door (the menu bar panel) isn't one.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var tabs: NSTabViewController?

    func show(_ tab: SettingsTab) {
        let window = window ?? make()
        if let index = SettingsTab.allCases.firstIndex(of: tab) {
            tabs?.selectedTabViewItemIndex = index
        }
        window.makeKeyAndOrderFront(nil)
        // Nothing focused until the keyboard is used: a ring on the first switch reads as "press me".
        window.makeFirstResponder(nil)
    }

    private func make() -> NSWindow {
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for tab in SettingsTab.allCases {
            let title = tab.title, symbol = tab.symbol
            let hosting = NSHostingController(rootView: Self.view(for: tab).environment(AppModel.shared).frame(width: 540))
            hosting.sizingOptions = [.preferredContentSize]
            hosting.title = title
            let item = NSTabViewItem(viewController: hosting)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.center()
        self.window = window
        self.tabs = tabs
        return window
    }

    @ViewBuilder
    private static func view(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView()
        case .live: LiveSettingsView()
        case .recordings: RestoringSettingsView()
        case .integrations: IntegrationsView()
        case .model: ModelSettingsView()
        }
    }
}

/// Switching tabs focuses nothing, as opening the window doesn't.
private final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        view.window?.makeFirstResponder(nil)
    }
}

extension SettingsTab: CaseIterable {
    static let allCases: [SettingsTab] = [.general, .live, .recordings, .integrations, .model]

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .live: String(localized: "Live")
        case .recordings: String(localized: "Recordings")
        case .integrations: String(localized: "Integrations")
        case .model: String(localized: "Model")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .live: "phone.bubble"
        case .recordings: "waveform"
        case .integrations: "puzzlepiece.extension"
        case .model: "cpu"
        }
    }
}
