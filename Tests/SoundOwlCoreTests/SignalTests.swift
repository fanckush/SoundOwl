import Foundation
import Testing
@testable import SoundOwlCore

struct SignalTests {
    @Test(arguments: [8, 1000, 2048, 3001, 4096 * 3])
    func longDFTRoundTrips(count: Int) {
        let signal = (0..<count).map { sin(Double($0) * 0.37) + Double($0 % 7) * 0.1 }
        var re = signal, im = [Double](repeating: 0, count: count)
        let dft = LongDFT(count: count)
        dft.transform(real: &re, imag: &im, inverse: false)
        // DC bin is the plain sum.
        #expect(abs(re[0] - signal.reduce(0, +)) < 1e-6 * Double(count))
        dft.transform(real: &re, imag: &im, inverse: true)
        let maxError = zip(signal, re).map { abs($0 - $1 / Double(count)) }.max()!
        #expect(maxError < 1e-9)
    }

    @Test func frameDFTMatchesLongDFT() {
        let n = 512
        let frame = (0..<n).map { Float(sin(Double($0) * 0.11)) }
        let dft = FrameDFT(size: n)
        var re = [Float](repeating: 0, count: n / 2 + 1), im = re
        dft.rfft(frame, real: &re, imag: &im)
        var lr = frame.map(Double.init), li = [Double](repeating: 0, count: n)
        LongDFT(count: n).transform(real: &lr, imag: &li, inverse: false)
        for k in 0...(n / 2) {
            #expect(abs(Double(re[k]) - lr[k]) < 1e-3 && abs(Double(im[k]) - li[k]) < 1e-3)
        }
        var back = [Float](repeating: 0, count: n)
        dft.irfft(real: re, imag: im, into: &back)
        #expect(zip(frame, back).map { abs($0 - $1) }.max()! < 1e-5)
    }

    @Test func resampleTriplesLengthAndKeepsLowFrequencies() {
        let x = (0..<1600).map { Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        let y = Signal.resample(x, from: 16_000, to: 48_000)
        #expect(y.count == 4800)
        // Away from the zero-padded edges, the 48 kHz signal is the same sine.
        for i in 300..<4500 {
            #expect(abs(y[i] - Float(sin(2 * Double.pi * 440 * Double(i) / 48_000))) < 2e-3)
        }
    }

    @Test func reflectPadMatchesNumpy() {
        #expect(Signal.reflectPad([1, 2, 3, 4], left: 2, right: 2) == [3, 2, 1, 2, 3, 4, 3, 2])
    }
}
