import Foundation
import Testing
@testable import SoundOwlCore

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
private let fixtures = root.appending(path: "Tests/Fixtures/lavasr-v2")
private let modelDirectory = ProcessInfo.processInfo.environment["SOUNDOWL_MODEL_DIR"].map { URL(fileURLWithPath: $0) }
    ?? root.appending(path: "tools/model-export/build/lavasr-v2")
private let hasModel = FileManager.default.fileExists(atPath: modelDirectory.appending(path: "model.json").path)

/// Streams `clip` one hop at a time, the way live restoring feeds it.
private func stream(_ clip: [Float], through restorer: StreamRestorer) throws -> [Float] {
    var out = [Float]()
    var position = 0
    while position < clip.count {
        let next = min(position + restorer.plan.core, clip.count)
        out += try restorer.push(Array(clip[position..<next]))
        position = next
    }
    return try out + (restorer.finish())
}

@Suite(.enabled(if: hasModel, "needs the exported model package (tools/model-export/export.py)"))
struct StreamRestorerTests {
    let model: LavaSR
    let clip: [Float]

    init() throws {
        model = try LavaSR(package: ModelPackage(directory: modelDirectory))
        clip = try AudioIO.read(fixtures.appending(path: "speech-16k.in.wav")).channels[0]
    }

    /// A stream is the file path on an endless plan: every hop whose window is the same as a
    /// file chunk's must give the very same samples.
    @Test func hopsMatchFileChunksExactly() throws {
        let core = 20 * ChunkPlan.grid, context = 31 * ChunkPlan.grid
        let streamed = try stream(clip, through: StreamRestorer(model: model, core: core, before: context, after: context))
        #expect(streamed.count == clip.count * 3)

        let plan = ChunkPlan(count: clip.count, core: core, before: context, after: context)
        let restorer = Restorer(model: model)
        var compared = 0
        for index in 0..<plan.chunkCount where plan.core(index).upperBound + context <= clip.count + ChunkPlan.tail {
            let expected = try restorer.restoreChunk(index, of: plan) { Array(clip[$0]) }
            let range = plan.core(index).lowerBound * 3..<plan.core(index).upperBound * 3
            #expect(Array(streamed[range]) == expected, "hop \(index)")
            compared += 1
        }
        #expect(compared >= 3)
    }

    /// With a second of context both sides, small hops sound like one pass over the file. Every
    /// seam costs a little (here ~90 of them in 6 s, against 5 in `chunkingIsTransparent`), so the
    /// bar is lower than there, and still far below anything audible.
    @Test func smallHopsWithFullContextMatchOnePass() throws {
        let context = 31 * ChunkPlan.grid
        let streamed = try stream(clip, through: StreamRestorer(model: model, core: 4 * ChunkPlan.grid,
                                                                before: context, after: context))
        let single = try Restorer(model: model).restore(clip)
        let result = Parity.compare(name: "stream", got: streamed, expected: single)
        #expect(result.snr > 70, "\(result)")
    }

    /// The short look-ahead live would use still gives whole, finite output of the right length,
    /// with and without a crossfade.
    @Test func shortLookaheadKeepsLengthAndStaysFinite() throws {
        for crossfade in [0, 256] {
            let restorer = StreamRestorer(model: model, core: 2 * ChunkPlan.grid, before: 16 * ChunkPlan.grid,
                                          after: 2 * ChunkPlan.grid, crossfade: crossfade)
            #expect(restorer.latency == 4 * ChunkPlan.grid)
            let out = try stream(clip, through: restorer)
            #expect(out.count == clip.count * 3)
            // A key path here trips the #expect macro (it can't tell it doesn't throw).
            // swiftformat:disable:next preferKeyPath
            #expect(out.allSatisfy { $0.isFinite })
            #expect(out.contains { $0 != 0 })
        }
    }

    @Test func outputComesInWholeHops() throws {
        let restorer = StreamRestorer(model: model, core: 2 * ChunkPlan.grid, before: 8 * ChunkPlan.grid,
                                      after: ChunkPlan.grid)
        var total = 0
        for size in [100, 700, 1500, 3000, 17] {
            let out = try restorer.push(Array(clip.prefix(size)))
            #expect(out.count % (restorer.plan.core * 3) == 0)
            total += out.count
        }
        #expect(total == (5317 - ChunkPlan.grid) / restorer.plan.core * restorer.plan.core * 3)
    }
}

struct QualityTests {
    private func tone(_ count: Int, hz: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / 48_000)) }
    }

    @Test func identicalSignalsAreIdentical() {
        let x = zip(tone(48_000, hz: 440), tone(48_000, hz: 12_000, amplitude: 0.05)).map { $0 + $1 }
        let result = Quality.highBand(got: x, ref: x, above: 8000)
        #expect(result.snr > 200)
        #expect(result.lsd < 1e-6)
    }

    @Test func highBandIgnoresLowBandDifferences() {
        let ref = zip(tone(48_000, hz: 440), tone(48_000, hz: 12_000, amplitude: 0.05)).map { $0 + $1 }
        let got = zip(tone(48_000, hz: 440, amplitude: 0.1), tone(48_000, hz: 12_000, amplitude: 0.05)).map { $0 + $1 }
        #expect(Quality.highBand(got: got, ref: ref, above: 8000).snr > 40)
    }

    /// Error bunched at hop boundaries reads as several dB; error spread evenly reads as about zero.
    @Test func seamRatioFindsBoundaryErrors() {
        let hop = 1536, count = hop * 40
        let ref = tone(count, hz: 440)
        var bunched = ref, spread = ref
        var seed: UInt64 = 1
        func noise() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: seed >> 11) % 2000 - 1000) / 1_000_000
        }
        for i in 0..<count {
            let distance = min(i % hop, hop - i % hop)
            if i >= hop / 2, distance < 60 { bunched[i] += 20 * noise() }
            spread[i] += noise()
        }
        #expect(Quality.seamRatio(got: bunched, ref: ref, hop: hop, above: 8000) > 6)
        #expect(abs(Quality.seamRatio(got: spread, ref: ref, hop: hop, above: 8000)) < 1.5)
    }

    @Test func fullBandMeansTheVoiceItselfReachesHigh() {
        // A "voice" that talks in bursts with pauses between, 0.5 s on, 0.5 s off.
        let talk = (0..<96_000).map { i -> Float in (i / 24_000) % 2 == 0 ? 1 : 0.001 }
        let voice = zip(tone(96_000, hz: 1000), talk).map { $0 * $1 }
        let airInVoice = zip(voice, zip(tone(96_000, hz: 9500, amplitude: 0.05), talk).map { $0 * $1 }).map { $0 + $1 }
        // Old recording on a full-band stream: dull voice, steady hiss up top.
        let hiss = zip(voice, tone(96_000, hz: 9500, amplitude: 0.05)).map { $0 + $1 }

        #expect(!Quality.hasFullBandContent(voice, sampleRate: 48_000))
        #expect(Quality.hasFullBandContent(airInVoice, sampleRate: 48_000))
        #expect(!Quality.hasFullBandContent(hiss, sampleRate: 48_000), "steady highs are noise, not voice")
        #expect(!Quality.hasFullBandContent(airInVoice, sampleRate: 16_000))
    }
}
