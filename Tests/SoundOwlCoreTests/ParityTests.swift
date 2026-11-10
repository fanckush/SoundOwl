import Foundation
import Testing
@testable import SoundOwlCore

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
private let fixtures = root.appending(path: "Tests/Fixtures/lavasr-v2")
private let modelDirectory = ProcessInfo.processInfo.environment["SOUNDOWL_MODEL_DIR"].map { URL(fileURLWithPath: $0) }
    ?? root.appending(path: "tools/model-export/build/lavasr-v2")
private let hasModel = FileManager.default.fileExists(atPath: modelDirectory.appending(path: "model.json").path)

@Suite(.enabled(if: hasModel, "needs the exported model package (tools/model-export/export.py)"))
struct ParityTests {
    let model: LavaSR

    init() throws {
        model = try LavaSR(package: ModelPackage(directory: modelDirectory))
    }

    @Test func matchesUpstreamOnEveryFixture() throws {
        for result in try Parity.run(model: model, fixtures: fixtures) {
            #expect(result.passed, "\(result)")
        }
    }

    /// A chunked restore must match a single pass: chunking is an implementation detail.
    @Test func chunkingIsTransparent() throws {
        let clip = try AudioIO.read(fixtures.appending(path: "speech-16k.in.wav")).channels[0]
        let restorer = Restorer(model: model)
        let single = try restorer.restore(clip)
        let chunked = try restorer.restore(clip, chunkSeconds: 1.3) // several seams inside a 6 s clip
        #expect(chunked.count == clip.count * 3)
        let result = Parity.compare(name: "chunked", got: chunked, expected: single)
        #expect(result.snr > 80, "\(result)")
    }

    /// Restoring chunks out of order (as the app does, playhead first) gives the same audio.
    @Test func chunkOrderDoesNotMatter() throws {
        let clip = try AudioIO.read(fixtures.appending(path: "speech-16k.in.wav")).channels[0]
        let restorer = Restorer(model: model)
        let plan = ChunkPlan(count: clip.count, chunkSeconds: 1.3)
        let forward = try (0..<plan.chunkCount).map { try restorer.restoreChunk($0, of: plan) { Array(clip[$0]) } }
        let backward = try (0..<plan.chunkCount).reversed().map { try restorer.restoreChunk($0, of: plan) { Array(clip[$0]) } }
        #expect(forward == Array(backward.reversed()))
    }

    @Test func preservesDurationForAnyLength() throws {
        let restorer = Restorer(model: model)
        for count in [1, 100, 257, 4000, 16_001] {
            let out = try restorer.restore([Float](repeating: 0.01, count: count))
            #expect(out.count == count * 3)
        }
    }
}
