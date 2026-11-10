import Accelerate

/// Picks the band-merge cutoff for a recording from what is actually in it.
///
/// Upstream takes the cutoff as `input_sr / 2` from the caller: 8 kHz for normal audio, 4 kHz for
/// phone audio. Below the cutoff the original is kept as is, so a phone call merged at 8 kHz would
/// keep its empty 4–8 kHz band. Measuring the bandwidth gives each file the cutoff upstream would
/// have been told.
public enum Bandwidth {
    public static let range: ClosedRange<Double> = 3000...8000

    /// Highest frequency with real content in 16 kHz `samples`, clamped to `range`.
    public static func cutoff(for samples: [Float]) -> Double {
        let n = 512, rate = Double(LavaSR.inputSampleRate)
        let bins = n / 2 + 1
        let dft = FrameDFT(size: n)
        let window = Signal.hann(n)
        var power = [Double](repeating: 0, count: bins)
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: bins), im = re
        var used = 0

        var start = 0
        while start + n <= samples.count {
            samples.withUnsafeBufferPointer { s in
                vDSP_vmul(s.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            start += n
            // Silence says nothing about bandwidth.
            guard vDSP.rootMeanSquare(frame) > 0.003 else { continue }
            dft.rfft(frame, real: &re, imag: &im)
            for k in 0..<bins { power[k] += Double(re[k] * re[k] + im[k] * im[k]) }
            used += 1
        }
        guard used > 0 else { return range.upperBound }

        let hz = { (k: Int) in Double(k) * rate / Double(n) }
        let speech = (0..<bins).filter { (500...3000).contains(hz($0)) }
        let reference = speech.map { power[$0] }.reduce(0, +) / Double(speech.count)
        // The top of the band is where the smoothed spectrum falls 40 dB below the speech band: low
        // enough for quiet sibilants, high enough that a hiss floor does not count as content.
        var edge = 0
        for k in 1..<(bins - 1) {
            let level = (power[k - 1] + power[k] + power[k + 1]) / 3
            if 10 * log10(level / reference + 1e-30) > -40 { edge = k }
        }
        let cutoff = (hz(edge) / 250).rounded(.down) * 250
        return cutoff >= 7500 ? range.upperBound : min(max(cutoff, range.lowerBound), range.upperBound)
    }
}
