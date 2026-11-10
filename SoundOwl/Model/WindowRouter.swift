import AppKit
import SwiftUI

/// Owns the player window and decides when SoundOwl is in the Dock.
///
/// SoundOwl lives in the menu bar (LSUIElement). The Dock icon and the menus appear only while
/// the player or Settings is open. The player exists only with a recording in it: closing it is
/// the end of listening.
@MainActor
final class WindowRouter: NSObject, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private let settings = SettingsWindow()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                self?.windowsDidChange()
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                // Settings opened from the menu bar item: give it a Dock icon and menus like any window.
                if let window, Self.isDocumentLike(window) { Self.becomeRegular() }
            }
        }
    }

    func showPlayer() {
        let window = mainWindow ?? makeMainWindow()
        Self.becomeRegular()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func showSettings(_ tab: SettingsTab) {
        Self.becomeRegular()
        NSApp.activate()
        settings.show(tab)
    }

    /// The main window's title and proxy icon follow the recording in it.
    func show(recording url: URL?) {
        mainWindow?.title = url?.deletingPathExtension().lastPathComponent ?? "SoundOwl"
        mainWindow?.representedURL = url
        if url == nil { mainWindow?.subtitle = "" }
    }

    /// Under the recording's name: how long it is and what kind.
    func show(subtitle: String) {
        mainWindow?.subtitle = subtitle
    }

    var hasVisibleWindows: Bool {
        NSApp.windows.contains { $0.isVisible && Self.isDocumentLike($0) }
    }

    private func makeMainWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        // Known before the content loads: the content sets the title from the recording.
        mainWindow = window
        // The Space key monitor and DebugSnapshots look for this name.
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.title = "SoundOwl"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 600, height: 380)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: ContentView().environment(AppModel.shared))
        window.center()
        window.setFrameAutosaveName("Player")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow else { return }
        // Closing the player means you're done listening. The place you stopped is remembered,
        // and a restored copy being saved finishes regardless.
        AppModel.shared.closePreview()
    }

    private func windowsDidChange() {
        guard !hasVisibleWindows else { return }
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.quitIfIdle()
    }

    private static func becomeRegular() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// The main window and Settings; not the menu bar item's panel.
    private static func isDocumentLike(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel)
    }
}
