import Accelerate
import Foundation

/// Signal helpers that mirror the torch/numpy calls upstream LavaSR relies on.
/// `tools/model-export/mirror.py` is the reference for each of them.
enum Signal {
    /// Periodic Hann window, as `torch.hann_window(n)`.
    static func hann(_ n: Int) -> [Float] {
        (0..<n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n)) }
    }

    /// `np.pad(x, (left, right), mode="reflect")`: mirrors around the edge sample without repeating it.
    static func reflectPad(_ x: [Float], left: Int, right: Int) -> [Float] {
        precondition(left < x.count && right < x.count, "reflect padding needs a longer signal")
        var out = [Float]()
        out.reserveCapacity(x.count + left + right)
        for i in stride(from: left, to: 0, by: -1) { out.append(x[i]) }
        out.append(contentsOf: x)
        for i in 0..<right { out.append(x[x.count - 2 - i]) }
        return out
    }

    /// `torchaudio.functional.resample` with its defaults (sinc_interp_hann, 6 zero crossings, 0.99 rolloff).
    static func resample(_ x: [Float], from source: Int, to target: Int) -> [Float] {
        let g = gcd(source, target)
        let orig = source / g, new = target / g
        let (kernels, width) = sincKernels(orig: orig, new: new)
        let taps = kernels[0].count
        let padded = [Float](repeating: 0, count: width) + x + [Float](repeating: 0, count: width + orig)
        let steps = (padded.count - taps) / orig + 1
        var y = [Float](repeating: 0, count: steps * new)
        var phase = [Float](repeating: 0, count: steps)
        for (j, kernel) in kernels.enumerated() {
            // phase[s] = Σ padded[s·orig + p] · kernel[p]
            vDSP_desamp(padded, vDSP_Stride(orig), kernel, &phase, vDSP_Length(steps), vDSP_Length(taps))
            for s in 0..<steps { y[s * new + j] = phase[s] }
        }
        let length = Int((Double(new) * Double(x.count) / Double(orig)).rounded(.up))
        return Array(y.prefix(length))
    }

    private static func sincKernels(orig: Int, new: Int, zeros: Double = 6, rolloff: Double = 0.99) -> ([[Float]], Int) {
        let base = Double(min(orig, new)) * rolloff
        let width = Int((zeros * Double(orig) / base).rounded(.up))
        let kernels = (0..<new).map { j in
            (-width..<(width + orig)).map { i -> Float in
                var t = (-Double(j) / Double(new) + Double(i) / Double(orig)) * base
                t = min(max(t, -zeros), zeros)
                let window = pow(cos(t * .pi / zeros / 2), 2)
                let sinc = t == 0 ? 1 : sin(t * .pi) / (t * .pi)
                return Float(sinc * window * base / Double(orig))
            }
        }
        return (kernels, width)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    /// Width of the crossover in `bandMerge`.
    enum Transition {
        /// Upstream's definition: bins of one FFT over the whole signal, so the width in Hz
        /// shrinks as the signal gets longer.
        case bins(Int)
        /// The same width whatever the length, which chunked processing needs.
        case hertz(Double)
    }

    /// LavaSR's FastLRMerge: keeps `original` below `cutoff` and `predicted` above it, with a
    /// smoothstep crossover computed on a single FFT across the whole signal.
    static func bandMerge(predicted: [Float], original: [Float], cutoff: Double,
                          transition: Transition = .bins(1024), sampleRate: Double = 48_000) -> [Float] {
        precondition(predicted.count == original.count)
        let n = predicted.count
        // Upstream's exact length is only needed to reproduce its bin-based crossover. With a width
        // in Hz, zero padding to a length vDSP transforms directly gives the same filter, faster.
        let length: Int
        let transitionBins: Int
        switch transition {
        case .bins(let count):
            length = n
            transitionBins = count
        case .hertz(let width):
            length = LongDFT.fastLength(atLeast: n)
            transitionBins = max(2, Int((width / (sampleRate / 2) * Double(length / 2 + 1)).rounded()))
        }
        let bins = length / 2 + 1
        let cutoffBin = Int((cutoff / (sampleRate / 2)) * Double(bins))
        let half = transitionBins / 2
        let start = max(0, cutoffBin - half), end = min(bins, cutoffBin + half)
        var mask = [Double](repeating: 1, count: bins)
        for k in 0..<start { mask[k] = 0 }
        for k in start..<end {
            // torch.linspace(-1, 1, transitionBins) mapped to [0, 1], then 3t² − 2t³.
            let x = -1 + 2 * Float(k - start) / Float(transitionBins - 1)
            let t = (x + 1) / 2
            mask[k] = Double(3 * t * t - 2 * t * t * t)
        }

        // merged = original + highpass(predicted − original); the mask is symmetric, so apply it
        // to the full complex spectrum and the result stays real.
        var re = [Double](repeating: 0, count: length)
        for i in 0..<n { re[i] = Double(predicted[i]) - Double(original[i]) }
        var im = [Double](repeating: 0, count: length)
        let dft = LongDFT.shared(count: length)
        dft.transform(real: &re, imag: &im, inverse: false)
        for k in 0..<length {
            let m = mask[k <= length / 2 ? k : length - k]
            re[k] *= m
            im[k] *= m
        }
        dft.transform(real: &re, imag: &im, inverse: true)
        let scale = 1 / Double(length)
        return (0..<n).map { original[$0] + Float(re[$0] * scale) }
    }
}
