import Foundation

/// How a 16 kHz signal of `count` samples is cut into chunks for `Restorer`.
///
/// Each chunk is restored from a window with context on both sides, and only its core is kept.
/// Chunks are independent, so they can be restored in any order (the playhead's first) and the
/// result is the same as one pass: chunking is an implementation detail.
public struct ChunkPlan: Sendable, Equatable {
    public let count: Int
    public let core: Int
    /// Context before and after each core. Files use the same on both sides; a live stream has
    /// plenty of past but can only wait for a little future, so it keeps `after` short.
    public let before: Int
    public let after: Int

    /// The networks are not shift-invariant: the high band they generate depends on where the
    /// STFT frames fall. Cores and context are multiples of 512 input samples, so every window is
    /// on the frame grid of a single pass (BWE hop 512 at 48 kHz, denoiser hop 256 at 16 kHz).
    public static let grid = 512

    /// Silence before the signal, so real audio never sits at a window edge where the merge FFT
    /// wraps around and the STFTs reflect.
    static let lead = grid

    /// Silence after the signal. Covers the hop upstream drops at the end, and gives very short
    /// clips enough room for the STFTs.
    static let tail = LavaSR.minimumInputCount

    public init(count: Int, chunkSeconds: Double = 30, contextSeconds: Double = 1) {
        let rate = Double(LavaSR.inputSampleRate)
        self.count = count
        core = max(Self.grid, Int(chunkSeconds * rate) / Self.grid * Self.grid)
        before = Int(contextSeconds * rate) / Self.grid * Self.grid
        after = before
    }

    /// Exact sizes in 16 kHz samples. All three must be multiples of `grid`, which keeps every
    /// window start (`index * core - before`) on the frame grid of a single pass.
    public init(count: Int, core: Int, before: Int, after: Int) {
        precondition(core > 0 && before >= 0 && after >= 0, "sizes must be positive")
        precondition([core, before, after].allSatisfy { $0 % Self.grid == 0 },
                     "core and context must be multiples of \(Self.grid) samples")
        self.count = count
        self.core = core
        self.before = before
        self.after = after
    }

    public var chunkCount: Int { (count + core - 1) / core }

    /// Input samples whose restoration this chunk produces.
    public func core(_ index: Int) -> Range<Int> {
        let start = index * core
        return start..<min(start + core, count)
    }

    /// Input samples the chunk is restored from, in signal coordinates. Can reach past both ends,
    /// where the signal reads as silence.
    public func window(_ index: Int) -> Range<Int> {
        let core = core(index)
        return max(-Self.lead, core.lowerBound - before)..<min(count + Self.tail, core.upperBound + after)
    }

    /// The chunk holding input sample `position`.
    public func chunk(containing position: Int) -> Int {
        min(max(0, position / core), max(0, chunkCount - 1))
    }
}

/// Runs `LavaSR` over audio of any length, one chunk at a time.
/// Output is always exactly three times the input length, so durations are preserved to the sample.
public struct Restorer {
    public var cutoff: Double?
    /// Upstream's 1024-bin crossover is about this wide on the few-second clips it was tuned on.
    public var transitionHz = 170.0
    public var denoise = false

    private let model: LavaSR

    public init(model: LavaSR) {
        self.model = model
    }

    /// Restores one chunk. `input` returns the 16 kHz samples of a range inside the signal.
    /// Returns 48 kHz samples for `plan.core(index)`.
    public func restoreChunk(_ index: Int, of plan: ChunkPlan,
                             input: (Range<Int>) throws -> [Float]) throws -> [Float] {
        try restoreChunk(index, of: plan, extra: 0, input: input)
    }

    /// Like `restoreChunk(_:of:input:)`, plus `extra` (at most `plan.after`) input samples' worth
    /// of output past the core, for crossfading into the next chunk.
    public func restoreChunk(_ index: Int, of plan: ChunkPlan, extra: Int,
                             input: (Range<Int>) throws -> [Float]) throws -> [Float] {
        precondition(extra >= 0 && extra <= plan.after, "extra must lie inside the right context")
        let ratio = LavaSR.outputSampleRate / LavaSR.inputSampleRate
        let core = plan.core(index)
        let window = plan.window(index)

        // Silence outside the signal, real samples inside.
        let inside = max(0, window.lowerBound)..<min(plan.count, window.upperBound)
        var x = [Float](repeating: 0, count: inside.lowerBound - window.lowerBound)
        x += try input(inside)
        x += [Float](repeating: 0, count: window.upperBound - inside.upperBound)

        let y = try model.enhance(x, cutoff: cutoff, transitionHz: transitionHz, denoise: denoise)
        let from = (core.lowerBound - window.lowerBound) * ratio
        // Windows are multiples of the grid, so the model returns exactly three times its input.
        let to = min(from + (core.count + extra) * ratio, y.count)
        precondition(to >= from + core.count * ratio, "the model returned less than the core")
        return Array(y[from..<to])
    }

    /// 16 kHz mono in, 48 kHz out, in memory. For tests and the CLI; the app restores chunks
    /// straight from and to disk.
    public func restore(_ x16: [Float], chunkSeconds: Double = 30,
                        progress: (Double) -> Void = { _ in }) throws -> [Float] {
        let plan = ChunkPlan(count: x16.count, chunkSeconds: chunkSeconds)
        var out = [Float]()
        out.reserveCapacity(x16.count * LavaSR.outputSampleRate / LavaSR.inputSampleRate)
        for index in 0..<plan.chunkCount {
            try Task.checkCancellation()
            out += try restoreChunk(index, of: plan) { Array(x16[$0]) }
            progress(Double(index + 1) / Double(plan.chunkCount))
        }
        return out
    }
}
