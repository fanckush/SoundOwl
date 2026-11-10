import Foundation

/// Restores a live 16 kHz stream with a fixed, small delay.
///
/// Each hop of `core` samples is restored once `after` samples past it have arrived, from a window
/// that also holds `before` samples of history. Underneath it is `Restorer.restoreChunk` on a
/// `ChunkPlan` that never ends, so a stream gets exactly what a file with the same sizes would,
/// and every window stays on the frame grid.
///
/// Not thread-safe: call it from one thread, like `LavaSR`.
public final class StreamRestorer {
    public let plan: ChunkPlan
    /// Input samples over which each hop fades in from the previous hop's overrun (0: hard cut).
    public let crossfade: Int

    private var restorer: Restorer
    private var history: [Float] = []
    private var historyStart = 0
    private var received = 0
    private var nextHop = 0
    private var overrun: [Float] = []
    private let fadeIn: [Float]

    private static let ratio = LavaSR.outputSampleRate / LavaSR.inputSampleRate

    /// Sizes are in 16 kHz samples and must be multiples of `ChunkPlan.grid` (32 ms).
    public init(model: LavaSR, core: Int, before: Int, after: Int, crossfade: Int = 0,
                cutoff: Double? = nil, denoise: Bool = false) {
        precondition(crossfade <= after, "the crossfade must fit inside the right context")
        plan = ChunkPlan(count: Int.max / 4, core: core, before: before, after: after)
        self.crossfade = crossfade
        restorer = Restorer(model: model)
        restorer.cutoff = cutoff
        restorer.denoise = denoise
        let n = crossfade * Self.ratio
        // Raised cosine; fade-in and fade-out sum to one, as they should for two takes of one signal.
        fadeIn = (0..<n).map { Float(0.5 - 0.5 * cos(Double.pi * (Double($0) + 0.5) / Double(n))) }
    }

    /// The band-merge cutoff. A change applies from the next hop.
    public var cutoff: Double? {
        get { restorer.cutoff }
        set { restorer.cutoff = newValue }
    }

    public var denoise: Bool {
        get { restorer.denoise }
        set { restorer.denoise = newValue }
    }

    /// How long a sample waits between arriving and leaving, in 16 kHz samples, not counting compute.
    public var latency: Int { plan.core + plan.after }

    /// Takes the next input samples and returns every hop that became ready, as 48 kHz samples.
    /// Output always comes in whole hops of `core * 3` samples.
    public func push(_ x16: [Float]) throws -> [Float] {
        history += x16
        received += x16.count
        var out = [Float]()
        while (nextHop + 1) * plan.core + plan.after <= received {
            out += try restoreHop(nextHop)
            nextHop += 1
            let keepFrom = max(0, nextHop * plan.core - plan.before)
            if keepFrom > historyStart {
                history.removeFirst(keepFrom - historyStart)
                historyStart = keepFrom
            }
        }
        return out
    }

    /// Ends the stream: flushes what is left as if silence followed, so every pushed sample has
    /// left as output. For offline comparisons; a live stream just stops.
    public func finish() throws -> [Float] {
        let total = received
        let hops = (total + plan.core - 1) / plan.core
        let missing = max(0, hops * plan.core + plan.after - received)
        var out = try push([Float](repeating: 0, count: missing))
        let excess = nextHop * plan.core * Self.ratio - total * Self.ratio
        out.removeLast(min(excess, out.count))
        return out
    }

    private func restoreHop(_ index: Int) throws -> [Float] {
        var y = try restorer.restoreChunk(index, of: plan, extra: crossfade) { range in
            Array(history[(range.lowerBound - historyStart)..<(range.upperBound - historyStart)])
        }
        let coreCount = plan.core * Self.ratio
        if !overrun.isEmpty {
            for i in 0..<min(overrun.count, fadeIn.count) {
                y[i] = overrun[i] * (1 - fadeIn[i]) + y[i] * fadeIn[i]
            }
        }
        overrun = crossfade > 0 ? Array(y[coreCount...]) : []
        return Array(y[..<coreCount])
    }
}
