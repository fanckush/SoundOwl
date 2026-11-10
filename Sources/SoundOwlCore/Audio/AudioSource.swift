import AVFoundation

/// A recording on disk, as SoundOwl sees it before restoring.
public struct AudioSource: Sendable {
    public let url: URL
    public let sampleRate: Double
    public let channelCount: Int
    public let frameCount: Int

    public var duration: Double { Double(frameCount) / sampleRate }

    /// Samples at the model's 16 kHz rate for the whole recording.
    public var modelFrameCount: Int {
        Int((Double(frameCount) * Double(LavaSR.inputSampleRate) / sampleRate).rounded())
    }

    public enum OpenError: LocalizedError {
        case protected
        case unreadable
        case empty

        public var errorDescription: String? {
            switch self {
            case .protected: String(localized: "This file is copy-protected, so it can't be opened.")
            case .unreadable: String(localized: "SoundOwl can't read this file.")
            case .empty: String(localized: "This file has no audio.")
            }
        }
    }

    /// Opens `url` and reads its format, explaining why when it can't.
    public init(url: URL) async throws(OpenError) {
        self.url = url
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            let asset = AVURLAsset(url: url)
            if await (try? asset.load(.hasProtectedContent)) == true { throw .protected }
            throw .unreadable
        }
        guard file.length > 0 else { throw .empty }
        sampleRate = file.fileFormat.sampleRate
        // Speech restoration is per channel; more than two channels is not a voice recording.
        channelCount = min(Int(file.fileFormat.channelCount), 2)
        frameCount = Int(file.length)
    }

    /// Decodes the recording to 16 kHz into `store`, one channel per file, in bounded memory.
    /// Returns the loudness (RMS over all channels) of `peakCount` buckets, for drawing the
    /// waveform. Loudness rather than peaks: on a long file every bucket holds a loud peak
    /// somewhere, and peaks would draw a flat bar.
    public func decode(into store: PCMStore, peakCount: Int = 2000,
                       progress: (Double) -> Void = { _ in }) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let inputFormat = file.processingFormat
        let block: AVAudioFrameCount = 1 << 16
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: block) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let resamplers = (0..<channelCount).map { _ in StreamingResampler(from: sampleRate, to: Double(LavaSR.inputSampleRate)) }
        var written = 0
        var energy = [Double](repeating: 0, count: peakCount)
        var samplesIn = [Int](repeating: 0, count: peakCount)
        let total = store.count

        func emit(_ channels: [[Float]]) throws {
            let n = min(channels[0].count, total - written)
            guard n > 0 else { return }
            for (c, samples) in channels.enumerated() {
                try store.write(Array(samples.prefix(n)), channel: c, at: written)
            }
            for i in 0..<n {
                let bucket = min(peakCount - 1, (written + i) * peakCount / max(total, 1))
                for samples in channels { energy[bucket] += Double(samples[i] * samples[i]) }
                samplesIn[bucket] += channels.count
            }
            written += n
        }

        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: input, frameCount: block)
            if input.frameLength == 0 { break }
            let channels = try (0..<channelCount).map { c in
                try resamplers[c].process(Array(UnsafeBufferPointer(
                    start: input.floatChannelData![c],
                    count: Int(input.frameLength)
                )))
            }
            try emit(channels)
            progress(Double(file.framePosition) / Double(file.length))
        }
        try emit(resamplers.map { try $0.finish() })
        // The converter can come up a few samples short; the rest of the store is already silence.
        return zip(energy, samplesIn).map { $1 > 0 ? Float(($0 / Double($1)).squareRoot()) : 0 }
    }
}

/// AVAudioConverter fed one block at a time, for files too long to convert in one go and for
/// live streams. Not thread-safe.
public final class StreamingResampler {
    private let converter: AVAudioConverter?
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private var pending: AVAudioPCMBuffer?
    private var ended = false

    public init(from source: Double, to target: Double) {
        input = AVAudioFormat(standardFormatWithSampleRate: source, channels: 1)!
        output = AVAudioFormat(standardFormatWithSampleRate: target, channels: 1)!
        if source == target {
            converter = nil
        } else {
            let converter = AVAudioConverter(from: input, to: output)!
            converter.sampleRateConverterQuality = .max
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            self.converter = converter
        }
    }

    public func process(_ samples: [Float]) throws -> [Float] {
        guard let converter else { return samples }
        let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        pending = buffer
        return try drain(converter, capacity: Int(Double(samples.count) * output.sampleRate / input.sampleRate) + 1024)
    }

    public func finish() throws -> [Float] {
        guard let converter else { return [] }
        ended = true
        return try drain(converter, capacity: 8192)
    }

    private func drain(_ converter: AVAudioConverter, capacity: Int) throws -> [Float] {
        var out = [Float]()
        while true {
            let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(capacity))!
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { [self] _, state in
                if let pending {
                    self.pending = nil
                    state.pointee = .haveData
                    return pending
                }
                state.pointee = ended ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error { throw error ?? CocoaError(.featureUnsupported) }
            out += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            if status != .haveData || buffer.frameLength == 0 { return out }
        }
    }
}
