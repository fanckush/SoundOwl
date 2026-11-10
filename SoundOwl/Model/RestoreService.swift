import AppKit
import Foundation
import SoundOwlCore
import UserNotifications

/// Restores in the background, one chunk at a time, most useful work first: the recording you're
/// listening to (just ahead of the playhead), then restores asked for from Finder, Shortcuts or
/// the window, in order. Each of those is saved next to its original.
///
/// Decoding doesn't need the model, so it runs while the model is still downloading. Restoring a
/// chunk takes a fraction of a second, so the order is re-decided after every chunk and a seek is
/// picked up almost immediately.
@MainActor @Observable
final class RestoreService {
    /// One copy to make: a file in, a restored file out.
    @MainActor @Observable
    final class Job: Identifiable {
        enum State: Equatable {
            case queued
            case reading(Double)
            case restoring(Double)
            case saving(Double)
            case done(URL)
            case failed(String)
            case cancelled
        }

        let id = UUID()
        let source: URL
        let recipe: Recipe
        let destination: RestoreDestination
        var state: State = .queued
        fileprivate var recording: Recording?
        /// Set when this job saves the recording being listened to.
        let previewID: Recording.ID?

        init(source: URL, recipe: Recipe, destination: RestoreDestination, recording: Recording? = nil) {
            self.source = source
            self.recipe = recipe
            self.destination = destination
            self.recording = recording
            previewID = recording?.id
        }

        var name: String { source.deletingPathExtension().lastPathComponent }

        var isFinished: Bool {
            switch state {
            case .done, .failed, .cancelled: true
            default: false
            }
        }
    }

    private(set) var jobs: [Job] = []
    var isBusy: Bool { jobs.contains { !$0.isFinished } }

    /// While listening, restore this far ahead of the playhead and keep this much behind it, in
    /// 30 s chunks: ten minutes and two. A ten-hour audiobook then needs minutes of scratch space.
    static let chunksAhead = 20
    static let chunksBehind = 4

    private unowned let app: AppModel
    private var worker: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var engine: EngineBox?
    private var clearTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
    }

    // MARK: - Asking for work

    /// Restores `urls` in the background, each saved to `destination`. Files already waiting
    /// with the same recipe are not added twice.
    @discardableResult
    func enqueue(_ urls: [URL], recipe: Recipe, destination: RestoreDestination = .nextToOriginal) -> [Job] {
        var added = [Job]()
        for url in urls {
            if let existing = jobs.first(where: { !$0.isFinished && $0.source == url && $0.recipe == recipe }) {
                added.append(existing)
                continue
            }
            let job = Job(source: url, recipe: recipe, destination: destination)
            jobs.append(job)
            added.append(job)
        }
        clearTask?.cancel()
        kick()
        return added
    }

    /// Restores `urls` and waits for all of them. For Shortcuts.
    func restore(_ urls: [URL], recipe: Recipe, destination: RestoreDestination = .nextToOriginal,
                 progress: (Int) -> Void = { _ in }) async -> [Job] {
        let added = enqueue(urls, recipe: recipe, destination: destination)
        while !added.allSatisfy(\.isFinished), !Task.isCancelled {
            progress(added.filter(\.isFinished).count)
            try? await Task.sleep(for: .milliseconds(200))
        }
        return added
    }

    /// Saves the recording being listened to. Reuses what's already restored.
    @discardableResult
    func save(_ recording: Recording, recipe: Recipe) -> Job {
        if let existing = jobs.first(where: { $0.previewID == recording.id && !$0.isFinished }) { return existing }
        recording.keepsEverything = true
        let job = Job(source: recording.url, recipe: recipe, destination: Self.destination(for: recording.url),
                      recording: recording)
        jobs.append(job)
        clearTask?.cancel()
        kick()
        return job
    }

    /// Next to the original, except for files inside the app (the sample), which go to Downloads.
    static func destination(for url: URL) -> RestoreDestination {
        url.path.hasPrefix(Bundle.main.bundleURL.path) ? .folder(URL.downloadsDirectory) : .nextToOriginal
    }

    func cancel(_ job: Job) {
        guard !job.isFinished else { return }
        job.state = .cancelled
        release(job)
        finishIfIdle()
    }

    func clearFinished() {
        jobs.removeAll(where: \.isFinished)
        app.quitIfIdle()
    }

    /// There may be new work: a file was added, a setting changed, the playhead moved, the model arrived.
    func kick() {
        if worker == nil {
            worker = Task { await run() }
        }
        wake?.resume()
        wake = nil
    }

    // MARK: - The loop

    private enum Step {
        case open(Job)
        case prepare(Recording, RestorationSession, Job?)
        case restore(Recording, RestorationSession, chunk: Int, Job?)
        case save(Job, PCMStore)
    }

    private func run() async {
        while !Task.isCancelled {
            guard let step = nextStep() else {
                // A loaded model holds a few hundred MB of ONNX Runtime buffers. Let it go once
                // there's been nothing to do for a while; loading it again takes well under a second.
                let release = Task {
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled, engine != nil else { return }
                    engine = nil
                    malloc_zone_pressure_relief(nil, 0)
                }
                await withCheckedContinuation { wake = $0 }
                release.cancel()
                continue
            }
            switch step {
            case .open(let job):
                await open(job)
            case .prepare(let recording, let session, let job):
                await prepare(recording, session, job: job)
            case .restore(let recording, let session, let chunk, let job):
                await restore(recording, session, chunk: chunk, job: job)
            case .save(let job, let store):
                save(job, store: store)
            }
        }
    }

    private func nextStep() -> Step? {
        // What you're listening to comes first, but only just ahead of you.
        if let preview = app.preview, let session = preview.session, !Self.isFailed(preview) {
            if !session.isPrepared { return .prepare(preview, session, nil) }
            if app.models.package != nil {
                let focus = Int(app.player.position * Double(LavaSR.inputSampleRate))
                let ahead = preview.keepsEverything ? nil : Self.chunksAhead
                if let chunk = session.nextChunk(focus: focus, ahead: ahead) {
                    return .restore(preview, session, chunk: chunk, nil)
                }
            }
        }
        // Then saved copies, oldest first. Only the first unfinished one is decoded at a time, so
        // a big batch doesn't fill the disk with scratch files.
        for job in jobs where !job.isFinished {
            if case .saving = job.state { continue }
            guard let recording = job.recording else { return .open(job) }
            guard let session = recording.session else { return nil } // still opening
            if Self.isFailed(recording) { continue }
            if !session.isPrepared { return .prepare(recording, session, job) }
            guard app.models.package != nil else { return nil }
            if let store = session.completedOutput() { return .save(job, store) }
            if let chunk = session.nextChunk() { return .restore(recording, session, chunk: chunk, job) }
            return nil
        }
        return nil
    }

    private static func isFailed(_ recording: Recording) -> Bool {
        if case .failed = recording.phase { return true }
        return false
    }

    private func open(_ job: Job) async {
        let recording = Recording(url: job.source, denoise: job.recipe.denoise)
        recording.keepsEverything = true
        job.recording = recording
        job.state = .reading(0)
        await recording.open()
        if case .failed(let message) = recording.phase { fail(job, message) }
    }

    private func prepare(_ recording: Recording, _ session: RestorationSession, job: Job?) async {
        recording.phase = .preparing(0)
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try session.prepare { fraction in
                    Task { @MainActor in
                        if case .preparing = recording.phase { recording.phase = .preparing(fraction) }
                        if let job, case .reading = job.state { job.state = .reading(fraction) }
                    }
                }
            }
        }.value
        switch result {
        case .success:
            recording.peaks = session.peaks
            recording.phase = .restoring
            if let job, !job.isFinished { job.state = .restoring(0) }
            app.player.recordingDidPrepare(recording)
        case .failure:
            let message = String(localized: "SoundOwl couldn't decode this file.")
            recording.phase = .failed(message)
            if let job { fail(job, message) }
        }
    }

    private func restore(_ recording: Recording, _ session: RestorationSession, chunk: Int, job: Job?) async {
        guard let engine = await engineForCurrentModel() else { return }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try session.restore(chunk: chunk, with: engine.model) }
        }.value
        if case .failure = result {
            let message = String(localized: "Something went wrong while restoring this file.")
            recording.phase = .failed(message)
            if let job { fail(job, message) }
            return
        }
        recording.restoredFraction = session.restoredFraction
        if session.isComplete { recording.phase = .restored }
        if let job, !job.isFinished { job.state = .restoring(session.restoredFraction) }
        // Also count the job saving the recording being listened to.
        for saving in jobs where saving.previewID == recording.id && !saving.isFinished {
            if case .saving = saving.state { continue }
            saving.state = .restoring(session.restoredFraction)
        }
        if recording === app.preview, !recording.keepsEverything {
            let current = session.plan.chunk(containing: Int(app.player.position * Double(LavaSR.inputSampleRate)))
            session.forget(chunksOutside: max(0, current - Self.chunksBehind)...(current + Self.chunksAhead))
            recording.restoredFraction = session.restoredFraction
        }
    }

    private func save(_ job: Job, store: PCMStore) {
        job.state = .saving(0)
        let source = job.source, format = job.recipe.format
        let folder = job.destination.folder(for: source)
        Task {
            do {
                let url = try await Exporter.export(store, source: source, to: folder, format: format) { fraction in
                    Task { @MainActor in
                        if case .saving = job.state { job.state = .saving(fraction) }
                    }
                }
                guard job.state != .cancelled else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                job.state = .done(url)
                if let recording = job.recording, recording.id == job.previewID { recording.savedURL = url }
            } catch {
                fail(job, Self.describe(saveError: error, folder: folder))
            }
            release(job)
            finishIfIdle()
            kick()
        }
    }

    private func fail(_ job: Job, _ message: String) {
        job.state = .failed(message)
        release(job)
        finishIfIdle()
        kick()
    }

    /// Lets go of a job's scratch files. The recording being listened to stays.
    private func release(_ job: Job) {
        if let recording = job.recording, recording.id == job.previewID {
            recording.keepsEverything = false
        }
        job.recording = nil
    }

    /// When the last restore is done: say so if nobody is looking, then tidy up after a while so
    /// the menu bar item goes away.
    private func finishIfIdle() {
        guard !isBusy, !jobs.isEmpty else { return }
        let finished = jobs.filter { $0.previewID == nil }
        // The panel shows it already; otherwise, say so where it'll be seen.
        if !finished.isEmpty, !app.menuBar.isShown { Notifications.post(for: finished) }
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, !isBusy else { return }
            clearFinished()
        }
    }

    private static func describe(saveError error: Error, folder: URL) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(nsError.code) {
            return String(localized: "SoundOwl can't write to “\(folder.lastPathComponent)”.")
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return String(localized: "There isn't enough space on the disk.")
        }
        return String(localized: "The restored copy couldn't be saved.")
    }

    // MARK: - The model

    /// The loaded model, loading it first if the installed package changed.
    private func engineForCurrentModel() async -> EngineBox? {
        guard let package = app.models.package else {
            engine = nil
            return nil
        }
        if let engine, engine.directory == package.directory { return engine }
        let loaded = await Task.detached(priority: .userInitiated) {
            try? EngineBox(model: LavaSR(package: package), directory: package.directory)
        }.value
        if loaded == nil {
            // The files are there but ONNX Runtime refused them: fetch a clean copy.
            try? app.models.remove()
            app.models.download()
        }
        engine = loaded
        return loaded
    }
}

/// LavaSR is not thread-safe. The service only ever runs one chunk at a time, so handing the same
/// instance to successive background tasks is safe.
private final class EngineBox: @unchecked Sendable {
    let model: LavaSR
    let directory: URL

    init(model: LavaSR, directory: URL) {
        self.model = model
        self.directory = directory
    }
}

/// "3 recordings restored", with a button that shows them in Finder.
enum Notifications {
    static let category = "restored"
    static let showAction = "show"

    static func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([UNNotificationCategory(
            identifier: category,
            actions: [UNNotificationAction(identifier: showAction, title: String(localized: "Show in Finder"))],
            intentIdentifiers: []
        )])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor
    static func post(for jobs: [RestoreService.Job]) {
        let saved = jobs.compactMap { job -> URL? in
            if case .done(let url) = job.state { return url }
            return nil
        }
        let failed = jobs.count - saved.count
        let content = UNMutableNotificationContent()
        if saved.count == 1, failed == 0 {
            content.title = String(localized: "“\(jobs[0].name)” is restored")
            content.body = String(localized: "Saved next to the original.")
        } else {
            content.title = String(localized: "\(saved.count) recordings restored")
            content.body = failed > 0
                ? String(localized: "\(failed) couldn't be restored.")
                : String(localized: "Saved next to the originals.")
        }
        content.categoryIdentifier = category
        content.userInfo = ["paths": saved.map(\.path)]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                                                     trigger: nil))
    }
}
