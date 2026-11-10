import SoundOwlCore
import SwiftUI

/// Listening to one recording, restored as it plays. Flip to the original to hear the difference;
/// save a restored copy if you want one.
struct ListenView: View {
    @Environment(AppModel.self) private var app
    @Bindable var recording: Recording

    private var player: Player { app.player }

    var body: some View {
        if case .failed(let message) = recording.phase {
            ContentUnavailableView {
                Label(recording.name, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Listen to Another…") { app.chooseRecordingToListen() }
            }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !recording.chapters.isEmpty {
                HStack {
                    Spacer()
                    chapterMenu
                }
            }

            VStack(spacing: 14) {
                WaveformView(peaks: recording.peaks, position: player.position, duration: recording.duration) {
                    player.seek(to: $0)
                }
                // The waveform takes whatever room the window has.
                .frame(minHeight: 100, maxHeight: .infinity)
                .overlay {
                    if recording.peaks.isEmpty {
                        ProgressView(value: preparingFraction)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 240)
                    }
                }
                transport
            }
            .padding(18)
            .soundOwlSurface()

            footer
        }
        .padding(24)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
        // What the recording is goes under its name in the title bar.
        .onChange(of: recording.details, initial: true) { _, details in app.windows.show(subtitle: details) }
    }

    // MARK: - Parts

    private var chapterMenu: some View {
        Menu {
            ForEach(recording.chapters, id: \.self) { chapter in
                Button {
                    player.seek(to: chapter.start)
                } label: {
                    Text("\(chapter.title)  \(Format.duration(chapter.start))")
                }
            }
        } label: {
            Label(currentChapter?.title ?? String(localized: "Chapters"), systemImage: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var currentChapter: Recording.Chapter? {
        recording.chapters.last { $0.start <= player.position + 0.5 }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { player.skip(by: -15) } label: { Image(systemName: "gobackward.15").font(.title3) }
                .buttonStyle(.borderless)
                .help("Back 15 seconds (←)")
                .disabled(recording.peaks.isEmpty)

            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying || player.isWaiting ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .background(Circle().fill(.quaternary))
            .disabled(recording.peaks.isEmpty)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .help("Play or pause (Space)")

            Button { player.skip(by: 15) } label: { Image(systemName: "goforward.15").font(.title3) }
                .buttonStyle(.borderless)
                .help("Forward 15 seconds (→)")
                .disabled(recording.peaks.isEmpty)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.duration(player.position)) / \(Format.duration(recording.duration))")
                    .monospacedDigit()
                if let statusLine {
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 4)

            Spacer()

            speedMenu

            Picker("Listen to", selection: Bindable(player).track) {
                Text("Original").tag(Player.Track.original)
                Text("Restored").tag(Player.Track.restored)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .overlay {
                if player.isPeeking {
                    Capsule().strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .help("Hold Space to hear the original")
        }
    }

    private var speedMenu: some View {
        Menu(Player.label(for: player.rate)) {
            Picker("Speed", selection: Bindable(player).rate) {
                ForEach(Player.rates, id: \.self) { Text(Player.label(for: $0)).tag($0) }
            }
            .pickerStyle(.inline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .monospacedDigit()
        .help("Playback speed")
    }

    /// What's happening, or else how to compare.
    private var statusLine: String? {
        switch recording.phase {
        case .opening, .preparing: return String(localized: "Reading the file…")
        case .failed: return nil
        case .restoring, .restored:
            if app.models.phase != .ready, player.isWaiting { return String(localized: "Waiting for the voice model…") }
            if player.isWaiting { return String(localized: "Restoring this part…") }
            return player
                .isPeeking ? String(localized: "Playing the original") : String(localized: "Hold Space to hear the original")
        }
    }

    private var preparingFraction: Double {
        if case .preparing(let fraction) = recording.phase { return fraction }
        return 0
    }

    private var footer: some View {
        HStack {
            Button {
                app.showSettings(.model)
            } label: {
                Label("Restored on this Mac · \(app.models.release.name)", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("About the voice model")

            Spacer()
            Toggle("Reduce Noise", isOn: $recording.denoise)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Removes steady hum, hiss and room noise. Leave it off if the voice starts to sound thin.")
                .onChange(of: recording.denoise) { _, on in app.recipe.denoise = on }
                .padding(.trailing, 12)
            saveButton
        }
    }

    @ViewBuilder
    private var saveButton: some View {
        if let job = app.previewSave {
            HStack(spacing: 8) {
                ProgressRing(fraction: job.fraction, tint: .accentColor).frame(width: 16, height: 16)
                Text("Saving a restored copy…").foregroundStyle(.secondary)
                Button("Cancel") { app.service.cancel(job) }
            }
        } else if let saved = recording.savedURL {
            Button("Show in Finder", systemImage: "folder") { app.savePreview() }
                .help("Saved as “\(saved.lastPathComponent)” in \(saved.deletingLastPathComponent().lastPathComponent)")
        } else {
            Button("Save Restored Copy") { app.savePreview() }
                .disabled(recording.session == nil)
                .help("Saves “\(recording.name) (Restored)” next to the original (⌘S)")
        }
    }
}
