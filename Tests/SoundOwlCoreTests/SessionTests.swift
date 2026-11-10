import AVFoundation
import Foundation
import Testing
@testable import SoundOwlCore

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
private let fixtures = root.appending(path: "Tests/Fixtures/lavasr-v2")
private let modelDirectory = ProcessInfo.processInfo.environment["SOUNDOWL_MODEL_DIR"].map { URL(fileURLWithPath: $0) }
    ?? root.appending(path: "tools/model-export/build/lavasr-v2")
private let hasModel = FileManager.default.fileExists(atPath: modelDirectory.appending(path: "model.json").path)

/// A 44.1 kHz stereo M4A with tags and artwork, like a real audiobook part.
private func makeTaggedRecording(in folder: URL) throws -> URL {
    let speech = try AudioIO.read(fixtures.appending(path: "speech-16k.in.wav")).channels[0]
    let wav = folder.appending(path: "plain.wav")
    let up = try AudioIO.resample(speech, from: 16_000, to: 44_100)
    try AudioIO.writeWAV([up, up.map { $0 * 0.5 }], sampleRate: 44_100, to: wav)
    let m4a = folder.appending(path: "Chapter 3.m4a")
    let convert = Process()
    convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    convert.arguments = ["-f", "m4af", "-d", "aac", "-b", "64000", wav.path, m4a.path]
    try convert.run()
    convert.waitUntilExit()
    return m4a
}

@Suite(.enabled(if: hasModel, "needs the exported model package (tools/model-export/export.py)"))
struct SessionTests {
    let model: LavaSR
    let folder: URL

    init() throws {
        model = try LavaSR(package: ModelPackage(directory: modelDirectory))
        folder = FileManager.default.temporaryDirectory.appending(path: "SoundOwlTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func restoresStereoFileAndExportsEveryFormat() async throws {
        let url = try makeTaggedRecording(in: folder)
        let source = try await AudioSource(url: url)
        #expect(source.channelCount == 2)
        let session = try RestorationSession(source: source)
        try session.prepare()
        #expect(session.cutoff == 8000)

        // Out of order, as the app does when the playhead is in the middle.
        while let chunk = session.nextChunk(focus: session.plan.count / 2) {
            try session.restore(chunk: chunk, with: model)
        }
        #expect(session.isComplete)
        let store = try #require(session.completedOutput())
        #expect(store.count == source.modelFrameCount * 3)
        #expect(abs(Double(store.count) / 48_000 - source.duration) < 0.001)

        for format in ExportFormat.allCases {
            let out = try await Exporter.export(store, source: url, to: folder, format: format)
            #expect(out.lastPathComponent == "Chapter 3 (Restored).\(format.fileExtension)"
                || out.lastPathComponent == "Chapter 3 (Restored 2).\(format.fileExtension)")
            let file = try AVAudioFile(forReading: out)
            #expect(file.fileFormat.sampleRate == 48_000)
            #expect(file.fileFormat.channelCount == 2)
            #expect(abs(Double(file.length) / 48_000 - source.duration) < 0.05)
        }
        // No temporary files left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".soundowl") }
        #expect(leftovers.isEmpty)
    }

    @Test func togglingDenoiseStartsOver() async throws {
        let url = fixtures.appending(path: "noisy-16k-denoise.in.wav")
        let session = try await RestorationSession(source: AudioSource(url: url))
        try session.prepare()
        try session.restore(chunk: 0, with: model)
        #expect(session.isComplete)
        session.denoise = true
        #expect(!session.isComplete)
        #expect(session.restored(channel: 0, range: 0..<100) == nil)
        try session.restore(chunk: 0, with: model)
        #expect(session.isComplete)
    }

    @Test func collisionsGetNumberedNames() {
        let source = folder.appending(path: "Talk.mp3")
        FileManager.default.createFile(atPath: folder.appending(path: "Talk (Restored).m4a").path, contents: Data())
        #expect(Exporter.uniqueURL(in: folder, for: source, extension: "m4a").lastPathComponent == "Talk (Restored 2).m4a")
    }
}

struct AudioFilesTests {
    @Test func expandsFoldersInFinderOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SoundOwlFiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "sub"), withIntermediateDirectories: true)
        for name in ["Part 10.mp3", "Part 2.mp3", "notes.txt", ".hidden.mp3", "sub/Part 1.m4a"] {
            FileManager.default.createFile(atPath: folder.appending(path: name).path, contents: Data())
        }
        let names = AudioFiles.expand([folder]).map(\.lastPathComponent)
        #expect(names == ["Part 2.mp3", "Part 10.mp3", "Part 1.m4a"])
    }

    @Test func keepsExplicitFilesSoTheyCanBeExplained() {
        let file = FileManager.default.temporaryDirectory.appending(path: "readme-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: file.path, contents: Data("hi".utf8))
        #expect(AudioFiles.expand([file, file]) == [file])
    }

    @Test func softLimitNeverClips() {
        for x in stride(from: -3 as Float, through: 3, by: 0.01) {
            #expect(abs(Exporter.softLimit(x)) < 1)
        }
        #expect(Exporter.softLimit(0.5) == 0.5)
    }
}

@MainActor
struct ModelStoreTests {
    @Test func installsFromAnArchiveAndRejectsDamage() async throws {
        let zip = root.appending(path: "tools/model-export/build/lavasr-v2-1.zip")
        guard FileManager.default.fileExists(atPath: zip.path) else { return }
        let rootFolder = FileManager.default.temporaryDirectory.appending(path: "SoundOwlModels-\(UUID().uuidString)")
        let release = ModelRelease.lavaSRv2
        let package = try await ModelStore.install(release, root: rootFolder,
                                                   into: rootFolder.appending(path: "lavasr-v2/1"),
                                                   from: zip)
        #expect(package.manifest.id == "lavasr-v2")
        #expect(try ModelStore.installed(at: rootFolder.appending(path: "lavasr-v2/1")).manifest.packageVersion == 1)

        let damaged = rootFolder.appending(path: "damaged.zip")
        try Data(Data(contentsOf: zip).prefix(1000)).write(to: damaged)
        await #expect(throws: (any Error).self) {
            try await ModelStore.install(release, root: rootFolder, into: rootFolder.appending(path: "x/1"), from: damaged)
        }
    }
}
