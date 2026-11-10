import AppIntents
import Foundation
import SoundOwlCore
import UniformTypeIdentifiers

/// Shortcuts' "Restore Audio": recordings in, restored copies out. Runs in the background, with
/// the same engine and default settings as everything else; the window doesn't open.
struct RestoreAudioIntent: AppIntent, ProgressReportingIntent {
    static let title: LocalizedStringResource = "Restore Audio"
    static let description = IntentDescription(
        "Makes the voices in recordings clearer, on this Mac. Each copy is saved next to its original as “Name (Restored)”; originals are never changed.",
        categoryName: "Audio"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Recordings", supportedContentTypes: [.audio], inputConnectionBehavior: .connectToPreviousIntentResult)
    var files: [IntentFile]

    @Parameter(title: "Reduce Background Noise",
               description: "Leave empty to use the setting in SoundOwl › Settings › Restoring.")
    var denoise: Bool?

    @Parameter(title: "Format", description: "Leave empty to use the setting in SoundOwl › Settings › Restoring.")
    var format: RestoreFormat?

    @Parameter(title: "Save Next to Original", default: true)
    var nextToOriginal: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Restore \(\.$files)") {
            \.$denoise
            \.$format
            \.$nextToOriginal
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let app = AppModel.shared
        let recipe = app.recipe.overriding(denoise: denoise, format: format?.exportFormat)

        // Files from Finder come with a location; files from other actions may be data only, and
        // are restored in a scratch folder (as are all of them when not saving next to the originals).
        let scratch = FileManager.default.temporaryDirectory.appending(path: "SoundOwl Shortcuts/\(UUID().uuidString)")
        var inputs = [(url: URL, destination: RestoreDestination)]()
        for file in files {
            if let url = file.fileURL, nextToOriginal {
                inputs.append((url, .nextToOriginal))
            } else {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let url = scratch.appending(path: file.filename)
                try file.data.write(to: url)
                inputs.append((url, .folder(scratch)))
            }
        }

        progress.totalUnitCount = Int64(inputs.count)
        var jobs = [RestoreService.Job]()
        for destination in Set(inputs.map(\.destination)) {
            let urls = inputs.filter { $0.destination == destination }.map(\.url)
            let done = jobs.count
            jobs += await app.restore(urls, recipe: recipe, destination: destination) { finished in
                progress.completedUnitCount = Int64(done + finished)
            }
        }
        progress.completedUnitCount = progress.totalUnitCount

        let outputs = jobs.compactMap { job -> IntentFile? in
            guard case .done(let url) = job.state else { return nil }
            return IntentFile(fileURL: url, filename: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension))
        }
        if outputs.isEmpty {
            let reason = jobs.lazy.compactMap { job -> String? in
                if case .failed(let message) = job.state { return message }
                return nil
            }.first
            throw RestoreAudioError.nothingRestored(reason ?? String(localized: "No recordings were restored."))
        }
        return .result(value: outputs)
    }
}

enum RestoreAudioError: Error, CustomLocalizedStringResourceConvertible {
    case nothingRestored(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingRestored(let reason): "\(reason)"
        }
    }
}

enum RestoreFormat: String, AppEnum {
    case aac
    case alac
    case wav

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Format"
    static let caseDisplayRepresentations: [RestoreFormat: DisplayRepresentation] = [
        .aac: "AAC",
        .alac: "Apple Lossless",
        .wav: "WAV"
    ]

    var exportFormat: ExportFormat {
        switch self {
        case .aac: .aac
        case .alac: .alac
        case .wav: .wav
        }
    }
}

struct SoundOwlShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RestoreAudioIntent(),
            phrases: [
                "Restore audio with \(.applicationName)",
                "Make a recording clearer with \(.applicationName)"
            ],
            shortTitle: "Restore Audio",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: SetLiveIntent(),
            phrases: [
                "Turn on Live in \(.applicationName)",
                "Make my call clearer with \(.applicationName)"
            ],
            shortTitle: "Live",
            systemImageName: "phone.bubble"
        )
    }
}
