import SoundOwlCore
import SwiftUI
import UserNotifications

struct SoundOwlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.shared

    var body: some Scene {
        // The owl in the menu bar, the player and Settings are AppKit windows (StatusItemController,
        // WindowRouter), so they open from anywhere. SwiftUI owns the menus; this empty scene only
        // carries them.
        Settings { EmptyView() }
            .commands { SoundOwlCommands(app: app) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let services = ServiceProvider()

    func applicationWillFinishLaunching(_: Notification) {
        // Finder's "Restore with SoundOwl" can be what launched us, so be ready for it first.
        NSApp.servicesProvider = services
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSUpdateDynamicServices()
        MainActor.assumeIsolated {
            let app = AppModel.shared
            _ = app.menuBar
            app.live.activate()
            #if DEBUG
                DebugSnapshots.startIfRequested()
            #endif
        }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let isPlainLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        guard !atLogin else { return }
        // Opened by hand: the owl opens its panel to say where SoundOwl lives. Started by Finder
        // or a Shortcut for a job instead: stay out of sight and leave once it's done.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            let app = AppModel.shared
            if isPlainLaunch, !app.hasReceivedWork {
                app.menuBar.show()
            } else if app.preview == nil {
                app.launchedForWork = true
                app.quitIfIdle()
            }
        }
    }

    /// Files opened with SoundOwl from Finder ("Open With", double-click, dropped on the app).
    func application(_: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppModel.shared.open(urls) }
    }

    /// Opening SoundOwl again while it runs opens the owl's panel.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.menuBar.show() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    // MARK: - Notifications

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
        }
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner]
    }
}

struct SoundOwlCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { app.showSettings(.general) }
                .keyboardShortcut(",")
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { app.updater.checkForUpdates() }
                .disabled(!app.updater.isAvailable)
        }
        CommandGroup(replacing: .newItem) {
            Button("Listen to a Recording…") { app.chooseRecordingToListen() }
                .keyboardShortcut("o")
            Button("Restore Recordings…") { app.chooseRecordingsToRestore() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button(app.preview?.savedURL == nil ? "Save Restored Copy" : "Show Restored Copy in Finder") {
                app.savePreview()
            }
            .keyboardShortcut("s")
            .disabled(app.preview?.session == nil)
        }
        CommandMenu("Playback") {
            Button(app.player.isPlaying ? "Pause" : "Play") { app.player.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(app.preview == nil)
            Button("Back 15 Seconds") { app.player.skip(by: -15) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(app.preview == nil)
            Button("Forward 15 Seconds") { app.player.skip(by: 15) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(app.preview == nil)
            Divider()
            Picker("Speed", selection: Bindable(app.player).rate) {
                ForEach(Player.rates, id: \.self) { rate in
                    Text(Player.label(for: rate)).tag(rate)
                }
            }
            Divider()
            Picker("Listen To", selection: Bindable(app.player).track) {
                Text("Original").tag(Player.Track.original)
                    .keyboardShortcut("1")
                Text("Restored").tag(Player.Track.restored)
                    .keyboardShortcut("2")
            }
            .pickerStyle(.inline)
        }
    }
}

extension Player {
    /// "1×", "1.25×"
    static func label(for rate: Float) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}
