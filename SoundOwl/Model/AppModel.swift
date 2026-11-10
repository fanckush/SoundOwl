import AppKit
import Network
import Observation
import ServiceManagement
import SoundOwlCore
import SoundOwlLive

/// The app's state. SoundOwl lives in the menu bar; everything here is reached from there.
///
/// Two verbs for recordings, the same everywhere:
/// - **Restore** (drop on the owl or its panel, Finder's service, Shortcuts, Terminal): a clear
///   copy next to the original.
/// - **Listen** (open a file with SoundOwl, "Listen to a Recording…", the sample): the player
///   window, restoring as it plays.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let models = ModelStore()
    let player = Player()
    let updater = Updater()
    let windows = WindowRouter()
    @ObservationIgnored private(set) lazy var service = RestoreService(app: self)
    @ObservationIgnored private(set) lazy var live = LiveController(app: self)
    @ObservationIgnored private(set) lazy var menuBar = StatusItemController(app: self)

    /// The recording in the player window.
    private(set) var preview: Recording?

    /// What "Restore" does everywhere: Finder, Shortcuts, the command line and the owl.
    var recipe: Recipe {
        didSet { RecipeStore.save(recipe) }
    }

    /// SoundOwl starts with the Mac, so Live is there for every call.
    var openAtLogin: Bool {
        didSet {
            guard openAtLogin != oldValue else { return }
            if openAtLogin {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
        }
    }

    /// Dismissed the welcome card.
    var onboarded: Bool {
        didSet { UserDefaults.standard.set(onboarded, forKey: "Onboarded") }
    }

    /// Finder or a Shortcut launched SoundOwl for a job; it leaves again once that's done, unless
    /// you start using it.
    var launchedForWork = false
    /// Some request arrived since launch (so the launch wasn't someone opening SoundOwl).
    var hasReceivedWork = false

    @ObservationIgnored private let network = NWPathMonitor()
    @ObservationIgnored private var quitCheck: Task<Void, Never>?

    init() {
        recipe = RecipeStore.load()
        openAtLogin = SMAppService.mainApp.status == .enabled
        onboarded = UserDefaults.standard.bool(forKey: "Onboarded")
        models.prepare()
        watchModel()
        watchNetwork()
    }

    // MARK: - Restoring

    /// Clear copies next to the originals, with progress in the menu bar panel.
    func restore(_ urls: [URL]) {
        hasReceivedWork = true
        let files = AudioFiles.expand(urls)
        guard !files.isEmpty else { return }
        Notifications.requestPermission()
        service.enqueue(files, recipe: recipe)
    }

    /// Restores files for Shortcuts and waits for them.
    func restore(_ urls: [URL], recipe: Recipe, destination: RestoreDestination,
                 progress: (Int) -> Void) async -> [RestoreService.Job] {
        hasReceivedWork = true
        return await service.restore(urls, recipe: recipe, destination: destination, progress: progress)
    }

    /// Files opened with SoundOwl from Finder: one recording plays, several are restored.
    func open(_ urls: [URL]) {
        hasReceivedWork = true
        let files = AudioFiles.expand(urls)
        if files.count == 1, urls.count == 1, !Self.isFolder(urls[0]) {
            listen(to: files[0])
        } else {
            restore(urls)
        }
    }

    // MARK: - Listening

    func listen(to url: URL) {
        hasReceivedWork = true
        launchedForWork = false
        if preview?.url != url {
            let recording = Recording(url: url, denoise: recipe.denoise)
            recording.onChange = { [weak self] in self?.service.kick() }
            preview = recording
            player.load(recording)
            Task { await recording.open() }
            service.kick()
        }
        windows.showPlayer()
    }

    /// The player window closed: listening is over. The place is remembered, and a copy being
    /// saved finishes regardless.
    func closePreview() {
        player.load(nil)
        preview = nil
        quitIfIdle()
    }

    func trySample() {
        guard let url = Bundle.main.url(forResource: "Sample Recording", withExtension: "m4a") else { return }
        listen(to: url)
    }

    /// "Listen to a Recording…": one file, into the player.
    func chooseRecordingToListen() {
        menuBar.close()
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.message = String(localized: "Choose a recording to listen to. SoundOwl restores it as it plays.")
        if panel.runModal() == .OK, let url = panel.url { listen(to: url) }
    }

    /// "Choose Recordings…" in the panel: copies, like a drop.
    func chooseRecordingsToRestore() {
        menuBar.close()
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.prompt = String(localized: "Restore")
        panel.message = String(localized: "Choose recordings or folders. Clear copies are saved next to the originals.")
        if panel.runModal() == .OK { restore(panel.urls) }
    }

    func savePreview() {
        guard let preview, preview.session != nil else { return }
        if let saved = preview.savedURL {
            NSWorkspace.shared.activateFileViewerSelecting([saved])
            return
        }
        service.save(preview, recipe: recipe.overriding(denoise: preview.denoise))
    }

    /// The job saving the recording being listened to, while it runs.
    var previewSave: RestoreService.Job? {
        guard let preview else { return nil }
        return service.jobs.last { $0.previewID == preview.id && !$0.isFinished }
    }

    func showSettings(_ tab: SettingsTab) {
        menuBar.close()
        windows.showSettings(tab)
    }

    // MARK: - Leaving

    /// After a launch just for work (Finder, a Shortcut): quits once that work is done and
    /// nothing else needs SoundOwl. Started by you, SoundOwl stays until you quit it.
    func quitIfIdle() {
        guard launchedForWork, quitCheck == nil else { return }
        quitCheck = Task {
            // Let a window that is opening, or a request that is arriving, show up first.
            try? await Task.sleep(for: .seconds(1))
            quitCheck = nil
            guard launchedForWork, service.jobs.allSatisfy(\.isFinished), !live.isActive,
                  !windows.hasVisibleWindows, !menuBar.isShown else { return }
            NSApp.terminate(nil)
        }
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    // MARK: - Watching the model and the network

    private func watchModel() {
        withObservationTracking {
            _ = models.phase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.service.kick()
                self?.live.modelChanged()
                self?.watchModel()
            }
        }
    }

    private func watchNetwork() {
        network.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                let models = AppModel.shared.models
                if models.failedOffline, case .failed = models.phase { models.download() }
            }
        }
        network.start(queue: .main)
    }
}

enum SettingsTab: Hashable {
    case general
    case live
    case recordings
    case integrations
    case model
}
