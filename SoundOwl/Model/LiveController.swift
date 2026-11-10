import AppKit
import Observation
import SoundOwlCore
import SoundOwlLive

/// Live, per app: the apps you switch on have their voices restored as you hear them, whenever
/// they play and SoundOwl is running. The switches are remembered.
@MainActor @Observable
final class LiveController {
    /// One line in the panel: an app that is playing sound, or one you've switched on.
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let isOn: Bool
        let isRunning: Bool
        let status: Status
    }

    /// How Live treats one app's sound. Remembered per app.
    struct Options: Codable, Equatable {
        var balance: LiveSettings.Balance = .balanced
        var choices = LiveChoices()
    }

    enum Status: Equatable {
        /// Off and silent.
        case idle
        /// Off, playing sound.
        case playing
        /// On, but the app isn't open.
        case notOpen
        /// On, open, not playing yet.
        case waiting
        case starting
        case waitingForModel
        /// Measuring the bandwidth, the first seconds of sound.
        case listening
        case restoring
        /// Already full quality: plays untouched.
        case alreadyClear
        /// Music: plays untouched (the model is made for voices).
        case music
        /// On, but held back by a notice (speakers, permission, a headset in call mode).
        case paused
        case failed
    }

    /// Something that holds every app back, said once under the list.
    enum Notice: Equatable {
        case speakers
        case permission
        case narrowOutput
        case failed(app: String, message: String)
    }

    private(set) var rows: [Row] = []
    private(set) var notice: Notice?
    /// Seconds from an app playing a sound to you hearing it, while something is restored.
    private(set) var latency: Double?

    /// Apps switched on, with their names for when they aren't running. Remembered.
    private(set) var enabled: [String: String] {
        didSet { UserDefaults.standard.set(enabled, forKey: "Live.Apps") }
    }

    /// Each app's options; apps not in here use the defaults.
    private(set) var options: [String: Options] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(options), forKey: "Live.Options") }
    }

    var onlyWithHeadphones: Bool {
        didSet {
            UserDefaults.standard.set(onlyWithHeadphones, forKey: "Live.OnlyWithHeadphones")
            refresh()
        }
    }

    /// Some app's voices are being restored right now.
    var isRestoring: Bool { rows.contains { $0.status == .restoring || $0.status == .listening } }
    /// Some session is running (and so must outlive a background launch).
    var isActive: Bool { !sessions.isEmpty }

    /// The app whose options are open in the panel, like a Control Center module: one at a time.
    var expanded: String?

    /// The panel is open: keep the list fresh even when nothing is switched on.
    var isWatched = false {
        didSet { updatePolling() }
    }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var sessions: [String: Entry] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var blocked: Set<String> = []
    @ObservationIgnored private var permissionMissing = false
    @ObservationIgnored private var watches: [AnyObject] = []
    @ObservationIgnored private var poll: Timer?

    private struct Entry {
        let session: LiveSession
        var state: LiveSession.State = .starting
    }

    init(app: AppModel) {
        self.app = app
        enabled = UserDefaults.standard.dictionary(forKey: "Live.Apps") as? [String: String] ?? [:]
        onlyWithHeadphones = UserDefaults.standard.object(forKey: "Live.OnlyWithHeadphones") as? Bool ?? true
        options = UserDefaults.standard.data(forKey: "Live.Options")
            .flatMap { try? JSONDecoder().decode([String: Options].self, from: $0) } ?? [:]
    }

    /// Starts watching apps and devices. Separate from init so `AppModel.shared` exists first.
    func activate() {
        guard watches.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.live.refresh() }
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.live.rebuildAll() }
        }
        let onChange: @Sendable () -> Void = {
            Task { @MainActor in AppModel.shared.live.refresh() }
        }
        watches = [AudioProcesses.watch(onChange: onChange), AudioProcesses.watchOutput(onChange: onChange)]
        updatePolling()
        refresh()
    }

    // MARK: - Switches

    func setOn(_ on: Bool, for row: Row) {
        if on {
            enabled[row.id] = row.name
            blocked.remove(row.id)
        } else {
            enabled[row.id] = nil
            stop(row.id)
        }
        updatePolling()
        refresh()
    }

    /// Switches every app off (the Shortcut with no app).
    func turnAllOff() {
        for id in enabled.keys { stop(id) }
        enabled = [:]
        updatePolling()
        refresh()
    }

    /// Switches one app on or off by name, for Shortcuts. Returns false when no such app is known.
    func set(_ on: Bool, appNamed name: String) -> Bool {
        let known = rows.map { ($0.id, $0.name) }
            + Self.runningApps().map { ($0.bundleIdentifier!, Self.name(of: $0)) }
            + enabled.map { ($0.key, $0.value) }
        guard let match = known.first(where: { $0.1.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }
        setOn(on, for: Row(id: match.0, name: match.1, isOn: !on, isRunning: true, status: .idle))
        return true
    }

    func options(for id: String) -> Options { options[id] ?? Options() }

    /// Changes an app's options; a running session follows at once (the delay after a moment's
    /// untouched sound, while it starts over).
    func set(_ new: Options, for id: String) {
        options[id] = new == Options() ? nil : new
        guard let session = sessions[id]?.session else { return }
        session.update(choices: new.choices)
        session.update(settings: new.balance.settings)
    }

    /// After granting permission, or after a failure.
    func retry() {
        permissionMissing = false
        blocked = []
        for id in Array(sessions.keys) { stop(id) }
        refresh()
    }

    func useSpeakersAnyway() {
        onlyWithHeadphones = false
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func modelChanged() { refresh() }

    // MARK: - Keeping up

    /// Starts and stops sessions to match the switches and the world, then rebuilds the rows.
    func refresh() {
        guard let app else { return }
        let running = Dictionary(Self.runningApps().map { ($0.bundleIdentifier!, $0) }, uniquingKeysWith: { a, _ in a })
        let audio = AudioProcesses.all()
        let output = try? OutputDevice.current()
        let onSpeakers = onlyWithHeadphones && output?.isHeadphones == false
        let modelReady = app.models.phase == .ready && app.models.package != nil

        // Sessions for apps that were switched off or quit, or that a notice holds back.
        for id in Array(sessions.keys) where enabled[id] == nil || running[id] == nil || onSpeakers || permissionMissing {
            stop(id)
        }

        // Sessions for apps switched on and running.
        if !onSpeakers, !permissionMissing, modelReady, let package = app.models.package {
            for (id, runningApp) in running where enabled[id] != nil && sessions[id] == nil && !blocked.contains(id) {
                start(id, pid: runningApp.processIdentifier, package: package)
            }
        } else if !modelReady, !enabled.isEmpty, case .missing = app.models.phase {
            app.models.download()
        }

        let notice = notice(running: running, onSpeakers: onSpeakers)
        if self.notice != notice { self.notice = notice }

        var latency: Double?
        let context = RowContext(running: running, audio: audio, onSpeakers: onSpeakers, modelReady: modelReady)
        let playing = running.keys.filter { context.isPlaying($0) }
        let rows = Set(enabled.keys).union(playing)
            .map { row(for: $0, context, latency: &latency) }
            .sorted { (Self.rank($0), $0.name.localizedLowercase) < (Self.rank($1), $1.name.localizedLowercase) }
        if self.rows != rows { self.rows = rows }
        if self.latency != latency { self.latency = latency }
        app.quitIfIdle()
    }

    private struct RowContext {
        let running: [String: NSRunningApplication]
        let audio: [AudioProcess]
        let onSpeakers: Bool
        let modelReady: Bool

        func isPlaying(_ id: String) -> Bool {
            guard let app = running[id] else { return false }
            return AudioProcesses.processes(of: id, pid: app.processIdentifier, in: audio).contains(where: \.isPlaying)
        }
    }

    private func row(for id: String, _ context: RowContext, latency: inout Double?) -> Row {
        let runningApp = context.running[id]
        let isOn = enabled[id] != nil
        let status: Status = if !isOn {
            context.isPlaying(id) ? .playing : .idle
        } else if runningApp == nil {
            .notOpen
        } else if context.onSpeakers || permissionMissing {
            .paused
        } else if !context.modelReady {
            .waitingForModel
        } else if blocked.contains(id) {
            .failed
        } else if let entry = sessions[id] {
            Self.status(of: entry, latency: &latency)
        } else {
            .starting
        }
        return Row(id: id, name: runningApp.map(Self.name(of:)) ?? enabled[id] ?? id, isOn: isOn,
                   isRunning: runningApp != nil, status: status)
    }

    private func notice(running: [String: NSRunningApplication], onSpeakers: Bool) -> Notice? {
        if permissionMissing { return .permission }
        if onSpeakers, enabled.keys.contains(where: { running[$0] != nil }) { return .speakers }
        for entry in sessions.values {
            if case .outputTooNarrow = entry.state { return .narrowOutput }
        }
        for (id, entry) in sessions {
            if case .failed(let message) = entry.state { return .failed(app: enabled[id] ?? id, message: message) }
        }
        return nil
    }

    private static func status(of entry: Entry, latency: inout Double?) -> Status {
        switch entry.state {
        case .stopped, .starting: return .starting
        case .waitingForApp: return .waiting
        case .needsPermission, .outputTooNarrow: return .paused
        case .failed: return .failed
        case .running:
            guard let stats = entry.session.stats() else { return .starting }
            if stats.isMusic { return .music }
            if stats.isAlreadyClear { return .alreadyClear }
            if stats.isListening { return .listening }
            latency = max(latency ?? 0, stats.latency)
            return .restoring
        }
    }

    private static func rank(_ row: Row) -> Int {
        switch row.status {
        case .restoring, .listening, .alreadyClear, .music: 0
        case .starting, .waitingForModel, .paused, .failed: 1
        case .playing: 2
        case .waiting: 3
        case .notOpen: 4
        case .idle: 5
        }
    }

    private func start(_ id: String, pid: pid_t, package: ModelPackage) {
        guard !loading.contains(id) else { return }
        loading.insert(id)
        let threads = LiveSettings.standard.threads
        Task {
            // Each session gets its own model: a model runs on one thread at a time.
            let loaded = try? await Task.detached { try LoadedModel(LavaSR(package: package, intraOpThreads: threads)) }.value
            loading.remove(id)
            guard let loaded else {
                blocked.insert(id)
                refresh()
                return
            }
            guard enabled[id] != nil, sessions[id] == nil else { return }
            let options = options(for: id)
            let session = LiveSession(model: loaded.model, target: .init(bundleID: id, pid: pid),
                                      settings: options.balance.settings) { state in
                Task { @MainActor in AppModel.shared.live.sessionChanged(id, state) }
            }
            session.update(choices: options.choices)
            sessions[id] = Entry(session: session)
            session.start()
            refresh()
        }
    }

    private func sessionChanged(_ id: String, _ state: LiveSession.State) {
        guard sessions[id] != nil else { return }
        sessions[id]?.state = state
        switch state {
        case .needsPermission:
            permissionMissing = true
        case .failed:
            blocked.insert(id)
        default:
            break
        }
        refresh()
    }

    private func stop(_ id: String) {
        sessions.removeValue(forKey: id)?.session.stop()
    }

    private func rebuildAll() {
        for entry in sessions.values { entry.session.rebuild() }
    }

    /// Once a second while something is on or the panel is open: status words, headphones, and
    /// apps that start or stop playing (which changes no process list).
    private func updatePolling() {
        let needed = isWatched || !enabled.isEmpty
        if needed, poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { AppModel.shared.live.refresh() }
            }
        } else if !needed {
            poll?.invalidate()
            poll = nil
        }
    }

    // MARK: - Apps

    private static func runningApps() -> [NSRunningApplication] {
        let me = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != me
        }
    }

    private static func name(of app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleIdentifier ?? "?"
    }
}

/// Carries a freshly loaded model out of the task that loaded it. Only one session uses it after.
private final class LoadedModel: @unchecked Sendable {
    let model: LavaSR
    init(_ model: LavaSR) { self.model = model }
}
