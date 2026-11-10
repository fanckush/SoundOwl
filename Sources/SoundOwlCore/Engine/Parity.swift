import Foundation

/// Compares the native engine with upstream LavaSR on the golden fixtures from
/// `tools/model-export/make_fixtures.py`. Shared by the tests and the CLI.
public enum Parity {
    public struct Result: CustomStringConvertible, Sendable {
        public let name: String
        public let length: Int
        public let expectedLength: Int
        public let maxError: Float
        public let snr: Double

        /// Matching length, and either 60 dB SNR or a tiny absolute error (for near-silent clips).
        public var passed: Bool { length == expectedLength && (snr > 60 || maxError < 1e-4) }

        public var description: String {
            String(format: "%@ %@: length %d/%d, max error %.2e, SNR %.1f dB",
                   passed ? "ok  " : "FAIL", name, length, expectedLength, maxError, snr)
        }
    }

    private struct Fixture: Decodable {
        let cutoffHz: Double
        let denoise: Bool
    }

    public static func run(model: LavaSR, fixtures: URL) throws -> [Result] {
        let index = try JSONDecoder().decode([String: Fixture].self,
                                             from: Data(contentsOf: fixtures.appending(path: "fixtures.json")))
        return try index.keys.sorted().map { name in
            let fixture = index[name]!
            let input = try AudioIO.read(fixtures.appending(path: "\(name).in.wav")).channels[0]
            let expected = try AudioIO.read(fixtures.appending(path: "\(name).out.wav")).channels[0]
            let got = try model.enhance(input, cutoff: fixture.cutoffHz, denoise: fixture.denoise)
            return compare(name: name, got: got, expected: expected)
        }
    }

    public static func compare(name: String, got: [Float], expected: [Float]) -> Result {
        let n = min(got.count, expected.count)
        var maxError: Float = 0
        var signal = 0.0, noise = 0.0
        for i in 0..<n {
            let e = got[i] - expected[i]
            maxError = max(maxError, abs(e))
            signal += Double(expected[i] * expected[i])
            noise += Double(e * e)
        }
        let snr = noise == 0 ? .infinity : 10 * log10(signal / noise + 1e-30)
        return Result(name: name, length: got.count, expectedLength: expected.count, maxError: maxError, snr: snr)
    }
}
