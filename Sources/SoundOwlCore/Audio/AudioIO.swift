import AVFoundation

/// Decoding to the model's input format and writing float WAV. The app's encoder lives elsewhere;
/// this is what the engine, the tests and the CLI need.
public enum AudioIO {
    public struct Decoded {
        public var channels: [[Float]]
        public var sampleRate: Double
        public var duration: Double { Double(channels.first?.count ?? 0) / sampleRate }
    }

    /// Reads any file Core Audio can decode, keeping its channels and rate.
    public static func read(_ url: URL) throws -> Decoded {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        var channels = [[Float]](repeating: [], count: Int(format.channelCount))
        for c in channels.indices { channels[c].reserveCapacity(Int(file.length)) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // A single read can return fewer frames than asked for, so read until the file is exhausted.
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            for c in channels.indices {
                channels[c].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![c],
                                                                   count: Int(buffer.frameLength)))
            }
        }
        return Decoded(channels: channels, sampleRate: format.sampleRate)
    }

    /// Converts one channel to another sample rate with Core Audio's best-quality converter.
    public static func resample(_ samples: [Float], from source: Double, to target: Double) throws -> [Float] {
        if source == target { return samples }
        let input = AVAudioFormat(standardFormatWithSampleRate: source, channels: 1)!
        let output = AVAudioFormat(standardFormatWithSampleRate: target, channels: 1)!
        guard let converter = AVAudioConverter(from: input, to: output) else { throw CocoaError(.featureUnsupported) }
        converter.sampleRateConverterQuality = .max
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        let inBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count))!
        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { inBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let expected = Int((Double(samples.count) * target / source).rounded())
        let outBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(expected + 4096))!
        var fed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, state in
            if fed {
                state.pointee = .endOfStream
                return nil
            }
            fed = true
            state.pointee = .haveData
            return inBuffer
        }
        if status == .error { throw error ?? CocoaError(.featureUnsupported) }
        var out = Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
        // The converter's length can be off by a few frames; the duration must not drift.
        if out.count < expected { out += [Float](repeating: 0, count: expected - out.count) }
        return Array(out.prefix(expected))
    }

    /// Writes 32-bit float WAV.
    public static func writeWAV(_ channels: [[Float]], sampleRate: Double, to url: URL) throws {
        // Beyond stereo, AVAudioFormat needs an explicit layout.
        let layout =
            AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels.count))!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false,
                                   channelLayout: layout)
        let count = channels.first?.count ?? 0
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(count, 1)))!
        buffer.frameLength = AVAudioFrameCount(count)
        for (c, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: count) }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels.count,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
