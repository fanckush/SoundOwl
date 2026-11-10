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

private func scratchDefaults() -> UserDefaults {
    let name = "SoundOwlTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func scratchFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SoundOwlTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

struct RecipeTests {
    @Test func roundTripsThroughDefaults() {
        let defaults = scratchDefaults()
        #expect(RecipeStore.load(from: defaults) == .standard)
        let recipe = Recipe.standard.overriding(denoise: true, format: .wav)
        RecipeStore.save(recipe, to: defaults)
        #expect(RecipeStore.load(from: defaults) == recipe)
    }

    @Test func carriesOverSettingsFromBeforeRecipes() {
        let defaults = scratchDefaults()
        defaults.set("alac", forKey: RecipeStore.legacyFormatKey)
        defaults.set(true, forKey: RecipeStore.legacyDenoiseKey)
        let recipe = RecipeStore.load(from: defaults)
        #expect(recipe.format == .alac)
        #expect(recipe.denoise)
        RecipeStore.save(recipe, to: defaults)
        #expect(defaults.object(forKey: RecipeStore.legacyFormatKey) == nil)
    }

    @Test func overridesOnlyWhatIsGiven() {
        let base = Recipe.standard.overriding(denoise: true)
        #expect(base.overriding(format: .wav).denoise)
        #expect(base.overriding(denoise: false).format == .aac)
        #expect(base.overriding() == base)
    }

    @Test func fallsBackToDownloadsWhenTheFolderIsReadOnly() throws {
        let folder = try scratchFolder()
        let file = folder.appending(path: "a.m4a")
        #expect(RestoreDestination.nextToOriginal.folder(for: file).path == folder.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(RestoreDestination.nextToOriginal.folder(for: file).path == URL.downloadsDirectory.path)
        #expect(RestoreDestination.folder(folder).folder(for: file) == folder)
    }

    @Test func discardedRangesReadAsSilence() throws {
        let store = try PCMStore(directory: scratchFolder(), name: "t", channels: 1, count: 100_000)
        try store.write([Float](repeating: 0.5, count: 100_000), channel: 0, at: 0)
        store.discard(channel: 0, range: 10_000..<90_000)
        let inside = try store.read(channel: 0, range: 20_000..<80_000)
        #expect(inside.allSatisfy { $0 == 0 })
        #expect(try store.read(channel: 0, range: 0..<5000).allSatisfy { $0 == 0.5 })
    }
}

@Suite(.enabled(if: hasModel, "needs the exported model package (tools/model-export/export.py)"))
struct FileRestoreTests {
    @Test func savesNextToTheOriginalWithAFreshName() async throws {
        let model = try LavaSR(package: ModelPackage(directory: modelDirectory))
        let folder = try scratchFolder()
        let original = folder.appending(path: "Interview.wav")
        try FileManager.default.copyItem(at: fixtures.appending(path: "speech-16k.in.wav"), to: original)

        let first = try await FileRestore.run(original, recipe: .standard, model: model)
        #expect(first == folder.appending(path: "Interview (Restored).m4a"))
        let second = try await FileRestore.run(original, recipe: .standard.overriding(format: .wav), model: model)
        #expect(second == folder.appending(path: "Interview (Restored).wav"))
        let third = try await FileRestore.run(original, recipe: .standard, model: model)
        #expect(third.lastPathComponent == "Interview (Restored 2).m4a")

        let file = try AVAudioFile(forReading: first)
        let source = try AVAudioFile(forReading: original)
        #expect(file.fileFormat.sampleRate == 48_000)
        let duration = Double(file.length) / 48_000, sourceDuration = Double(source.length) / source.fileFormat.sampleRate
        #expect(abs(duration - sourceDuration) < 0.05)
    }
}

struct ModelInstallLockTests {
    /// The app and the command line installing at once must end with one good install.
    @Test func concurrentInstallsLeaveOneGoodPackage() async throws {
        let zip = root.appending(path: "tools/model-export/build/lavasr-v2-1.zip")
        guard FileManager.default.fileExists(atPath: zip.path) else { return }
        let rootFolder = try scratchFolder()
        let destination = ModelStore.installDirectory(for: .lavaSRv2, root: rootFolder)
        try await withThrowingTaskGroup(of: ModelPackage.self) { group in
            for _ in 0..<3 {
                group.addTask { try await ModelStore.install(.lavaSRv2, root: rootFolder, into: destination, from: zip) }
            }
            for try await package in group { #expect(package.manifest.id == "lavasr-v2") }
        }
        #expect(try ModelStore.installed(at: destination).manifest.packageVersion == 1)
    }
}
