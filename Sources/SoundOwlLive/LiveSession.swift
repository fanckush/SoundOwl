import CoreAudio
import Foundation
import SoundOwlCore
import Synchronization

/// Live restoring of one app's sound, kept going while devices and processes come and go.
///
/// Setup and teardown happen on the session's own queue, and `onChange` reports state changes
/// there. `start`, `stop` and `stats` never wait for it: the first start can sit in
/// `AudioDeviceStart` for as long as macOS's permission prompt is up.
public final class LiveSession: @unchecked Sendable {
    public struct Target: Sendable, Equatable {
        public let bundleID: String
        public let pid: pid_t?
        public init(bundleID: String, pid: pid_t? = nil) {
            self.bundleID = bundleID
            self.pid = pid
        }
    }

    public enum State: Sendable, Equatable {
        case starting
        /// The app isn't making any sound yet (or isn't running). Live starts when it does.
        case waitingForApp
        case running
        /// Taps deliver silence without the Screen & System Audio Recording permission.
        case needsPermission
        /// The output can't carry the restored highs: a headset in call mode plays at 16 kHz.
        case outputTooNarrow(sampleRate: Double)
        case failed(String)
        case stopped
    }

    public struct Stats: Sendable {
        public var latency: Double
        public var output: String
        public var sampleRate: Double
        /// Waiting for enough of the call to measure its bandwidth.
        public var isListening: Bool
        /// Already full-band: played untouched.
        public var isAlreadyClear: Bool
        /// Music: played untouched.
        public var isMusic: Bool
        public var cutoff: Int
        public var fallbackFraction: Double
        public var restarts: Int
        public var lastHopMs: Double
        public var worstHopMs: Double
    }

    public let target: Target
    /// The sizes it restores with; changing them starts the pipeline over.
    public var settings: LiveSettings { published.withLock { $0.settings } }
    public var state: State { published.withLock { $0.state } }

    /// What other threads may read without waiting for the queue.
    private struct Published {
        var state: State = .stopped
        var pipeline: LivePipeline?
        var output = ""
        var sampleRate = 0.0
        var bufferFrames = 0
        var settings = LiveSettings.standard
        var choices = LiveChoices()
    }
    private let published = Mutex(Published())

    private let model: LavaSR
    private let queue = DispatchQueue(label: "app.soundowl.live", qos: .userInitiated)
    private let onChange: @Sendable (State) -> Void
    private var tap: ProcessTap?
    private var pipeline: LivePipeline?
    private var tapped: Set<AudioObjectID> = []
    private var watches: [PropertyWatch] = []
    private var timer: DispatchSourceTimer?
    private var startedAt = DispatchTime.now()
    /// Frames played and fallen back, sampled every half second, for the last five seconds.
    private var recent: [(played: Int, fellBack: Int)] = []

    public init(model: LavaSR, target: Target, settings: LiveSettings = .standard,
                onChange: @escaping @Sendable (State) -> Void) {
        self.model = model
        self.target = target
        published.withLock { $0.settings = settings }
        self.onChange = onChange
    }

    public func start() {
        queue.async { [self] in
            guard state == .stopped || isRetryable else { return }
            // A retry after a failure: forget the old watchers first.
            timer?.cancel()
            set(.starting)
            watches = [
                PropertyWatch(kAudioHardwarePropertyDefaultOutputDevice, queue: queue) { [weak self] in self?.rebuild() },
                PropertyWatch(kAudioHardwarePropertyProcessObjectList, queue: queue) { [weak self] in self?.processesChanged() }
            ]
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
            build()
        }
    }

    /// Stops as soon as the queue is free. `completion` runs once the app is heard directly again.
    public func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            watches = []
            tearDown()
            set(.stopped)
            completion?()
        }
    }

    /// Stops and waits for it. For command-line use; never on a main thread.
    public func stopAndWait() {
        let done = DispatchSemaphore(value: 0)
        stop { done.signal() }
        done.wait()
    }

    /// Changes the delay against clarity: the pipeline starts over (a short gap of untouched sound).
    public func update(settings: LiveSettings) {
        let changed = published.withLock { p in
            defer { p.settings = settings }
            return p.settings != settings
        }
        if changed { rebuild() }
    }

    /// Changes take effect at once.
    public func update(choices: LiveChoices) {
        published.withLock { p in
            p.choices = choices
            if let pipeline = p.pipeline { choices.apply(to: pipeline) }
        }
    }

    /// Starts over with the current devices and processes, after sleep for example.
    public func rebuild() {
        queue.async { [self] in
            guard timer != nil else { return }
            tearDown()
            build()
        }
    }

    public func stats() -> Stats? {
        published.withLock { p in
            guard let pipeline = p.pipeline else { return nil }
            let played = max(1, pipeline.framesPlayed.load(ordering: .relaxed))
            return Stats(latency: pipeline.latencySeconds + Double(p.bufferFrames) / p.sampleRate,
                         output: p.output, sampleRate: p.sampleRate,
                         isListening: !pipeline.isReady, isAlreadyClear: pipeline.isAlreadyClear,
                         isMusic: pipeline.isReady && pipeline.kind == .music,
                         cutoff: pipeline.cutoffHz.load(ordering: .relaxed),
                         fallbackFraction: Double(pipeline.framesFallenBack.load(ordering: .relaxed)) / Double(played),
                         restarts: pipeline.restarts.load(ordering: .relaxed),
                         lastHopMs: Double(pipeline.lastHopMicros.load(ordering: .relaxed)) / 1000,
                         worstHopMs: Double(pipeline.worstHopMicros.load(ordering: .relaxed)) / 1000)
        }
    }

    // MARK: - On the queue

    private var isRetryable: Bool {
        switch state {
        case .needsPermission, .failed, .outputTooNarrow: true
        default: false
        }
    }

    private func set(_ new: State) {
        let changed = published.withLock { p in
            guard p.state != new else { return false }
            p.state = new
            return true
        }
        if changed { onChange(new) }
    }

    private func matchingProcesses() -> [AudioProcess] {
        AudioProcesses.processes(of: target.bundleID, pid: target.pid)
    }

    private func build() {
        let processes = matchingProcesses()
        tapped = Set(processes.map(\.object))
        guard !processes.isEmpty else {
            set(.waitingForApp)
            return
        }
        do {
            let output = try OutputDevice.current()
            guard output.sampleRate >= 24_000 else {
                set(.outputTooNarrow(sampleRate: output.sampleRate))
                return
            }
            let tap = try ProcessTap(processes: processes.map(\.object), output: output)
            let pipeline = try LivePipeline(model: model, sampleRate: tap.sampleRate,
                                            bufferFrames: tap.bufferFrames, settings: settings)
            published.withLock { $0.choices.apply(to: pipeline) }
            pipeline.start()
            self.tap = tap
            self.pipeline = pipeline
            // The first time, this waits for the user to answer macOS's permission prompt.
            try tap.start { input, output, frames in pipeline.render(input: input, output: output, frames: frames) }
            published.withLock {
                $0.pipeline = pipeline
                $0.output = tap.output.name
                $0.sampleRate = tap.sampleRate
                $0.bufferFrames = tap.bufferFrames
            }
            startedAt = .now()
            recent = []
            set(.running)
        } catch {
            tearDown()
            set(.failed(String(describing: error)))
        }
    }

    private func tearDown() {
        published.withLock { $0.pipeline = nil }
        tap?.stop()
        tap = nil
        pipeline?.stop()
        pipeline = nil
    }

    private func processesChanged() {
        guard timer != nil else { return }
        let now = Set(matchingProcesses().map(\.object))
        guard now != tapped else { return }
        tearDown()
        build()
    }

    /// The watchdog and the permission check, twice a second.
    private func check() {
        if case .outputTooNarrow = state {
            // The headset may have left call mode.
            if let output = try? OutputDevice.current(), output.sampleRate >= 24_000 { build() }
            return
        }
        guard state == .running, let pipeline, let tap else { return }
        let rate = tap.sampleRate

        // A headset switching into or out of call mode changes rate without changing device.
        if let output = try? OutputDevice.current(), output.uid == tap.output.uid, output.sampleRate != rate {
            tearDown()
            build()
            return
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1e9

        // Can't keep up: three seconds in a row of the original, or a quarter of the last five
        // seconds (restarting over and over sounds worse than not restoring). Turn off rather than
        // stutter.
        let played = pipeline.framesPlayed.load(ordering: .relaxed)
        let fellBack = pipeline.framesFallenBack.load(ordering: .relaxed)
        recent.append((played, fellBack))
        if recent.count > 10 { recent.removeFirst() }
        let windowPlayed = played - recent[0].played, windowFellBack = fellBack - recent[0].fellBack
        let struggling = recent.count == 10 && windowPlayed > 0 && Double(windowFellBack) > 0.25 * Double(windowPlayed)
        if pipeline.isReady, Double(pipeline.fallbackRun.load(ordering: .relaxed)) > 3 * rate || struggling {
            tearDown()
            set(
                .failed(
                    String(
                        localized: "This Mac couldn't restore the sound fast enough, so Live stopped. Close some apps and try again."
                    )
                )
            )
            return
        }

        // Nothing but digital silence for 8 s while the app is playing: the tap has no permission.
        if elapsed > 8, pipeline.lastSoundFrame.load(ordering: .relaxed) < 0,
           matchingProcesses().contains(where: \.isPlaying) {
            tearDown()
            set(.needsPermission)
        }
    }
}

/// What Live does with an app's sound, changeable while it plays.
public struct LiveChoices: Sendable, Equatable, Codable {
    /// Sound that is already full-band plays untouched.
    public var leaveClearSoundAlone = true
    /// Background noise is reduced as well.
    public var reduceNoise = false

    public init(leaveClearSoundAlone: Bool = true, reduceNoise: Bool = false) {
        self.leaveClearSoundAlone = leaveClearSoundAlone
        self.reduceNoise = reduceNoise
    }

    func apply(to pipeline: LivePipeline) {
        pipeline.leavesClearSoundAlone.store(leaveClearSoundAlone, ordering: .relaxed)
        pipeline.reducesNoise.store(reduceNoise, ordering: .relaxed)
    }
}
