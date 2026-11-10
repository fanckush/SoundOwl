import Accelerate
import AudioToolbox
import Foundation
import SoundOwlCore
import Synchronization

/// The sizes Live restores with. All in 16 kHz samples, multiples of `ChunkPlan.grid` (32 ms).
public struct LiveSettings: Sendable, Equatable {
    public var core: Int
    public var before: Int
    public var after: Int
    /// ORT threads for the live model, so a call doesn't get every core.
    public var threads: Int
    /// Slack on top of the computed delay, in seconds, for scheduling hiccups.
    public var safety: Double

    public init(core: Int, before: Int, after: Int, threads: Int = 2, safety: Double = 0.015) {
        self.core = core
        self.before = before
        self.after = after
        self.threads = threads
        self.safety = safety
    }

    /// 32 ms hops, 512 ms of history and 128 ms of look-ahead: about 190 ms in all, the shortest
    /// look-ahead the feasibility run (docs/engine.md) found close to the offline restore. The
    /// blind listening test decides whether this moves.
    public static let standard = LiveSettings(core: 512, before: 8192, after: 2048)

    /// How long Live waits for what comes next before restoring a moment: the trade between
    /// delay and clarity, as the panel offers it. About 135, 190 and 255 ms in all.
    public enum Balance: Int, CaseIterable, Sendable, Codable {
        case faster
        case balanced
        case clearer

        public var settings: LiveSettings {
            var settings = LiveSettings.standard
            settings.after = LiveSettings.samples(milliseconds: [64, 128, 192][rawValue])
            return settings
        }
    }

    /// Milliseconds to 16 kHz samples, on the grid.
    public static func samples(milliseconds: Int) -> Int {
        let n = milliseconds * LavaSR.inputSampleRate / 1000
        return n / ChunkPlan.grid * ChunkPlan.grid
    }
}

/// Restores a live stream as it plays, a fixed delay behind it.
///
/// `render` runs on the audio device's real-time thread. It hands the incoming audio to an engine
/// thread and plays what came in `delay` frames ago: restored if the engine has it ready, the
/// original otherwise, crossfading between the two. A slow or stalled engine means hearing the
/// person unrestored, never silence.
///
/// Everything `render` touches is preallocated; it never locks or allocates.
public final class LivePipeline: @unchecked Sendable {
    public let sampleRate: Double
    /// How far output trails input, in device frames.
    public let delay: Int
    public let settings: LiveSettings

    // MARK: Shared with the engine thread

    private let incoming: SampleFIFO
    private let restored: TimelineRing
    private let wake = DispatchSemaphore(value: 0)
    private let stopping = Atomic<Bool>(false)
    /// The call is already full-band.
    private let fullBand = Atomic<Bool>(false)
    /// Restoring right now; otherwise the original plays untouched.
    private let restoring = Atomic<Bool>(false)
    /// Set once the first cutoff is measured. Until then the original plays.
    private let ready = Atomic<Bool>(false)
    /// Where the current run of restoring began: frames from here on should come restored.
    private let restoringFrom = Atomic<Int>(Int.max)

    // MARK: Statistics, readable from anywhere

    /// Frames played, and frames played from the original because nothing restored was ready
    /// (not counting bypass or the wait for the first cutoff).
    public let framesPlayed = Atomic<Int>(0)
    public let framesFallenBack = Atomic<Int>(0)
    /// The current run of fallback frames, for the watchdog.
    public let fallbackRun = Atomic<Int>(0)
    /// The last input frame that wasn't digital silence, for spotting a tap without permission.
    public let lastSoundFrame = Atomic<Int>(-1)
    public let framesReceived = Atomic<Int>(0)
    /// Times the engine fell so far behind that it started over at the present.
    public let restarts = Atomic<Int>(0)
    /// The band-merge cutoff in use, in Hz (0 until measured).
    public let cutoffHz = Atomic<Int>(0)
    /// Engine time per hop in microseconds: the latest and the worst.
    public let lastHopMicros = Atomic<Int>(0)
    public let worstHopMicros = Atomic<Int>(0)

    // MARK: Choices, changeable while it runs

    /// Sound that is already full-band plays untouched. Off: every voice is restored.
    public let leavesClearSoundAlone = Atomic<Bool>(true)
    /// Background noise is reduced too. Costs about three times the compute.
    public let reducesNoise = Atomic<Bool>(false)

    /// Playing untouched because the sound is already full-band (and that's wanted).
    public var isAlreadyClear: Bool {
        isReady && kind != .music && fullBand.load(ordering: .relaxed) && leavesClearSoundAlone.load(ordering: .relaxed)
    }
    public var isReady: Bool { ready.load(ordering: .relaxed) }
    /// Voice or music, as far as the classifier can tell.
    public var kind: SoundKind { detector?.kind ?? .voice }

    // MARK: IOProc-only state

    private let maxFrames: Int
    private let historyMask: Int
    private let historyLeft: UnsafeMutablePointer<Float>
    private let historyRight: UnsafeMutablePointer<Float>
    private let mono: UnsafeMutablePointer<Float>
    private var position = 0
    private var gain: Float = 0
    private let gainStep: Float

    // MARK: Engine-only state

    private let model: LavaSR
    private let alignment: Int
    /// Music is left alone: the model is made for voices. Without the classifier, all is voice.
    private let detector: SoundKindDetector?
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)

    /// - Parameters:
    ///   - sampleRate: the device's rate; input and output run at it.
    ///   - bufferFrames: the device's I/O buffer size, which the delay has to cover.
    public init(model: LavaSR, sampleRate: Double, bufferFrames: Int, settings: LiveSettings = .standard) throws {
        self.model = model
        self.sampleRate = sampleRate
        self.settings = settings
        maxFrames = max(4096, 4 * bufferFrames)
        alignment = try Self.measureAlignment(sampleRate: sampleRate)
        let perInput = sampleRate / Double(LavaSR.inputSampleRate)
        // Restored frame n needs input up to n + core + after, which arrives one callback later
        // than the frame itself and then takes a hop's compute.
        delay = Int((Double(settings.core + settings.after) * perInput).rounded(.up)) + alignment
            + 2 * bufferFrames + Int(settings.safety * sampleRate)

        let historySize = Self.powerOfTwo(atLeast: delay + 2 * maxFrames)
        historyMask = historySize - 1
        historyLeft = .allocate(capacity: historySize)
        historyLeft.initialize(repeating: 0, count: historySize)
        historyRight = .allocate(capacity: historySize)
        historyRight.initialize(repeating: 0, count: historySize)
        mono = .allocate(capacity: maxFrames)
        mono.initialize(repeating: 0, count: maxFrames)
        incoming = SampleFIFO(minimumCapacity: Int(sampleRate * 4))
        restored = TimelineRing(minimumCapacity: delay + Int(sampleRate * 2))
        gainStep = Float(1 / (0.005 * sampleRate))
        detector = SoundKindDetector(sampleRate: sampleRate)
    }

    deinit {
        historyLeft.deallocate()
        historyRight.deallocate()
        mono.deallocate()
    }

    public var latencySeconds: Double { Double(delay) / sampleRate }

    // MARK: - Engine thread

    /// Starts restoring. The first hop warms the model up first, off the audio thread.
    public func start() {
        guard thread == nil else { return }
        let thread = Thread { [self] in engineLoop() }
        thread.name = "SoundOwl Live"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Stops the engine and waits for its last hop, so the model is free for someone else.
    public func stop() {
        guard thread != nil, !stopping.exchange(true, ordering: .acquiringAndReleasing) else { return }
        wake.signal()
        finished.wait()
    }

    private func engineLoop() {
        defer {
            detector?.stop()
            finished.signal()
        }
        var buffer = [Float](repeating: 0, count: incoming.capacity)
        var stream: Stream?
        var analysis = Analysis(sampleRate: sampleRate)
        var consumed = 0
        // Where the first measurement landed: the classifier gets a few seconds more to decide.
        var measuredAt: Int?
        var lastKind = SoundKind.unknown

        // One hop of silence first: the first run of a graph is the slow one.
        _ = try? StreamRestorer(model: model, core: settings.core, before: settings.before, after: settings.after)
            .push([Float](repeating: 0, count: settings.core + settings.after))

        while !stopping.load(ordering: .acquiring) {
            _ = wake.wait(timeout: .now() + .milliseconds(100))
            let n = buffer.withUnsafeMutableBufferPointer { incoming.read(into: $0.baseAddress!, maxCount: $0.count) }
            guard n > 0 else { continue }
            let block = Array(buffer[..<n])
            let start = consumed
            consumed += n

            // Hopelessly behind (the Mac stalled, or a debugger paused us): start over at the present.
            // This block is already late too, so the new stream begins with the next one.
            if let current = stream, restored.readerPosition > current.outputPosition + Int(sampleRate / 2) {
                stream = nil
                restarts.add(1, ordering: .relaxed)
                continue
            }

            detector?.add(block)
            let heard = kind
            if heard != lastKind {
                if lastKind != .unknown { analysis.soundChanged() }
                lastKind = heard
            }
            if let measured = analysis.add(block) {
                fullBand.store(measured.fullBand, ordering: .relaxed)
                cutoffHz.store(Int(measured.cutoff), ordering: .relaxed)
                stream?.restorer.cutoff = measured.cutoff
                measuredAt = measuredAt ?? start
            }
            // Ready once the bandwidth is measured and it's known whether this is music (or the
            // classifier stayed unsure a few seconds longer: then it's taken as a voice).
            if !ready.load(ordering: .relaxed), let measuredAt,
               kind != .unknown || start - measuredAt > Int(sampleRate * 3) {
                ready.store(true, ordering: .releasing)
            }
            let restore = ready.load(ordering: .relaxed) && kind != .music
                && !(fullBand.load(ordering: .relaxed) && leavesClearSoundAlone.load(ordering: .relaxed))
            restoring.store(restore, ordering: .relaxed)
            guard restore else {
                stream = nil
                continue
            }

            do {
                if stream == nil {
                    restoringFrom.store(start, ordering: .relaxed)
                    stream = try Stream(model: model, settings: settings, sampleRate: sampleRate,
                                        startingAt: start, alignment: alignment,
                                        cutoff: Double(cutoffHz.load(ordering: .relaxed)))
                }
                let denoise = reducesNoise.load(ordering: .relaxed)
                if stream!.restorer.denoise != denoise { stream!.restorer.denoise = denoise }
                let began = DispatchTime.now().uptimeNanoseconds
                let produced = try stream!.process(block)
                let micros = Int((DispatchTime.now().uptimeNanoseconds - began) / 1000)
                if produced.hops > 0 {
                    let perHop = micros / produced.hops
                    lastHopMicros.store(perHop, ordering: .relaxed)
                    if perHop > worstHopMicros.load(ordering: .relaxed) { worstHopMicros.store(perHop, ordering: .relaxed) }
                }
                if !produced.frames.isEmpty {
                    produced.frames.withUnsafeBufferPointer {
                        restored.write($0.baseAddress!, count: $0.count, at: produced.position)
                    }
                }
            } catch {
                // A failed hop plays as the original; try again from the present.
                stream = nil
            }
        }
    }

    /// One unbroken run of restoring: input at the device rate → 16 kHz → the model → 48 kHz →
    /// the device rate, with the output lined up on the input's frame positions.
    private struct Stream {
        let restorer: StreamRestorer
        let down: StreamingResampler
        let up: StreamingResampler
        /// Where the next output frame lands on the timeline.
        var outputPosition: Int
        /// Output frames that still belong before the stream started (resampler start-up).
        var skip: Int

        init(model: LavaSR, settings: LiveSettings, sampleRate: Double, startingAt start: Int,
             alignment: Int, cutoff: Double) throws {
            restorer = StreamRestorer(model: model, core: settings.core, before: settings.before,
                                      after: settings.after, cutoff: cutoff > 0 ? cutoff : nil)
            down = StreamingResampler(from: sampleRate, to: Double(LavaSR.inputSampleRate))
            up = StreamingResampler(from: Double(LavaSR.outputSampleRate), to: sampleRate)
            // Output frame k of this stream shows input frame start + k - alignment.
            outputPosition = start
            skip = alignment
        }

        struct Produced {
            var frames: [Float]
            /// Where `frames` start on the timeline.
            var position: Int
            var hops: Int
        }

        mutating func process(_ block: [Float]) throws -> Produced {
            let x16 = try down.process(block)
            let y48 = try restorer.push(x16)
            let hops = y48.count / (restorer.plan.core * 3)
            guard !y48.isEmpty else { return Produced(frames: [], position: outputPosition, hops: 0) }
            var y = try up.process(y48)
            if skip > 0 {
                let dropped = min(skip, y.count)
                y.removeFirst(dropped)
                skip -= dropped
            }
            let position = outputPosition
            outputPosition += y.count
            return Produced(frames: y, position: position, hops: hops)
        }
    }

    /// Measures the call's bandwidth as it goes: from the first 3 s of sound, then every 10 s.
    /// New sound measures sooner: after 2 s of quiet (the next video, the next speaker) the next
    /// 3 s of sound are measured on their own, and when the sound changes kind (music to talk)
    /// the last 3 s are measured right away.
    private struct Analysis {
        struct Measurement: Equatable {
            var cutoff: Double
            var fullBand: Bool
        }

        let sampleRate: Double
        private var recent: [Float] = []
        private var speech = 0
        private var sinceLast = 0
        private var quiet = 0
        /// Measure as soon as there are 3 s of sound, and take the result as it is.
        private var fresh = true
        private var current: Measurement?
        private var pending: Double?
        /// The last measurement found the sound full-band.
        private var lastFullBand = false
        private let window: Int

        init(sampleRate: Double) {
            self.sampleRate = sampleRate
            window = Int(sampleRate * 3)
        }

        /// What's playing changed kind: what's in the window now is the new sound.
        mutating func soundChanged() {
            fresh = true
            speech = max(speech, recent.count)
        }

        /// Returns a new measurement when there is one.
        mutating func add(_ block: [Float]) -> Measurement? {
            if vDSP.rootMeanSquare(block) > 0.003 {
                speech += block.count
                quiet = 0
            } else {
                quiet += block.count
                if quiet >= Int(sampleRate * 2), !fresh || !recent.isEmpty {
                    // Whatever plays next is measured on its own.
                    fresh = true
                    recent = []
                    speech = 0
                }
            }
            recent += block
            if recent.count > window { recent.removeFirst(recent.count - window) }
            sinceLast += block.count
            let due = fresh ? speech >= window : sinceLast >= Int(sampleRate * 10)
            guard due, speech >= window / 2 else { return nil }
            sinceLast = 0
            speech = 0
            guard let x16 = try? AudioIO.resample(recent, from: sampleRate, to: Double(LavaSR.inputSampleRate))
            else { return nil }
            let cutoff = Bandwidth.cutoff(for: x16)
            let fullBand = Quality.hasFullBandContent(recent, sampleRate: sampleRate)
            defer { lastFullBand = fullBand }
            guard let previous = current, !fresh else {
                fresh = false
                pending = nil
                let next = Measurement(cutoff: cutoff, fullBand: fullBand)
                guard next != current else { return nil }
                current = next
                return next
            }
            // Within the same sound, a cutoff moves only when two measurements in a row agree, or
            // it jumped a lot.
            var next = previous
            if abs(cutoff - previous.cutoff) >= 1000 || (pending.map { abs($0 - cutoff) < 250 } ?? false
                && abs(cutoff - previous.cutoff) >= 250) {
                next.cutoff = cutoff
            }
            pending = cutoff
            // Restoring stops only when two measurements in a row find the sound clear: 3 s of a
            // dull voice can read as full-band now and then (sibilants). It starts again at once.
            next.fullBand = fullBand && (previous.fullBand || lastFullBand)
            guard next != previous else { return nil }
            current = next
            return next
        }
    }

    // MARK: - Real-time side

    /// Called by the IOProc with the tapped audio and the device's output buffers, both
    /// 32-bit float. Missing input plays as silence; missing output means nothing to fill.
    public func render(input: UnsafePointer<AudioBufferList>?, output: UnsafeMutablePointer<AudioBufferList>?,
                       frames requested: Int) {
        let frames = min(requested, maxFrames)
        guard frames > 0 else { return }
        if requested > frames, let output { Self.silence(output, from: frames, to: requested) }
        let start = position
        take(input, frames: frames, at: start)
        position = start + frames
        framesReceived.store(position, ordering: .relaxed)
        wake.signal()
        if let output { play(into: output, frames: frames, from: start - delay) }
    }

    /// Keeps both channels for the original path and sends the mono mix to the engine.
    private func take(_ input: UnsafePointer<AudioBufferList>?, frames: Int, at start: Int) {
        var left: UnsafePointer<Float>?, right: UnsafePointer<Float>?
        var leftStride = 1, rightStride = 1
        if let input {
            var channel = 0
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, Int(buffer.mDataByteSize) >= frames * channels * 4 else { continue }
                for c in 0..<channels {
                    if channel == 0 { left = UnsafePointer(data + c); leftStride = channels }
                    if channel == 1 { right = UnsafePointer(data + c); rightStride = channels }
                    channel += 1
                }
            }
        }
        if right == nil { right = left; rightStride = leftStride }
        var loud = false
        for i in 0..<frames {
            let l = left?[i * leftStride] ?? 0, r = right?[i * rightStride] ?? 0
            let slot = (start + i) & historyMask
            historyLeft[slot] = l
            historyRight[slot] = r
            mono[i] = 0.5 * (l + r)
            if l != 0 || r != 0 { loud = true }
        }
        incoming.write(mono, count: frames)
        if loud { lastSoundFrame.store(start + frames - 1, ordering: .relaxed) }
    }

    /// Plays the frames from `from` on: restored where the engine has them, the original otherwise.
    private func play(into output: UnsafeMutablePointer<AudioBufferList>, frames: Int, from: Int) {
        let have = restored.available(in: from..<(from + frames))
        let wantRestored = restoring.load(ordering: .relaxed)
        let expectedFrom = restoringFrom.load(ordering: .relaxed)
        var fallback = 0
        let outList = UnsafeMutableAudioBufferListPointer(output)
        for i in 0..<frames {
            let p = from + i
            let slot = p & historyMask
            let l = p >= 0 ? historyLeft[slot] : 0, r = p >= 0 ? historyRight[slot] : 0
            let isRestored = have.contains(p)
            if wantRestored, !isRestored, p >= expectedFrom { fallback += 1 }
            let target: Float = wantRestored && isRestored ? 1 : 0
            gain = gain < target ? min(target, gain + gainStep) : max(target, gain - gainStep)
            let x = isRestored ? restored.frame(at: p) : 0
            let outLeft = isRestored ? gain * x + (1 - gain) * l : l
            let outRight = isRestored ? gain * x + (1 - gain) * r : r

            var channel = 0
            for buffer in outList {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = Int(buffer.mNumberChannels)
                guard Int(buffer.mDataByteSize) >= frames * channels * 4 else { continue }
                for c in 0..<channels {
                    data[i * channels + c] = channel == 0 ? outLeft : outRight
                    channel += 1
                }
            }
        }
        restored.advanceReader(to: from + frames)
        framesPlayed.add(frames, ordering: .relaxed)
        if fallback > 0 {
            framesFallenBack.add(fallback, ordering: .relaxed)
            fallbackRun.add(fallback, ordering: .relaxed)
        } else {
            fallbackRun.store(0, ordering: .relaxed)
        }
    }

    // MARK: - Helpers

    /// Never leave stale samples in a buffer the device will play: they'd repeat.
    private static func silence(_ output: UnsafeMutablePointer<AudioBufferList>, from: Int, to: Int) {
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(buffer.mNumberChannels)
            let capacity = Int(buffer.mDataByteSize) / 4
            let lower = min(from * channels, capacity), upper = min(to * channels, capacity)
            if upper > lower { (data + lower).update(repeating: 0, count: upper - lower) }
        }
    }

    /// How many device frames the two resamplers delay the signal by, measured with an impulse
    /// fed in blocks the way the engine feeds them.
    static func measureAlignment(sampleRate: Double) throws -> Int {
        let block = 480
        let length = Int(sampleRate) // one second
        let at = length / 3
        var impulse = [Float](repeating: 0, count: length)
        impulse[at] = 1
        let down = StreamingResampler(from: sampleRate, to: Double(LavaSR.inputSampleRate))
        var x16 = [Float]()
        for i in stride(from: 0, to: length, by: block) {
            x16 += try down.process(Array(impulse[i..<min(i + block, length)]))
        }
        // The model maps 16 kHz sample k to 48 kHz sample 3k; stand in for it with an ideal x3.
        var y48 = [Float](repeating: 0, count: x16.count * 3)
        for (k, v) in x16.enumerated() { y48[3 * k] = 3 * v }
        let up = StreamingResampler(from: Double(LavaSR.outputSampleRate), to: sampleRate)
        var y = [Float]()
        for i in stride(from: 0, to: y48.count, by: 1440) {
            y += try up.process(Array(y48[i..<min(i + 1440, y48.count)]))
        }
        guard let peak = y.indices.max(by: { abs(y[$0]) < abs(y[$1]) }) else { return 0 }
        return max(0, peak - at)
    }

    private static func powerOfTwo(atLeast n: Int) -> Int {
        var size = 1
        while size < n { size <<= 1 }
        return size
    }
}
