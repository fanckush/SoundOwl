import AVFoundation
import SoundAnalysis
import Synchronization

/// What an app is playing, as far as restoring goes: a voice to restore, or music to leave alone.
///
/// The voice model rebuilds speech; on music it smears instruments and singing. Apple's built-in
/// sound classifier (on device, about 2 ms per second of sound) tells the two apart reliably: on
/// the test corpus every window of speech scored speech ≥ 0.86 and music < 0.2, and songs scored
/// music or singing ≥ 0.35 in 55 of 60 windows (the rest unsure, none speech).
public enum SoundKind: Sendable, Equatable {
    /// Not decided yet: too little sound so far.
    case unknown
    case voice
    case music
}

/// Classifies a live stream in 1.5 s windows and decides with a little hysteresis, so one odd
/// window (a jingle, a laugh) doesn't flip restoring on and off.
final class SoundKindDetector: @unchecked Sendable {
    private let analyzer: SNAudioStreamAnalyzer
    private let format: AVAudioFormat
    private let observer = Observer()
    private var position: AVAudioFramePosition = 0

    var kind: SoundKind { observer.kind }

    init?(sampleRate: Double) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return nil }
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 48_000)
        request.overlapFactor = 0
        self.format = format
        analyzer = SNAudioStreamAnalyzer(format: format)
        guard (try? analyzer.add(request, withObserver: observer)) != nil else { return nil }
    }

    /// Mono samples at the stream's rate. Called from the engine thread, never the audio thread.
    func add(_ block: [Float]) {
        guard !block.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(block.count)
        block.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: block.count) }
        analyzer.analyze(buffer, atAudioFramePosition: position)
        position += AVAudioFramePosition(block.count)
    }

    func stop() {
        analyzer.completeAnalysis()
        analyzer.removeAllRequests()
    }

    /// One window's verdict.
    enum Verdict: Equatable {
        case voice
        case music
        /// Silence, noise, or not sure.
        case other
    }

    /// Music or singing at 0.35 outweighs speech: sung words also score as speech.
    static func verdict(speech: Double, music: Double, singing: Double) -> Verdict {
        if max(music, singing) >= 0.35 { return .music }
        if speech >= 0.6 { return .voice }
        return .other
    }

    /// Two of the last three windows decide; unsure windows keep what was decided.
    static func decide(_ recent: [Verdict], current: SoundKind) -> SoundKind {
        let last = recent.suffix(3)
        if last.count(where: { $0 == .music }) >= 2 { return .music }
        if last.count(where: { $0 == .voice }) >= 2 { return .voice }
        return current
    }

    private final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        private let state = Mutex<(recent: [Verdict], kind: SoundKind)>(([], .unknown))

        var kind: SoundKind { state.withLock { $0.kind } }

        func request(_: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            func confidence(_ label: String) -> Double { result.classification(forIdentifier: label)?.confidence ?? 0 }
            let verdict = SoundKindDetector.verdict(speech: confidence("speech"), music: confidence("music"),
                                                    singing: confidence("singing"))
            state.withLock { s in
                s.recent.append(verdict)
                if s.recent.count > 3 { s.recent.removeFirst() }
                s.kind = SoundKindDetector.decide(s.recent, current: s.kind)
            }
        }
    }
}
