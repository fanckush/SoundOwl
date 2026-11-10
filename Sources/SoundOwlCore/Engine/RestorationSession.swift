import Foundation
import Synchronization

/// Everything SoundOwl keeps about one recording while restoring it, in scratch files.
///
/// The recording is decoded once to 16 kHz. Chunks are restored in whatever order the app asks
/// for (the playhead's first) into a 48 kHz store that the player and the exporter read from.
/// Changing a setting starts a new generation: a fresh output store, with nothing restored yet.
/// Every method is safe to call from any thread.
public final class RestorationSession: Sendable {
    public let source: AudioSource
    public let plan: ChunkPlan
    public let peakCount = 2000

    private let directory: URL
    private let input: PCMStore
    private let state: Mutex<State>

    private struct State {
        var generation = 0
        var denoise = false
        var output: PCMStore?
        var ready = Set<Int>()
        var peaks: [Float] = []
        var restoredPeaks: [Float] = []
        var cutoff: Double?
        /// Sums of squares over restored chunks, for loudness matching.
        var originalEnergy = 0.0
        var restoredEnergy = 0.0
    }

    public init(source: AudioSource) throws {
        self.source = source
        plan = ChunkPlan(count: source.modelFrameCount)
        directory = FileManager.default.temporaryDirectory.appending(path: "SoundOwl/\(UUID().uuidString)")
        input = try PCMStore(directory: directory, name: "input", channels: source.channelCount, count: plan.count)
        state = Mutex(State())
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    public var outputCount: Int { plan.count * Self.ratio }
    public var duration: Double { Double(plan.count) / Double(LavaSR.inputSampleRate) }
    static let ratio = LavaSR.outputSampleRate / LavaSR.inputSampleRate

    // MARK: - Preparing

    public var isPrepared: Bool { state.withLock { $0.cutoff != nil } }

    /// Decodes the recording and measures its bandwidth. Call once, before restoring.
    public func prepare(progress: (Double) -> Void = { _ in }) throws {
        let peaks = try source.decode(into: input, peakCount: peakCount, progress: progress)
        // A couple of minutes say enough about bandwidth.
        let sample = try input.read(channel: 0, range: 0..<min(plan.count, 120 * LavaSR.inputSampleRate))
        let cutoff = Bandwidth.cutoff(for: sample)
        try state.withLock { state in
            state.peaks = peaks
            state.cutoff = cutoff
            try startGeneration(&state)
        }
    }

    public var peaks: [Float] { state.withLock { $0.peaks } }
    public var restoredPeaks: [Float] { state.withLock { $0.restoredPeaks } }
    public var cutoff: Double? { state.withLock { $0.cutoff } }

    // MARK: - Settings

    public var denoise: Bool {
        get { state.withLock { $0.denoise } }
        set {
            try? state.withLock { state in
                guard state.denoise != newValue else { return }
                state.denoise = newValue
                if state.cutoff != nil { try startGeneration(&state) }
            }
        }
    }

    private func startGeneration(_ state: inout State) throws {
        state.generation += 1
        state.output = try PCMStore(directory: directory, name: "restored-\(state.generation)",
                                    channels: source.channelCount, count: outputCount)
        state.ready = []
        state.restoredPeaks = [Float](repeating: 0, count: peakCount)
        state.originalEnergy = 0
        state.restoredEnergy = 0
    }

    // MARK: - Restoring

    public var restoredFraction: Double {
        state.withLock { Double($0.ready.count) / Double(max(plan.chunkCount, 1)) }
    }

    public var isComplete: Bool { state.withLock { $0.ready.count == plan.chunkCount } }

    /// The next chunk worth restoring: the first missing one at or after `focus` (an input sample
    /// position), wrapping around to the start. With `ahead`, only the chunks from the one under
    /// `focus` to `ahead` past it count, with no wrapping: listening restores just in front of you.
    public func nextChunk(focus: Int = 0, ahead: Int? = nil) -> Int? {
        state.withLock { state in
            let count = plan.chunkCount
            let first = plan.chunk(containing: focus)
            if let ahead {
                return (first..<min(count, first + ahead + 1)).first { !state.ready.contains($0) }
            }
            return (0..<count).lazy.map { (first + $0) % count }.first { !state.ready.contains($0) }
        }
    }

    /// Frees restored chunks outside `keep`, so listening to a long audiobook doesn't fill the
    /// disk. They are restored again if the playhead comes back to them.
    public func forget(chunksOutside keep: ClosedRange<Int>) {
        let (output, forgotten) = state.withLock { state -> (PCMStore?, [Int]) in
            let outside = state.ready.filter { !keep.contains($0) }
            state.ready.subtract(outside)
            return (state.output, Array(outside))
        }
        guard let output else { return }
        for index in forgotten {
            let core = plan.core(index)
            for c in 0..<output.channelCount {
                output.discard(channel: c, range: core.lowerBound * Self.ratio..<core.upperBound * Self.ratio)
            }
        }
    }

    /// Chunks restored so far.
    public var readyChunks: Set<Int> { state.withLock { $0.ready } }

    /// Restores one chunk with `model`. Not concurrent with other calls using the same model.
    public func restore(chunk index: Int, with model: LavaSR) throws {
        let (generation, denoise, cutoff, output) = state.withLock { ($0.generation, $0.denoise, $0.cutoff, $0.output) }
        guard let output, let cutoff else { return }
        var restorer = Restorer(model: model)
        restorer.denoise = denoise
        restorer.cutoff = cutoff

        let core = plan.core(index)
        var originalEnergy = 0.0, restoredEnergy = 0.0
        var chunkPeaks = [Int: Float]()
        for c in 0..<source.channelCount {
            let y = try restorer.restoreChunk(index, of: plan) { try input.read(channel: c, range: $0) }
            try output.write(y, channel: c, at: core.lowerBound * Self.ratio)
            originalEnergy += try input.read(channel: c, range: core).reduce(0) { $0 + Double($1 * $1) } * Double(Self.ratio)
            restoredEnergy += y.reduce(0) { $0 + Double($1 * $1) }
            for (i, sample) in y.enumerated() {
                let bucket = min(peakCount - 1, (core.lowerBound * Self.ratio + i) * peakCount / outputCount)
                chunkPeaks[bucket] = max(chunkPeaks[bucket] ?? 0, abs(sample))
            }
        }

        state.withLock { state in
            // A setting changed while this chunk ran; its audio belongs to a dead generation.
            guard state.generation == generation else { return }
            state.ready.insert(index)
            state.originalEnergy += originalEnergy
            state.restoredEnergy += restoredEnergy
            for (bucket, peak) in chunkPeaks { state.restoredPeaks[bucket] = max(state.restoredPeaks[bucket], peak) }
        }
    }

    /// Gain that brings the original to the restored loudness, for a fair A/B. Within ±6 dB.
    public var originalGain: Float {
        state.withLock { state in
            guard state.originalEnergy > 0, state.restoredEnergy > 0 else { return 1 }
            let gain = (state.restoredEnergy / state.originalEnergy).squareRoot()
            return Float(min(max(gain, 0.5), 2))
        }
    }

    // MARK: - Reading restored audio

    /// Restored 48 kHz samples, or nil if any part of `range` is not restored yet.
    public func restored(channel: Int, range: Range<Int>) -> [Float]? {
        let (output, ready) = state.withLock { ($0.output, $0.ready) }
        guard let output, !range.isEmpty else { return nil }
        let first = plan.chunk(containing: range.lowerBound / Self.ratio)
        let last = plan.chunk(containing: (range.upperBound - 1) / Self.ratio)
        guard (first...last).allSatisfy(ready.contains) else { return nil }
        return try? output.read(channel: min(channel, source.channelCount - 1), range: range)
    }

    /// The whole restored store, once every chunk is done, for exporting.
    public func completedOutput() -> PCMStore? {
        state.withLock { $0.ready.count == plan.chunkCount ? $0.output : nil }
    }
}
