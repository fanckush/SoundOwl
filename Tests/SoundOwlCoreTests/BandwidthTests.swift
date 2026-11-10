import Foundation
import Testing
@testable import SoundOwlCore

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/lavasr-v2")

struct BandwidthTests {
    private func cutoff(_ name: String) throws -> Double {
        try Bandwidth.cutoff(for: AudioIO.read(fixtures.appending(path: "\(name).in.wav")).channels[0])
    }

    @Test func fullBandSpeechKeepsUpstreamDefault() throws {
        #expect(try cutoff("speech-16k") == 8000)
    }

    /// An 8 kHz recording, brought to 16 kHz the way the app does it.
    @Test func phoneAudioGetsANarrowCutoff() throws {
        let speech = try AudioIO.read(fixtures.appending(path: "speech-16k.in.wav")).channels[0]
        let phone = try AudioIO.resample(AudioIO.resample(speech, from: 16_000, to: 8000), from: 8000, to: 16_000)
        let hz = Bandwidth.cutoff(for: phone)
        #expect((3500...4000).contains(hz), "got \(hz)")
    }

    @Test func silenceFallsBackToDefault() throws {
        #expect(try cutoff("silence") == 8000)
    }
}
