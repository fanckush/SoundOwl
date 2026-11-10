import AVFoundation
import Foundation
import Observation
import SoundOwlCore

/// One file SoundOwl is working on: the one you're listening to, or one restoring in the
/// background. What it is, and how far restoring has got.
@MainActor @Observable
final class Recording: Identifiable {
    enum Phase: Equatable {
        case opening
        case preparing(Double)
        case restoring
        case restored
        case failed(String)
    }

    struct Chapter: Hashable {
        let title: String
        let start: Double
    }

    let id = UUID()
    let url: URL
    var phase: Phase = .opening
    private(set) var source: AudioSource?
    private(set) var session: RestorationSession?
    /// Loudness over the file, for the waveform.
    var peaks: [Float] = []
    var restoredFraction = 0.0
    private(set) var chapters: [Chapter] = []
    /// Where the restored copy was saved, once it has been.
    var savedURL: URL?
    /// Saving needs every chunk, so restoring stops freeing the ones behind the playhead.
    var keepsEverything = false

    /// Runs the denoiser before restoring. Changing it starts the restore over.
    var denoise: Bool {
        didSet {
            guard denoise != oldValue else { return }
            session?.denoise = denoise
            restoredFraction = 0
            if phase == .restored { phase = .restoring }
            savedURL = nil
            onChange?()
        }
    }

    /// Called when there is new work for the restore service.
    var onChange: (() -> Void)?

    init(url: URL, denoise: Bool) {
        self.url = url
        self.denoise = denoise
    }

    var name: String { url.deletingPathExtension().lastPathComponent }
    var duration: Double { source?.duration ?? 0 }

    /// Reads the file's format, or explains why it can't be used.
    func open() async {
        do {
            let source = try await AudioSource(url: url)
            let session = try RestorationSession(source: source)
            session.denoise = denoise
            self.source = source
            self.session = session
            phase = .preparing(0)
        } catch let error as AudioSource.OpenError {
            phase = .failed(error.localizedDescription)
        } catch {
            phase = .failed(String(localized: "SoundOwl can't read this file."))
        }
        onChange?()
        chapters = await Self.chapters(of: url)
    }

    /// Chapters of an audiobook (M4B and friends), if the file has any.
    private static func chapters(of url: URL) async -> [Chapter] {
        let asset = AVURLAsset(url: url)
        guard let groups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)
        else { return [] }
        var chapters = [Chapter]()
        for (index, group) in groups.enumerated() {
            var title: String?
            if let item = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first {
                title = try? await item.load(.stringValue)
            }
            chapters.append(Chapter(title: title ?? String(localized: "Chapter \(index + 1)"),
                                    start: group.timeRange.start.seconds))
        }
        return chapters.count > 1 ? chapters : []
    }

    /// "1:02:13 · Stereo · 44.1 kHz"
    var details: String {
        guard let source else { return url.pathExtension.uppercased() }
        let channels = source.channelCount == 1 ? String(localized: "Mono") : String(localized: "Stereo")
        let rate = (source.sampleRate / 1000).formatted(.number.precision(.fractionLength(0...1)))
        return "\(Format.duration(source.duration)) · \(channels) · \(rate) kHz"
    }
}

enum Format {
    /// 0:07, 12:03, 1:02:13
    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
