import SoundOwlCore
import SwiftUI

/// Starting with the Mac, and updates.
struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        @Bindable var updater = app.updater
        Form {
            Section {
                Toggle(isOn: $app.openAtLogin) {
                    Text("Open SoundOwl at login")
                    Text("SoundOwl lives in the menu bar. Live restores calls only while it's running.")
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                    .disabled(!updater.isAvailable)
                LabeledContent("Version", value: Self.version)
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.isAvailable)
                Text(updater.isAvailable
                    ? "SoundOwl is free and open source. Updates are signed and come from GitHub."
                    : "This is a local build, so it doesn't update itself. Official releases are on GitHub.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// How Live behaves. Switching apps on and off, and each app's options, live in the menu bar
/// panel; this is the overview.
struct LiveSettingsView: View {
    @Environment(AppModel.self) private var app

    private var switchedOn: [(id: String, name: String)] {
        app.live.enabled.map { ($0.key, $0.value) }.sorted { $0.name.localizedLowercase < $1.name.localizedLowercase }
    }

    var body: some View {
        @Bindable var live = app.live
        Form {
            Section {
                Toggle(isOn: $live.onlyWithHeadphones) {
                    Text("Only with headphones")
                    Text(
                        "Over speakers, the others on a call could hear themselves: call apps cancel echo using what they play, not what SoundOwl plays."
                    )
                }
            }
            Section {
                if switchedOn.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(switchedOn, id: \.id) { entry in
                    HStack(spacing: 10) {
                        Image(nsImage: AppIcons.icon(for: entry.id)).resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name)
                            Text(summary(app.live.options(for: entry.id)))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Turn Off") {
                            app.live.setOn(false, for: .init(id: entry.id, name: entry.name, isOn: true, isRunning: false,
                                                             status: .idle))
                        }
                    }
                }
            } header: {
                Text("Apps")
            } footer: {
                Text("Switch apps on, and change how each one sounds, from SoundOwl in the menu bar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Button("Open Privacy Settings…") { app.live.openPrivacySettings() }
                } label: {
                    Text("System Audio Recording")
                    Text("macOS asks the first time an app is switched on. Sound never leaves your Mac.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func summary(_ options: LiveController.Options) -> String {
        let balance = switch options.balance {
        case .faster: String(localized: "Faster")
        case .balanced: String(localized: "Balanced")
        case .clearer: String(localized: "Clearer")
        }
        var parts = [balance]
        if options.choices.reduceNoise { parts.append(String(localized: "Reduces background noise")) }
        if !options.choices.leaveClearSoundAlone { parts.append(String(localized: "Restores clear sound too")) }
        return parts.joined(separator: " · ")
    }
}

/// What the model is, who made it, and where it lives. For the curious; nobody has to read it.
struct ModelSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmRemove = false

    private var models: ModelStore { app.models }
    private var release: ModelRelease { models.release }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    OwlMark(size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(release.name).font(.headline)
                        Text("\(ByteCountFormatter.string(fromByteCount: release.bytes, countStyle: .file)) · \(status)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(release.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Made By") {
                ForEach(release.credits, id: \.self) { credit in
                    LabeledContent(credit.part) {
                        Text("\(credit.authors) · \(credit.license)")
                    }
                }
                HStack(spacing: 16) {
                    ForEach(release.links, id: \.self) { link in
                        Link(link.title, destination: link.url)
                    }
                }
            }
            Section {
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([models.installDirectory])
                    }
                    .disabled(models.phase != .ready)
                    Spacer()
                    Button("Download Again") {
                        try? models.remove()
                        models.download()
                    }
                    .disabled(isBusy)
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                        .disabled(models.phase != .ready)
                }
            } footer: {
                Text(
                    "The model runs entirely on this Mac. SoundOwl goes online only to download it once and to check for updates. Your sound never leaves your computer."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove the voice model?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { try? models.remove() }
        } message: {
            Text("SoundOwl needs it to restore sound and will download it again the next time it's needed.")
        }
    }

    private var isBusy: Bool {
        switch models.phase {
        case .downloading, .installing, .checking: true
        default: false
        }
    }

    private var status: String {
        switch models.phase {
        case .ready: String(localized: "On this Mac")
        case .downloading: String(localized: "Downloading…")
        case .installing: String(localized: "Installing…")
        case .checking: String(localized: "Checking…")
        case .missing: String(localized: "Not downloaded")
        case .failed: String(localized: "Download failed")
        }
    }
}

/// The default recipe: what "Restore" does from the owl, Finder, Shortcuts and the command line.
struct RestoringSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                Toggle(isOn: $app.recipe.denoise) {
                    Text("Reduce background noise")
                    Text("Removes steady hum, hiss and room noise. Leave it off if voices start to sound thin.")
                }
                Picker(selection: $app.recipe.format) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(Self.name(format)).tag(format)
                    }
                } label: {
                    Text("Format")
                    Text(Self.detail(app.recipe.format))
                }
            } footer: {
                Text(
                    "Clear copies are saved next to the original as “Name (Restored)”, keeping its title, artist and artwork. Originals are never changed. These settings apply wherever you start: the menu bar, Finder, Shortcuts or Terminal."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private static func name(_ format: ExportFormat) -> String {
        switch format {
        case .aac: String(localized: "AAC")
        case .alac: String(localized: "Apple Lossless")
        case .wav: String(localized: "WAV")
        }
    }

    private static func detail(_ format: ExportFormat) -> String {
        switch format {
        case .aac: String(localized: "Small files that sound great. Best for listening and sharing.")
        case .alac: String(localized: "Bit-perfect and still compressed. For archiving or editing.")
        case .wav: String(localized: "Uncompressed. The largest files, for audio editors.")
        }
    }
}
