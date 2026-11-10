import AppKit
import Sparkle

/// Checks the release feed and installs updates through Sparkle's own windows.
@MainActor @Observable
final class Updater {
    private let controller: SPUStandardUpdaterController

    /// Updates need the public key in Info.plist. A fork that removes it (or the placeholder) gets
    /// no updater, because an updater that can't verify anything would only show errors.
    let isAvailable: Bool

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        // A local build is always version 0.1.0 (1), so every published release would look newer.
        #if DEBUG
            isAvailable = false
        #else
            isAvailable = !key.isEmpty && key != "SPARKLE_PUBLIC_KEY_NOT_SET"
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: isAvailable, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
    }

    /// Mirrors Sparkle's setting so SwiftUI can bind to it.
    var automaticallyChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    func checkForUpdates() {
        guard isAvailable else { return }
        controller.checkForUpdates(nil)
    }
}
