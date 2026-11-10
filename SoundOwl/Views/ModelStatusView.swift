import SoundOwlCore
import SwiftUI

/// Getting the voice model, said plainly: what it is, how big, that it stays on this Mac, and
/// that it only happens once. Files can be dropped while it downloads.
struct ModelStatusView: View {
    @Environment(AppModel.self) private var app
    /// The menu bar panel's version: smaller, same words.
    var compact = false

    private var models: ModelStore { app.models }
    private var size: String { ByteCountFormatter.string(fromByteCount: models.release.bytes, countStyle: .file) }

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 10 : 14) {
            if !compact { OwlMark(size: 40, listening: isWorking) }
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                Text(title)
                    .font(compact ? .callout.weight(.semibold) : .headline)
                Text(message)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .downloading(let fraction) = models.phase {
                    ProgressView(value: fraction ?? 0)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Download progress")
                } else if models.phase == .installing {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            Spacer(minLength: 0)
            switch models.phase {
            case .failed:
                Button("Try Again") { models.download() }
            case .missing:
                Button("Download") { models.download() }
                    .buttonStyle(.borderedProminent)
            case .downloading:
                Button("Cancel") { models.cancel() }
            default:
                EmptyView()
            }
        }
        .controlSize(compact ? .small : .regular)
        .padding(compact ? 10 : 16)
        .frame(maxWidth: 640)
        .soundOwlSurface()
        .accessibilityElement(children: .combine)
    }

    private var isWorking: Bool {
        switch models.phase {
        case .downloading, .installing, .checking: true
        default: false
        }
    }

    private var title: String {
        switch models.phase {
        case .checking, .downloading: String(localized: "Getting SoundOwl ready")
        case .installing: String(localized: "Almost there")
        case .missing: String(localized: "SoundOwl needs its voice model")
        case .failed: String(localized: "The voice model couldn't be downloaded")
        case .ready: ""
        }
    }

    private var message: String {
        switch models.phase {
        case .checking, .downloading, .missing:
            String(
                localized: "SoundOwl uses an AI voice model that runs entirely on your Mac. Downloading \(models.release.name) · \(size). This only happens once, and your recordings never leave your Mac."
            )
        case .installing:
            String(localized: "Checking the download…")
        case .failed(let reason):
            reason
        case .ready:
            ""
        }
    }
}
