import Accelerate
import Synchronization

/// Short real transforms for STFT frames. Power-of-two sizes only (512, 2048).
///
/// Uses vDSP's complex DFT on a zero-imaginary input, which costs twice a packed real FFT but keeps
/// the bin layout identical to `numpy.fft.rfft` with no unpacking.
final class FrameDFT {
    let size: Int
    var bins: Int { size / 2 + 1 }

    private let forward: OpaquePointer
    private let inverse: OpaquePointer
    private let zeros: [Float]
    private var re: [Float]
    private var im: [Float]
    private var scratch: [Float]

    init(size: Int) {
        precondition(size >= 16 && size & (size - 1) == 0, "frame size must be a power of two")
        self.size = size
        forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
        inverse = vDSP_DFT_zop_CreateSetup(forward, vDSP_Length(size), .INVERSE)!
        zeros = [Float](repeating: 0, count: size)
        re = zeros
        im = zeros
        scratch = zeros
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    /// `rfft(frame)`: writes `bins` real and imaginary parts.
    func rfft(_ frame: UnsafePointer<Float>, real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>) {
        re.withUnsafeMutableBufferPointer { re in
            im.withUnsafeMutableBufferPointer { im in
                vDSP_DFT_Execute(forward, frame, zeros, re.baseAddress!, im.baseAddress!)
                real.update(from: re.baseAddress!, count: bins)
                imag.update(from: im.baseAddress!, count: bins)
            }
        }
    }

    /// `irfft(spectrum, size)`: the imaginary parts of the DC and Nyquist bins are ignored, as numpy does.
    func irfft(real: UnsafePointer<Float>, imag: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>) {
        re.withUnsafeMutableBufferPointer { re in
            im.withUnsafeMutableBufferPointer { im in
                let half = size / 2
                re[0] = real[0]
                im[0] = 0
                re[half] = real[half]
                im[half] = 0
                for k in 1..<half {
                    re[k] = real[k]
                    im[k] = imag[k]
                    re[size - k] = real[k]
                    im[size - k] = -imag[k]
                }
                // The imaginary output is ~0 for a Hermitian spectrum and is discarded.
                scratch.withUnsafeMutableBufferPointer { scratch in
                    vDSP_DFT_Execute(inverse, re.baseAddress!, im.baseAddress!, output, scratch.baseAddress!)
                }
                var scale = 1 / Float(size)
                vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(size))
            }
        }
    }
}

/// Complex DFT of any length in double precision, for the whole-chunk band merge.
///
/// vDSP handles lengths of the form f·2^k (f ∈ 1, 3, 5, 15) directly. Every other length goes
/// through Bluestein's algorithm on a power-of-two transform.
final class LongDFT: @unchecked Sendable { // immutable after init; vDSP setups are safe to share
    let count: Int

    private static let cache = Mutex([Int: LongDFT]())

    /// A transform for `count`, reused across calls. vDSP keeps memory for large setups even after
    /// they are destroyed, so making a fresh one per chunk grows the process by ~20 MB each time.
    /// Chunked restores reuse a handful of lengths, so the cache stays small.
    static func shared(count: Int) -> LongDFT {
        cache.withLock { cache in
            if let dft = cache[count] { return dft }
            if cache.count >= 8 { cache.removeAll() }
            let dft = LongDFT(count: count)
            cache[count] = dft
            return dft
        }
    }
    private let direct: (forward: OpaquePointer, inverse: OpaquePointer)?
    private let bluestein: Bluestein?

    init(count: Int) {
        self.count = count
        if let forward = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(count), .FORWARD),
           let inverse = vDSP_DFT_zop_CreateSetupD(forward, vDSP_Length(count), .INVERSE) {
            direct = (forward, inverse)
            bluestein = nil
        } else {
            direct = nil
            bluestein = Bluestein(count: count)
        }
    }

    /// The smallest length ≥ `count` that vDSP transforms without Bluestein: f·2^k, f ∈ 1, 3, 5, 15.
    static func fastLength(atLeast count: Int) -> Int {
        var best = Int.max
        for f in [1, 3, 5, 15] {
            var length = f * 16
            while length < count { length <<= 1 }
            best = min(best, length)
        }
        return best
    }

    deinit {
        if let direct {
            vDSP_DFT_DestroySetupD(direct.forward)
            vDSP_DFT_DestroySetupD(direct.inverse)
        }
    }

    /// Unnormalized forward (`inverse == false`) or inverse transform, in place.
    func transform(real: inout [Double], imag: inout [Double], inverse: Bool) {
        precondition(real.count == count && imag.count == count)
        if let direct {
            let inReal = real, inImag = imag
            vDSP_DFT_ExecuteD(inverse ? direct.inverse : direct.forward, inReal, inImag, &real, &imag)
        } else if inverse {
            // IDFT(x) = conj(DFT(conj(x)))
            vDSP.negative(imag, result: &imag)
            bluestein!.forward(real: &real, imag: &imag)
            vDSP.negative(imag, result: &imag)
        } else {
            bluestein!.forward(real: &real, imag: &imag)
        }
    }
}

private final class Bluestein {
    let count: Int
    let padded: Int
    private let chirpRe: [Double]
    private let chirpIm: [Double]
    private let kernelRe: [Double]
    private let kernelIm: [Double]
    private let forwardSetup: OpaquePointer
    private let inverseSetup: OpaquePointer

    init(count n: Int) {
        count = n
        var m = 1
        while m < 2 * n - 1 { m <<= 1 }
        padded = m
        forwardSetup = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(m), .FORWARD)!
        inverseSetup = vDSP_DFT_zop_CreateSetupD(forwardSetup, vDSP_Length(m), .INVERSE)!

        // chirp[k] = exp(-iπk²/n). k² is reduced mod 2n first so the angle stays exact for long inputs.
        var cr = [Double](repeating: 0, count: n)
        var ci = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let angle = Double.pi * Double((k * k) % (2 * n)) / Double(n)
            cr[k] = cos(angle)
            ci[k] = -sin(angle)
        }
        chirpRe = cr
        chirpIm = ci

        // The convolution kernel is conj(chirp), laid out circularly, and kept in the frequency domain.
        var br = [Double](repeating: 0, count: m)
        var bi = [Double](repeating: 0, count: m)
        br[0] = cr[0]
        bi[0] = -ci[0]
        for k in 1..<n {
            br[k] = cr[k]
            bi[k] = -ci[k]
            br[m - k] = cr[k]
            bi[m - k] = -ci[k]
        }
        var kr = [Double](repeating: 0, count: m)
        var ki = [Double](repeating: 0, count: m)
        vDSP_DFT_ExecuteD(forwardSetup, br, bi, &kr, &ki)
        kernelRe = kr
        kernelIm = ki
    }

    deinit {
        vDSP_DFT_DestroySetupD(forwardSetup)
        vDSP_DFT_DestroySetupD(inverseSetup)
    }

    func forward(real: inout [Double], imag: inout [Double]) {
        let n = count, m = padded
        var ar = [Double](repeating: 0, count: m)
        var ai = [Double](repeating: 0, count: m)
        for k in 0..<n {
            ar[k] = real[k] * chirpRe[k] - imag[k] * chirpIm[k]
            ai[k] = real[k] * chirpIm[k] + imag[k] * chirpRe[k]
        }
        var fr = [Double](repeating: 0, count: m)
        var fi = [Double](repeating: 0, count: m)
        vDSP_DFT_ExecuteD(forwardSetup, ar, ai, &fr, &fi)
        for k in 0..<m {
            let r = fr[k] * kernelRe[k] - fi[k] * kernelIm[k]
            let i = fr[k] * kernelIm[k] + fi[k] * kernelRe[k]
            fr[k] = r
            fi[k] = i
        }
        vDSP_DFT_ExecuteD(inverseSetup, fr, fi, &ar, &ai)
        let scale = 1 / Double(m)
        for k in 0..<n {
            let r = ar[k] * scale, i = ai[k] * scale
            real[k] = r * chirpRe[k] - i * chirpIm[k]
            imag[k] = r * chirpIm[k] + i * chirpRe[k]
        }
    }
}
