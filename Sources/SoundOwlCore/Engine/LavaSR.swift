import Accelerate
import Foundation

/// LavaSR v2 with the networks in ONNX Runtime and everything around them native.
///
/// `enhance` is upstream `LavaEnhance.enhance` (non-batch) step for step, so its output can be
/// checked against the golden fixtures. Not thread-safe: use one instance per thread.
public final class LavaSR {
    public static let inputSampleRate = 16_000
    public static let outputSampleRate = 48_000

    private let bweGraph: OnnxGraph
    private let denoiserGraph: OnnxGraph
    private let bweFFT: Int
    private let bweHop: Int
    private let denoiserFFT: Int
    private let denoiserHop: Int
    public let defaultCutoff: Double
    private let transitionBins: Int

    /// `intraOpThreads` caps the CPU threads a single restore may use. Files leave it nil (as
    /// fast as possible); live restoring caps it so the call app keeps its share of the CPU.
    public init(package: ModelPackage, intraOpThreads: Int? = nil) throws {
        let pipeline = package.manifest.pipeline
        guard pipeline.modelSampleRate == Self.inputSampleRate, pipeline.outputSampleRate == Self.outputSampleRate else {
            throw EngineError.invalidModel("unexpected sample rates")
        }
        bweGraph = try OnnxGraph(url: package.directory.appending(path: pipeline.bwe.file), intraOpThreads: intraOpThreads)
        denoiserGraph = try OnnxGraph(url: package.directory.appending(path: pipeline.denoiser.file),
                                      intraOpThreads: intraOpThreads)
        bweFFT = pipeline.bwe.nFFT
        bweHop = pipeline.bwe.hop
        denoiserFFT = pipeline.denoiser.nFFT
        denoiserHop = pipeline.denoiser.hop
        defaultCutoff = pipeline.merge.cutoffHz
        transitionBins = pipeline.merge.transitionBins
    }

    /// 16 kHz mono in, 48 kHz out. Like upstream, the output can be up to one hop shorter than
    /// three times the input; `Restorer` pads around that.
    ///
    /// `transitionHz` fixes the width of the band-merge crossover. Left nil, it follows upstream,
    /// whose width depends on the input length.
    public func enhance(_ x16: [Float], cutoff: Double? = nil, transitionHz: Double? = nil,
                        denoise: Bool = false) throws -> [Float] {
        let input = denoise ? try self.denoise(x16) : x16
        let x48 = Signal.resample(input, from: Self.inputSampleRate, to: Self.outputSampleRate)
        let predicted = try bandwidthExtend(x48)
        let n = min(predicted.count, x48.count)
        return Signal.bandMerge(predicted: Array(predicted.prefix(n)), original: Array(x48.prefix(n)),
                                cutoff: cutoff ?? defaultCutoff,
                                transition: transitionHz.map { .hertz($0) } ?? .bins(transitionBins))
    }

    /// The shortest input `enhance` accepts.
    public static let minimumInputCount = 1024

    // MARK: - Bandwidth extension (Vocos with "same" padding)

    func bandwidthExtend(_ x48: [Float]) throws -> [Float] {
        let n = bweFFT, hop = bweHop, bins = n / 2 + 1
        let pad = (n - hop) / 2
        let padded = Signal.reflectPad(x48, left: pad, right: pad)
        let frames = 1 + (padded.count - n) / hop
        let window = Signal.hann(n)
        let dft = FrameDFT(size: n)

        // Magnitude laid out (1, bins, frames) for the graph.
        var magnitude = [Float](repeating: 0, count: bins * frames)
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: bins)
        var im = [Float](repeating: 0, count: bins)
        for t in 0..<frames {
            padded.withUnsafeBufferPointer { p in
                vDSP_vmul(p.baseAddress! + t * hop, 1, window, 1, &frame, 1, vDSP_Length(n))
            }
            dft.rfft(frame, real: &re, imag: &im)
            for f in 0..<bins {
                magnitude[f * frames + t] = (re[f] * re[f] + im[f] * im[f]).squareRoot()
            }
        }

        let out = try bweGraph.run(["magnitude": .init(values: magnitude, shape: [1, bins, frames])],
                                   outputs: ["real", "imag"])
        let real = out["real"]!, imag = out["imag"]!

        var y = [Float](repeating: 0, count: (frames - 1) * hop + n)
        var envelope = [Float](repeating: 0, count: y.count)
        let windowSquared = vDSP.square(window)
        for t in 0..<frames {
            for f in 0..<bins {
                re[f] = real[f * frames + t]
                im[f] = imag[f * frames + t]
            }
            dft.irfft(real: re, imag: im, into: &frame)
            overlapAdd(frame, window: window, windowSquared: windowSquared, at: t * hop, into: &y, envelope: &envelope)
        }
        return normalized(y, envelope: envelope, from: pad, count: y.count - 2 * pad)
    }

    // MARK: - Denoiser (UL-UNAS with torch.stft center=True)

    func denoise(_ x16: [Float]) throws -> [Float] {
        let n = denoiserFFT, hop = denoiserHop, bins = n / 2 + 1
        let padded = Signal.reflectPad(x16, left: n / 2, right: n / 2)
        let frames = 1 + (padded.count - n) / hop
        let window = Signal.hann(n)
        let dft = FrameDFT(size: n)

        // (1, 2, frames, bins): real plane, then imaginary plane.
        var spec = [Float](repeating: 0, count: 2 * frames * bins)
        var frame = [Float](repeating: 0, count: n)
        spec.withUnsafeMutableBufferPointer { spec in
            for t in 0..<frames {
                padded.withUnsafeBufferPointer { p in
                    vDSP_vmul(p.baseAddress! + t * hop, 1, window, 1, &frame, 1, vDSP_Length(n))
                }
                dft.rfft(frame, real: spec.baseAddress! + t * bins, imag: spec.baseAddress! + (frames + t) * bins)
            }
        }

        let enhanced = try denoiserGraph.run(["spec": .init(values: spec, shape: [1, 2, frames, bins])],
                                             outputs: ["enhanced"])["enhanced"]!

        var y = [Float](repeating: 0, count: (frames - 1) * hop + n)
        var envelope = [Float](repeating: 0, count: y.count)
        let windowSquared = vDSP.square(window)
        enhanced.withUnsafeBufferPointer { e in
            for t in 0..<frames {
                dft.irfft(real: e.baseAddress! + t * bins, imag: e.baseAddress! + (frames + t) * bins, into: &frame)
                overlapAdd(frame, window: window, windowSquared: windowSquared, at: t * hop, into: &y, envelope: &envelope)
            }
        }
        var out = normalized(y, envelope: envelope, from: n / 2, count: hop * (frames - 1))
        out += [Float](repeating: 0, count: max(0, x16.count - out.count))
        return Array(out.prefix(x16.count))
    }

    // MARK: - Overlap-add

    private func overlapAdd(_ frame: [Float], window: [Float], windowSquared: [Float], at offset: Int,
                            into y: inout [Float], envelope: inout [Float]) {
        let n = frame.count
        y.withUnsafeMutableBufferPointer { y in
            envelope.withUnsafeMutableBufferPointer { env in
                let yp = y.baseAddress! + offset, ep = env.baseAddress! + offset
                vDSP_vma(frame, 1, window, 1, yp, 1, yp, 1, vDSP_Length(n))
                vDSP_vadd(windowSquared, 1, ep, 1, ep, 1, vDSP_Length(n))
            }
        }
    }

    private func normalized(_ y: [Float], envelope: [Float], from start: Int, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        y.withUnsafeBufferPointer { y in
            envelope.withUnsafeBufferPointer { e in
                vDSP_vdiv(e.baseAddress! + start, 1, y.baseAddress! + start, 1, &out, 1, vDSP_Length(count))
            }
        }
        return out
    }
}
