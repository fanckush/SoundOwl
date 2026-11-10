import AVFoundation
import MediaPlayer
import Observation
import SoundOwlCore

/// Plays a recording with instant switching between the original and the restored version.
///
/// Both versions play all the time, started on the same host time, and switching only changes
/// which one is audible. That keeps them in lockstep, so flipping back and forth compares the
/// same words. The original plays from the file itself (not the 16 kHz copy the model gets), at a
/// gain that matches the restored loudness.
///
/// It is also a player for spoken word: speed, skipping, media keys and Now Playing, and it
/// remembers where you stopped in long recordings.
@MainActor @Observable
final class Player {
    enum Track: Hashable {
        case original
        case restored
    }

    var track: Track = .restored {
        didSet { if track != oldValue { applyVolumes(ramp: true) } }
    }

    private(set) var isPlaying = false
    /// Waiting for the chunk under the playhead to be restored before starting.
    private(set) var isWaiting = false
    private(set) var position: Double = 0
    /// Holding Space plays the original until the key comes back up.
    private(set) var isPeeking = false

    /// Playback speed, pitch kept. Speech stays clear up to about 2×.
    var rate: Float = 1 {
        didSet {
            timePitch.rate = rate
            updateNowPlaying()
        }
    }

    static let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    private(set) weak var recording: Recording?
    private let engine = AVAudioEngine()
    private let originalNode = AVAudioPlayerNode()
    private let restoredNode = AVAudioPlayerNode()
    private let mix = AVAudioMixerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var originalFile: AVAudioFile?
    private var restoredFormat: AVAudioFormat?

    /// Bumped on every stop and seek, so callbacks from an earlier schedule do nothing.
    private var generation = 0
    private var startPosition: Double = 0
    private var nextRestoredFrame = 0
    private var queuedBuffers = 0
    private var ticker: Task<Void, Never>?
    private var spaceDown: Date?
    private var peekTask: Task<Void, Never>?

    private static let bufferFrames = 24_000 // 0.5 s at 48 kHz
    private static let buffersAhead = 4

    init() {
        engine.attach(originalNode)
        engine.attach(restoredNode)
        engine.attach(mix)
        engine.attach(timePitch)
        setUpRemoteCommands()
    }

    var duration: Double { recording?.duration ?? 0 }

    func load(_ recording: Recording?) {
        guard recording !== self.recording else { return }
        rememberPosition()
        stop()
        self.recording = recording
        position = 0
        originalFile = nil
        updateNowPlaying()
    }

    /// Picks up where you stopped last time, once the file is read.
    func recordingDidPrepare(_ recording: Recording) {
        guard recording === self.recording, !isPlaying, !isWaiting, position == 0,
              let saved = ListeningPositions.position(for: recording.url, duration: recording.duration) else { return }
        position = saved
        updateNowPlaying()
    }

    func skip(by seconds: Double) {
        seek(to: (isPlaying ? currentPosition() : position) + seconds)
    }

    func togglePlay() {
        if isPlaying || isWaiting { pause() } else { play() }
    }

    func play() {
        guard recording?.session?.isPrepared == true else { return }
        if position >= duration - 0.05 { position = 0 }
        start(from: position)
    }

    func pause() {
        position = currentPosition()
        stop()
        rememberPosition()
        updateNowPlaying()
    }

    func seek(to seconds: Double) {
        let target = min(max(0, seconds), duration)
        let wasPlaying = isPlaying || isWaiting
        stop()
        position = target
        if wasPlaying { start(from: target) }
        recording?.onChange?()
        rememberPosition()
        updateNowPlaying()
    }

    // MARK: - Hold Space for the original

    /// Space down: a tap toggles playback, holding it plays the original until release.
    func spacePressed() {
        guard spaceDown == nil else { return }
        spaceDown = .now
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, spaceDown != nil else { return }
            isPeeking = true
            applyVolumes(ramp: true)
            if !isPlaying, !isWaiting { play() }
        }
    }

    func spaceReleased() {
        peekTask?.cancel()
        defer { spaceDown = nil }
        if isPeeking {
            isPeeking = false
            applyVolumes(ramp: true)
        } else if spaceDown != nil {
            togglePlay()
        }
    }

    /// What's audible right now, peeking included.
    var audibleTrack: Track { isPeeking ? .original : track }

    // MARK: - Engine

    private func start(from seconds: Double) {
        guard let recording, let session = recording.session else { return }
        do {
            try prepareGraph(for: recording, session: session)
        } catch {
            return
        }
        generation += 1
        startPosition = seconds
        nextRestoredFrame = Int(seconds * Exporter.sampleRate)
        queuedBuffers = 0

        // Don't start the restored side on silence: wait for the chunk under the playhead.
        if session.restored(channel: 0, range: nextRestoredFrame..<min(nextRestoredFrame + 1, session.outputCount)) == nil,
           nextRestoredFrame < session.outputCount {
            isWaiting = true
            let generation = generation
            ticker?.cancel()
            ticker = Task { [weak self] in
                while let self, !Task.isCancelled, self.generation == generation {
                    if session.restored(channel: 0, range: nextRestoredFrame..<nextRestoredFrame + 1) != nil {
                        isWaiting = false
                        start(from: seconds)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            return
        }
        isWaiting = false

        guard let file = originalFile else { return }
        let sourceRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(seconds * sourceRate)
        let remaining = AVAudioFrameCount(max(0, file.length - startFrame))
        if remaining > 0 {
            originalNode.scheduleSegment(file, startingFrame: startFrame, frameCount: remaining, at: nil)
        }
        for _ in 0..<Self.buffersAhead { scheduleNextRestored(session) }

        applyVolumes(ramp: false)
        if !engine.isRunning { try? engine.start() }
        // Same host time for both, a little ahead so both nodes are ready.
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        originalNode.play(at: when)
        restoredNode.play(at: when)
        isPlaying = true
        startTicker()
        updateNowPlaying()
    }

    private func stop() {
        generation += 1
        ticker?.cancel()
        ticker = nil
        originalNode.stop()
        restoredNode.stop()
        isPlaying = false
        isWaiting = false
    }

    private func prepareGraph(for recording: Recording, session: RestorationSession) throws {
        if originalFile == nil || originalFile?.url != recording.url {
            originalFile = try AVAudioFile(forReading: recording.url)
        }
        let restored = AVAudioFormat(standardFormatWithSampleRate: Exporter.sampleRate,
                                     channels: AVAudioChannelCount(session.source.channelCount))!
        let original = originalFile!.processingFormat
        if restoredFormat != restored || engine.outputConnectionPoints(for: originalNode, outputBus: 0).isEmpty
            || originalNode.outputFormat(forBus: 0) != original {
            engine.stop()
            // Both versions → one mix → speed → out, so switching and speed never disagree.
            let mixed = AVAudioFormat(standardFormatWithSampleRate: Exporter.sampleRate, channels: 2)!
            engine.connect(originalNode, to: mix, format: original)
            engine.connect(restoredNode, to: mix, format: restored)
            engine.connect(mix, to: timePitch, format: mixed)
            engine.connect(timePitch, to: engine.mainMixerNode, format: mixed)
            timePitch.rate = rate
            restoredFormat = restored
        }
    }

    private func scheduleNextRestored(_ session: RestorationSession) {
        guard let format = restoredFormat, nextRestoredFrame < session.outputCount else { return }
        let range = nextRestoredFrame..<min(nextRestoredFrame + Self.bufferFrames, session.outputCount)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count))!
        buffer.frameLength = AVAudioFrameCount(range.count)
        for c in 0..<Int(format.channelCount) {
            // Not restored yet (rare: restoring runs far ahead of playback): play silence there.
            if let samples = session.restored(channel: c, range: range) {
                samples.withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: range.count) }
            }
        }
        nextRestoredFrame = range.upperBound
        queuedBuffers += 1
        let generation = generation
        restoredNode.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.queuedBuffers -= 1
                self.scheduleNextRestored(session)
            }
        }
    }

    private func startTicker() {
        ticker?.cancel()
        let generation = generation
        ticker = Task { [weak self] in
            var ticks = 0
            while let self, !Task.isCancelled, self.generation == generation {
                position = currentPosition()
                if position >= duration {
                    stop()
                    position = duration
                    rememberPosition()
                    updateNowPlaying()
                    return
                }
                ticks += 1
                if ticks % 30 == 0 {
                    // Once a second: restoring follows the playhead, and long files remember it.
                    recording?.onChange?()
                    if ticks % 150 == 0 { rememberPosition() }
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func currentPosition() -> Double {
        guard isPlaying, let nodeTime = restoredNode.lastRenderTime,
              let playerTime = restoredNode.playerTime(forNodeTime: nodeTime), playerTime.sampleTime >= 0 else {
            return position
        }
        return min(startPosition + Double(playerTime.sampleTime) / playerTime.sampleRate, duration)
    }

    // MARK: - Now Playing and media keys

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand
            .addTarget { [weak self] _ in self?.remote { $0.togglePlay() } ?? .noActionableNowPlayingItem }
        center.playCommand.addTarget { [weak self] _ in self?.remote { $0.play() } ?? .noActionableNowPlayingItem }
        center.pauseCommand.addTarget { [weak self] _ in self?.remote { $0.pause() } ?? .noActionableNowPlayingItem }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in self?.remote { $0.skip(by: 15) } ?? .noActionableNowPlayingItem }
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.remote { $0.skip(by: -15) } ?? .noActionableNowPlayingItem }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.remote { $0.seek(to: event.positionTime) } ?? .noActionableNowPlayingItem
        }
    }

    /// Media keys arrive on the main thread.
    private nonisolated func remote(_ action: @MainActor (Player) -> Void) -> MPRemoteCommandHandlerStatus {
        MainActor.assumeIsolated {
            guard recording != nil else { return .noActionableNowPlayingItem }
            action(self)
            return .success
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let recording else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: recording.name,
            MPMediaItemPropertyArtist: String(localized: "Restored by SoundOwl"),
            MPMediaItemPropertyPlaybackDuration: recording.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: isPlaying ? currentPosition() : position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        center.playbackState = isPlaying ? .playing : .paused
    }

    private func rememberPosition() {
        guard let recording else { return }
        ListeningPositions.remember(isPlaying ? currentPosition() : position, for: recording.url, duration: recording.duration)
    }

    // MARK: - Volumes

    private var originalLevel: Float { audibleTrack == .original ? (recording?.session?.originalGain ?? 1) : 0 }
    private var restoredLevel: Float { audibleTrack == .restored ? 1 : 0 }

    /// A 30 ms crossfade on switch, so flipping tracks never clicks.
    private func applyVolumes(ramp: Bool) {
        guard ramp else {
            originalNode.volume = originalLevel
            restoredNode.volume = restoredLevel
            return
        }
        let from = (originalNode.volume, restoredNode.volume)
        let to = (originalLevel, restoredLevel)
        Task { [weak self] in
            for step in 1...6 {
                guard let self else { return }
                let t = Float(step) / 6
                originalNode.volume = from.0 + (to.0 - from.0) * t
                restoredNode.volume = from.1 + (to.1 - from.1) * t
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }
}

/// Where you stopped in each long recording, so an audiobook opens where you left it.
enum ListeningPositions {
    private static let key = "ListeningPositions"
    /// Short recordings start from the top; there's nothing to find your way back to.
    private static let minimumDuration: Double = 5 * 60
    private static let limit = 200

    static func position(for url: URL, duration: Double) -> Double? {
        guard duration >= minimumDuration,
              let saved = UserDefaults.standard.dictionary(forKey: key)?[url.path] as? [String: Double],
              let seconds = saved["position"], seconds > 5, seconds < duration - 10 else { return nil }
        return seconds
    }

    static func remember(_ seconds: Double, for url: URL, duration: Double) {
        guard duration >= minimumDuration else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Double]] ?? [:]
        if seconds < 5 || seconds > duration - 10 {
            all[url.path] = nil
        } else {
            all[url.path] = ["position": seconds, "saved": Date().timeIntervalSince1970]
        }
        if all.count > limit {
            let oldest = all.sorted { ($0.value["saved"] ?? 0) < ($1.value["saved"] ?? 0) }.prefix(all.count - limit)
            for (path, _) in oldest { all[path] = nil }
        }
        UserDefaults.standard.set(all, forKey: key)
    }
}
