import AudioToolbox
import Foundation
import Testing
@testable import SoundOwlCore
@testable import SoundOwlLive

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
private let fixtures = root.appending(path: "Tests/Fixtures/lavasr-v2")
private let modelDirectory = ProcessInfo.processInfo.environment["SOUNDOWL_MODEL_DIR"].map { URL(fileURLWithPath: $0) }
    ?? root.appending(path: "tools/model-export/build/lavasr-v2")
private let hasModel = FileManager.default.fileExists(atPath: modelDirectory.appending(path: "model.json").path)
#if DEBUG
    private let isOptimized = false
#else
    private let isOptimized = true
#endif

struct RingTests {
    /// One thread writes a counting sequence in odd-sized pieces, another reads it back: nothing
    /// lost, nothing reordered, however the two interleave.
    @Test func fifoKeepsOrderAcrossThreads() {
        let fifo = SampleFIFO(minimumCapacity: 1000)
        let total = 400_000
        let writer = Thread {
            var next = 0
            var chunk = [Float](repeating: 0, count: 97)
            while next < total {
                let n = min(chunk.count, total - next)
                for i in 0..<n { chunk[i] = Float(next + i) }
                var done = 0
                while done < n {
                    done += chunk.withUnsafeBufferPointer { fifo.write($0.baseAddress! + done, count: n - done) }
                }
                next += n
            }
        }
        writer.start()
        var expected = 0
        var buffer = [Float](repeating: 0, count: 61)
        let deadline = Date.now.addingTimeInterval(20)
        while expected < total, Date.now < deadline {
            let n = buffer.withUnsafeMutableBufferPointer { fifo.read(into: $0.baseAddress!, maxCount: $0.count) }
            for i in 0..<n where buffer[i] != Float(expected + i) {
                Issue.record("sample \(expected + i) read as \(buffer[i])")
                return
            }
            expected += n
        }
        #expect(expected == total)
    }

    @Test func timelineSkipsAheadAndNeverShowsStaleFrames() {
        let ring = TimelineRing(minimumCapacity: 64)
        let ones = [Float](repeating: 1, count: 10), twos = [Float](repeating: 2, count: 10)
        ones.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 10, at: 0) }
        #expect(ring.available(in: 5..<20) == 5..<10)
        twos.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 10, at: 30) }
        // The jump leaves 0..<30 behind: not available, even the part written before.
        #expect(ring.available(in: 0..<30).isEmpty)
        #expect(ring.available(in: 25..<35) == 30..<35)
        #expect(ring.frame(at: 31) == 2)
        // The writer never laps the reader.
        ring.advanceReader(to: 40)
        let many = [Float](repeating: 3, count: 200)
        many.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 200, at: 40) }
        #expect(ring.writtenEnd == 40 + ring.capacity)
    }
}

/// Interleaved stereo buffers shaped like the IOProc's.
private final class StereoBuffers {
    let frames: Int
    let input: UnsafeMutablePointer<Float>
    let output: UnsafeMutablePointer<Float>
    let inputList: UnsafeMutableAudioBufferListPointer
    let outputList: UnsafeMutableAudioBufferListPointer

    init(frames: Int) {
        self.frames = frames
        input = .allocate(capacity: frames * 2)
        output = .allocate(capacity: frames * 2)
        inputList = AudioBufferList.allocate(maximumBuffers: 1)
        outputList = AudioBufferList.allocate(maximumBuffers: 1)
        inputList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: input)
        outputList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: output)
    }

    deinit {
        input.deallocate()
        output.deallocate()
        free(inputList.unsafeMutablePointer)
        free(outputList.unsafeMutablePointer)
    }

    /// Plays `signal[start..<start+frames]` (mono, both channels) through `pipeline`; returns the
    /// left output channel.
    func render(_ signal: [Float], from start: Int, through pipeline: LivePipeline) -> [Float] {
        for i in 0..<frames {
            let x = start + i < signal.count ? signal[start + i] : 0
            input[2 * i] = x
            input[2 * i + 1] = x
        }
        pipeline.render(input: inputList.unsafePointer, output: outputList.unsafeMutablePointer, frames: frames)
        return (0..<frames).map { output[2 * $0] }
    }
}

@Suite(.enabled(if: hasModel, "needs the exported model package (tools/model-export/export.py)"))
struct LivePipelineTests {
    let model: LavaSR
    let clip48: [Float]

    init() throws {
        model = try LavaSR(package: ModelPackage(directory: modelDirectory), intraOpThreads: 2)
        let clip = try AudioIO.read(fixtures.appending(path: "speech-16k.in.wav")).channels[0]
        clip48 = try AudioIO.resample(clip, from: 16_000, to: 48_000)
    }

    /// With no engine at all, the output is the input `delay` frames later, sample for sample.
    @Test func withoutTheEngineTheOriginalPlaysDelayed() throws {
        let pipeline = try LivePipeline(model: model, sampleRate: 48_000, bufferFrames: 512)
        let buffers = StereoBuffers(frames: 512)
        var out = [Float]()
        var start = 0
        while start < 4 * 48_000 {
            out += buffers.render(clip48, from: start, through: pipeline)
            start += 512
        }
        let d = pipeline.delay
        #expect(out[..<d].allSatisfy { $0 == 0 })
        let mismatches = (d..<out.count).filter { out[$0] != clip48[$0 - d] }.count
        #expect(mismatches == 0)
        #expect(pipeline.framesFallenBack.load(ordering: .relaxed) == 0, "not ready yet, so not a fallback")
    }

    /// At twice real time, the engine keeps up: after the first measurement nearly everything
    /// plays restored, lined up with the input.
    ///
    /// Timing, so optimized builds only: unoptimized DSP takes longer than a hop lasts. CI runs it
    /// with `swift test -c release -Xswiftc -enable-testing --filter LivePipelineTests`.
    @Test(.enabled(if: isOptimized, "timing test; run with -c release"))
    func restoresInTimeAndStaysAligned() throws {
        let pipeline = try LivePipeline(model: model, sampleRate: 48_000, bufferFrames: 512)
        pipeline.start()
        defer { pipeline.stop() }
        let buffers = StereoBuffers(frames: 512)
        var out = [Float]()
        var start = 0
        var readyAt: Int?
        let total = clip48.count + pipeline.delay
        let period = 512.0 / 48_000 / 2
        let began = Date.now
        while start < total {
            out += buffers.render(clip48, from: start, through: pipeline)
            start += 512
            if readyAt == nil, pipeline.isReady { readyAt = start }
            let due = began.addingTimeInterval(Double(start / 512) * period)
            if due > .now { Thread.sleep(until: due) }
        }
        let ready = try #require(readyAt, "the bandwidth should be measured within the clip")
        #expect(!pipeline.isAlreadyClear)
        #expect(pipeline.cutoffHz.load(ordering: .relaxed) >= 7000)

        let played = pipeline.framesPlayed.load(ordering: .relaxed)
        let fallback = pipeline.framesFallenBack.load(ordering: .relaxed)
        #expect(
            Double(fallback) < 0.05 * Double(played - ready),
            "fell back for \(fallback) of \(played - ready) frames, worst hop \(pipeline.worstHopMicros.load(ordering: .relaxed)) µs"
        )

        // The restored voice keeps the original's lows, so it correlates best with the input at
        // exactly the pipeline's delay.
        let from = ready + pipeline.delay + 48_000, to = min(out.count, clip48.count + pipeline.delay) - 100
        #expect(to - from > 48_000)
        func correlation(_ lag: Int) -> Double {
            var xy = 0.0, xx = 0.0, yy = 0.0
            for i in from..<to {
                let x = Double(out[i]), y = Double(clip48[i - lag])
                xy += x * y
                xx += x * x
                yy += y * y
            }
            return xy / max(1e-12, (xx * yy).squareRoot())
        }
        let best = (pipeline.delay - 24...pipeline.delay + 24).max { correlation($0) < correlation($1) }!
        #expect(abs(best - pipeline.delay) <= 2, "best lag \(best), delay \(pipeline.delay)")
        #expect(correlation(pipeline.delay) > 0.9)
    }
}

/// Music is left alone: the classifier's scores, turned into a decision.
struct SoundKindTests {
    @Test func singingAndMusicOutweighSpeech() {
        #expect(SoundKindDetector.verdict(speech: 0.98, music: 0.15, singing: 0) == .voice)
        #expect(SoundKindDetector.verdict(speech: 0.7, music: 0.6, singing: 0.5) == .music)
        #expect(SoundKindDetector.verdict(speech: 0.4, music: 0.1, singing: 0.46) == .music)
        #expect(SoundKindDetector.verdict(speech: 0.3, music: 0.2, singing: 0) == .other)
    }

    @Test func oneOddWindowDoesNotFlipIt() {
        #expect(SoundKindDetector.decide([.voice, .voice, .music], current: .voice) == .voice)
        #expect(SoundKindDetector.decide([.voice, .music, .music], current: .voice) == .music)
        #expect(SoundKindDetector.decide([.music, .other, .other], current: .music) == .music)
        #expect(SoundKindDetector.decide([.other], current: .unknown) == .unknown)
    }
}
