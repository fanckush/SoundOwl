import AVFoundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable, Codable {
    case aac
    case alac
    case wav

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .aac: String(localized: "AAC (smaller files)")
        case .alac: String(localized: "Apple Lossless")
        case .wav: String(localized: "WAV")
        }
    }

    public var fileExtension: String {
        switch self {
        case .aac, .alac: "m4a"
        case .wav: "wav"
        }
    }
}

/// Writes restored audio to its final file next to nothing it could clobber.
///
/// The file is written under a hidden temporary name in the destination folder and renamed only
/// when complete, so a cancelled or failed export leaves nothing behind. Originals are never
/// touched, and an existing file of the same name gets a numbered sibling instead.
public enum Exporter {
    public static let sampleRate = Double(LavaSR.outputSampleRate)

    public static func export(_ store: PCMStore, source: URL, to folder: URL, format: ExportFormat,
                              progress: @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let temporary = folder.appending(path: ".soundowl-\(UUID().uuidString).\(format.fileExtension)")
        do {
            switch format {
            case .aac, .alac:
                let metadata = await Metadata.items(from: source)
                try await writeMPEG4(store, format: format, metadata: metadata, to: temporary, progress: progress)
            case .wav:
                try writeWAV(store, to: temporary, progress: progress)
            }
            let destination = uniqueURL(in: folder, for: source, extension: format.fileExtension)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// `Name (Restored).m4a`, or `Name (Restored 2).m4a` and so on when that is taken.
    public static func uniqueURL(in folder: URL, for source: URL, extension ext: String) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = folder.appending(path: "\(base) (\(String(localized: "Restored"))).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(base) (\(String(localized: "Restored")) \(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Blocks of restored audio, soft-limited so nothing clips. The model can overshoot full scale
    /// slightly on loud sibilants; a hard clip there is audible, a soft knee is not.
    static func blocks(of store: PCMStore, frames: Int = 1 << 16) -> AnySequence<(offset: Int, channels: [[Float]])> {
        AnySequence(stride(from: 0, to: store.count, by: frames).lazy.map { offset in
            let range = offset..<min(offset + frames, store.count)
            let channels = (0..<store.channelCount).map { c in
                ((try? store.read(channel: c, range: range)) ?? []).map(softLimit)
            }
            return (offset, channels)
        })
    }

    static func softLimit(_ x: Float) -> Float {
        let knee: Float = 0.95, ceiling: Float = 0.995
        let a = abs(x)
        guard a > knee else { return x }
        let limited = knee + (ceiling - knee) * tanh((a - knee) / (ceiling - knee))
        return x < 0 ? -limited : limited
    }

    // MARK: - M4A (AAC, Apple Lossless)

    private static func writeMPEG4(_ store: PCMStore, format: ExportFormat, metadata: [AVMetadataItem],
                                   to url: URL, progress: (Double) -> Void) async throws {
        let channels = store.channelCount
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: layoutData
        ]
        switch format {
        case .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = channels == 1 ? 96_000 : 160_000
        default:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = 24
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        writer.metadata = metadata
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let description = try formatDescription(channels: channels)
        do {
            for block in blocks(of: store) {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let buffer = try sampleBuffer(interleaving: block.channels, at: block.offset, format: description)
                guard input.append(buffer) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                progress(Double(block.offset) / Double(store.count))
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        progress(1)
    }

    private static func formatDescription(channels: Int) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
                                                    layout: nil, magicCookieSize: 0, magicCookie: nil,
                                                    extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw CocoaError(.fileWriteUnknown) }
        return description
    }

    private static func sampleBuffer(interleaving channels: [[Float]], at frame: Int,
                                     format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        let frames = channels[0].count, count = channels.count
        var interleaved = [Float](repeating: 0, count: frames * count)
        for (c, samples) in channels.enumerated() {
            for i in 0..<frames { interleaved[i * count + c] = samples[i] }
        }
        let bytes = interleaved.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard status == noErr, let block else { throw CocoaError(.fileWriteUnknown) }
        status = interleaved.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw CocoaError(.fileWriteUnknown) }
        return sample
    }

    // MARK: - WAV

    private static func writeWAV(_ store: PCMStore, to url: URL, progress: (Double) -> Void) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: store.channelCount,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        for block in blocks(of: store) {
            try Task.checkCancellation()
            let frames = block.channels[0].count
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for (c, samples) in block.channels.enumerated() {
                samples.withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: frames) }
            }
            try file.write(from: buffer)
            progress(Double(block.offset) / Double(store.count))
        }
        progress(1)
    }
}
