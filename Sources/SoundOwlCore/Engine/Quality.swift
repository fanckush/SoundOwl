import Accelerate
import Foundation

/// Measures for comparing two restorations of the same audio, and for telling whether a source
/// already has real high-band content. Used by the live feasibility test (`soundowl-dev lookahead`).
public enum Quality {
    public struct HighBand: Sendable, CustomStringConvertible {
        /// Reference high-band energy over error energy, in dB. Higher is closer.
        public var snr: Double
        /// Mean log-spectral distance above the cutoff, in dB, over non-silent frames. Lower is closer.
        public var lsd: Double

        public var description: String { String(format: "high-band SNR %.1f dB, LSD %.2f dB", snr, lsd) }
    }

    /// Compares `got` with `ref` (both 48 kHz, same length) above `cutoff` Hz.
    public static func highBand(got: [Float], ref: [Float], above cutoff: Double,
                                sampleRate: Double = 48_000) -> HighBand {
        precondition(got.count == ref.count, "signals must have the same length")
        let n = 2048, hop = 512, bins = n / 2 + 1
        let first = min(bins - 1, Int((cutoff / (sampleRate / 2) * Double(bins - 1)).rounded(.up)))
        let window = Signal.hann(n)
        let dft = FrameDFT(size: n)
        var frame = [Float](repeating: 0, count: n)
        var gr = [Float](repeating: 0, count: bins), gi = gr, rr = gr, ri = gr
        var signal = 0.0, error = 0.0, lsdSum = 0.0, lsdFrames = 0

        var start = 0
        while start + n <= ref.count {
            ref.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n)) }
            let silent = vDSP.rootMeanSquare(frame) < 0.003
            dft.rfft(frame, real: &rr, imag: &ri)
            got.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n)) }
            dft.rfft(frame, real: &gr, imag: &gi)
            start += hop

            var distance = 0.0
            for k in first..<bins {
                let pr = Double(rr[k] * rr[k] + ri[k] * ri[k])
                let pg = Double(gr[k] * gr[k] + gi[k] * gi[k])
                let dr = Double(gr[k] - rr[k]), di = Double(gi[k] - ri[k])
                signal += pr
                error += dr * dr + di * di
                let d = 10 * log10((pg + 1e-10) / (pr + 1e-10))
                distance += d * d
            }
            if !silent {
                lsdSum += (distance / Double(bins - first)).squareRoot()
                lsdFrames += 1
            }
        }
        return HighBand(snr: 10 * log10((signal + 1e-30) / (error + 1e-30)),
                        lsd: lsdFrames > 0 ? lsdSum / Double(lsdFrames) : 0)
    }

    /// How much of the high-band error sits at hop boundaries, in dB: error energy within
    /// ±`width` samples of each boundary over the energy everywhere else. Around 0 dB the seams
    /// are no worse than the rest; a hop-rate buzz shows up as several dB.
    public static func seamRatio(got: [Float], ref: [Float], hop: Int, above cutoff: Double,
                                 width: Int = 240, sampleRate: Double = 48_000) -> Double {
        precondition(got.count == ref.count && hop > 2 * width, "signals must match and hops be wider than seams")
        let difference = zip(got, ref).map { $0 - $1 }
        // bandMerge keeps `original` below the cutoff and `predicted` above: with silence as the
        // original, that is a high-pass of the error.
        let error = Signal.bandMerge(predicted: difference, original: [Float](repeating: 0, count: difference.count),
                                     cutoff: cutoff, transition: .hertz(170), sampleRate: sampleRate)
        var seam = 0.0, seamCount = 0, rest = 0.0, restCount = 0
        for (i, e) in error.enumerated() {
            let offset = i % hop
            let distance = min(offset, hop - offset)
            if i >= hop - width, distance <= width {
                seam += Double(e * e)
                seamCount += 1
            } else {
                rest += Double(e * e)
                restCount += 1
            }
        }
        guard seamCount > 0, restCount > 0 else { return 0 }
        return 10 * log10((seam / Double(seamCount) + 1e-30) / (rest / Double(restCount) + 1e-30))
    }

    /// What's above 8 kHz, and whether it's voice.
    public struct HighBandContent: Sendable, CustomStringConvertible {
        /// 8.5–11 kHz against the 0.5–3 kHz speech band while someone speaks, in dB.
        public var level: Double
        /// How much louder 8.5–11 kHz is while someone speaks than in the pauses, in dB. Speech's own
        /// highs (sibilants included) come and go with the voice; hiss and room noise stay put.
        public var contrast: Double

        public var description: String { String(format: "high band %.1f dB, contrast %.1f dB", level, contrast) }
    }

    /// Measures 8.5–11 kHz at the source's own rate, frame by frame. Nil when the rate cannot carry
    /// that band, or there's too little sound to tell.
    public static func highBandContent(_ samples: [Float], sampleRate: Double) -> HighBandContent? {
        guard sampleRate >= 24_000 else { return nil }
        let n = 2048, bins = n / 2 + 1
        let window = Signal.hann(n)
        let dft = FrameDFT(size: n)
        let all = (0..<bins).filter { (300.0...11_000).contains(Double($0) * sampleRate / Double(n)) }
        let speech = (0..<bins).filter { (500.0...3000).contains(Double($0) * sampleRate / Double(n)) }
        let high = (0..<bins).filter { (8500.0...11_000).contains(Double($0) * sampleRate / Double(n)) }
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: bins), im = re
        struct Frame { var total, speech, high: Double }
        var frames: [Frame] = []
        var start = 0
        while start + n <= samples.count {
            samples.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(n)) }
            start += n / 2
            // Digital silence says nothing; quiet stretches between words are the point.
            guard vDSP.rootMeanSquare(frame) > 1e-6 else { continue }
            dft.rfft(frame, real: &re, imag: &im)
            func power(_ ks: [Int]) -> Double {
                ks.reduce(0) { $0 + Double(re[$1] * re[$1] + im[$1] * im[$1]) } / Double(ks.count)
            }
            frames.append(Frame(total: power(all), speech: power(speech), high: power(high)))
        }
        guard frames.count >= 12 else { return nil }
        // By overall loudness: the loudest 40% is speech (vowels and sibilants alike), the quietest
        // 20% the pauses between words.
        let sorted = frames.sorted { $0.total < $1.total }
        let quiet = sorted[..<(sorted.count / 5)], loud = sorted[(sorted.count * 3 / 5)...]
        func mean(_ xs: some Collection<Double>) -> Double { xs.reduce(0, +) / Double(max(1, xs.count)) }
        let loudHigh = mean(loud.map(\.high)), loudSpeech = mean(loud.map(\.speech)), quietHigh = mean(quiet.map(\.high))
        return HighBandContent(level: 10 * log10((loudHigh + 1e-30) / (loudSpeech + 1e-30)),
                               contrast: 10 * log10((loudHigh + 1e-30) / (quietHigh + 1e-30)))
    }

    /// Level of 8.5–11 kHz against the speech band, in dB (-infinity when there's no telling).
    public static func highBandLevel(_ samples: [Float], sampleRate: Double) -> Double {
        highBandContent(samples, sampleRate: sampleRate)?.level ?? -.infinity
    }

    /// Whether a source already carries the voice's own highs above 8 kHz, so restoring would
    /// replace a real high band with a generated one. Hiss or room noise up there doesn't count:
    /// an old recording on a full-band stream (a 1984 keynote on YouTube) still needs restoring.
    /// When in doubt, restore: a needless restore sounds nearly the same, a missed one sounds dull.
    /// Real full-band voices measure about -40 dB with 13–27 dB of contrast; dull or hissy sources
    /// -54 to -63 dB, or under 10 dB of contrast (`soundowl-dev fullband`). Music fails the
    /// contrast test too (it keeps its highs on all the time), so Live recognizes music separately.
    public static func hasFullBandContent(_ samples: [Float], sampleRate: Double,
                                          threshold: Double = -50, minimumContrast: Double = 10) -> Bool {
        guard let content = highBandContent(samples, sampleRate: sampleRate) else { return false }
        return content.level > threshold && content.contrast >= minimumContrast
    }
}
