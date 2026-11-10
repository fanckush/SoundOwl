import AppKit
import SoundOwlCore
import SoundOwlLive
import SwiftUI

/// The panel's measurements, so everything lines up: text and icons start `inset` from the
/// edge, hover highlights reach to `highlightInset`, as in the system's own menu bar menus.
enum PanelMetrics {
    static let width: CGFloat = 320
    static let inset: CGFloat = 14
    static let highlightInset: CGFloat = 5
    static let radius: CGFloat = 12
    static let iconSize: CGFloat = 24
    static let iconGap: CGFloat = 8
    /// Where text after an icon starts.
    static let textAfterIcon = inset + iconSize + iconGap
    /// Room taken by a row's disclosure arrow, right of its switch.
    static let disclosure: CGFloat = 14 + 6
    /// Changes of height: always through `withAnimation(resize)`. The window follows with the
    /// same length and curve (`StatusItemController.fit`).
    static let resizeDuration = 0.22
    static let resize = Animation.easeInOut(duration: resizeDuration)
}

/// What the owl opens: voices on calls, recordings, and the way out. Everything SoundOwl does
/// starts here.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var app
    @State private var isDropTarget = false
    /// Told the content's height as it changes, frame by frame while it animates.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SoundOwl")
                .font(.headline)
                .padding(.horizontal, PanelMetrics.inset)
                .padding(.top, 10)
                .padding(.bottom, 4)
            if !app.onboarded {
                WelcomeCard()
                    .padding(.horizontal, PanelMetrics.inset)
                    .padding(.vertical, 4)
            }
            if app.models.phase != .ready {
                ModelStatusView(compact: true)
                    .padding(.horizontal, PanelMetrics.inset)
                    .padding(.vertical, 4)
            }
            PanelSeparator()
            LiveSection()
            PanelSeparator()
            RecordingsSection()
            PanelSeparator()
            MenuRow("SoundOwl Settings…", shortcut: "⌘,") { app.showSettings(.general) }
                .keyboardShortcut(",")
            MenuRow("Quit SoundOwl", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .padding(.bottom, PanelMetrics.highlightInset)
        }
        .frame(width: PanelMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            // After this layout pass, not inside it.
            DispatchQueue.main.async { onHeightChange(height) }
        }
        // The material, corners and edge are the window's (`PanelBackground`).
        .overlay {
            if isDropTarget {
                DropOverlay()
                    .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.radius, style: .continuous))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        // Recordings dropped anywhere on the panel become clear copies, as on the owl.
        .dropDestination(for: URL.self) { urls, _ in
            app.restore(urls)
            return true
        } isTargeted: { isDropTarget = $0 }
    }
}

/// Shown over the whole panel while recordings are dragged over it.
private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            RoundedRectangle(cornerRadius: PanelMetrics.radius - 4, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(4)
            VStack(spacing: 4) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .padding(.bottom, 4)
                Text("Drop to Make Clear Copies").font(.headline)
                Text("Saved next to the originals").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - First run

/// Says once what SoundOwl is and where it lives, then gets out of the way.
private struct WelcomeCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 6) {
            Text("SoundOwl lives up here").font(.callout.weight(.semibold))
            Text(
                "Switch on the app you call with and voices come through clearly. Drop recordings here, or on the owl, for clear copies."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Toggle("Open at Login", isOn: $app.openAtLogin)
                .toggleStyle(.checkbox)
                .font(.callout)
                .padding(.top, 2)
            HStack {
                Button("Hear a Sample") {
                    app.menuBar.close()
                    app.trySample()
                }
                Spacer()
                Button("Got It") {
                    withAnimation(PanelMetrics.resize) { app.onboarded = true }
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}

// MARK: - Live

private struct LiveSection: View {
    @Environment(AppModel.self) private var app
    private var live: LiveController { app.live }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Voices on Calls")
            if live.rows.isEmpty {
                Text("Start a call or video, then switch its app on here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, PanelMetrics.inset)
                    .padding(.vertical, 4)
            } else {
                ForEach(live.rows) { row in
                    LiveAppRow(row: row, isExpanded: live.expanded == row.id && row.isOn) {
                        withAnimation(PanelMetrics.resize) {
                            live.expanded = live.expanded == row.id ? nil : row.id
                        }
                    }
                }
            }
            if let notice = live.notice {
                LiveNotice(notice: notice)
                    .padding(.horizontal, PanelMetrics.inset)
                    .padding(.vertical, 4)
            }
        }
    }
}

/// An app, like a device in the Bluetooth menu: its switch, and its options folded away.
private struct LiveAppRow: View {
    @Environment(AppModel.self) private var app
    let row: LiveController.Row
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if row.isOn {
                Disclosure(isExpanded: isExpanded) {
                    LiveOptionsView(id: row.id)
                        .padding(.leading, PanelMetrics.textAfterIcon)
                        .padding(.trailing, PanelMetrics.inset + PanelMetrics.disclosure)
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: PanelMetrics.iconGap) {
            Image(nsImage: AppIcons.icon(for: row.id))
                .resizable()
                .frame(width: PanelMetrics.iconSize, height: PanelMetrics.iconSize)
                .opacity(row.isRunning ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name).lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Toggle(row.name, isOn: Binding(get: { row.isOn }, set: { on in
                withAnimation(PanelMetrics.resize) { app.live.setOn(on, for: row) }
            }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            Button(action: toggleExpanded) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: PanelMetrics.disclosure - 6, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .focusEffectDisabled()
            .opacity(row.isOn ? 1 : 0)
            .disabled(!row.isOn)
            .help(isExpanded ? "Hide Options" : "Show Options")
            .accessibilityLabel(Text(isExpanded ? "Hide options for \(row.name)" : "Show options for \(row.name)"))
        }
        .padding(.horizontal, PanelMetrics.inset)
        .frame(minHeight: 38)
    }

    private var detail: String? {
        switch row.status {
        case .idle: nil
        case .playing: String(localized: "Playing")
        case .notOpen: String(localized: "Starts when you open it")
        case .waiting: String(localized: "Starts when it plays sound")
        case .starting: String(localized: "Starting…")
        case .waitingForModel: String(localized: "Waiting for the voice model…")
        case .listening: String(localized: "Listening…")
        case .restoring: String(localized: "Restoring voices")
        case .alreadyClear: String(localized: "Already clear, left as is")
        case .music: String(localized: "Music, left as is")
        case .paused: String(localized: "Paused")
        case .failed: String(localized: "Stopped")
        }
    }
}

/// Content that unfolds downward: always laid out, revealed by animating its visible height
/// from nothing to its full height, so the rows below and the window's edge glide with it.
private struct Disclosure<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .frame(height: isExpanded ? height : 0, alignment: .top)
            .clipped()
            .opacity(isExpanded ? 1 : 0)
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
    }
}

/// One app's options, inline under its row: how long to wait for clarity, and what to restore.
private struct LiveOptionsView: View {
    @Environment(AppModel.self) private var app
    let id: String

    var body: some View {
        let options = app.live.options(for: id)
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Slider(value: Binding(
                    get: { Double(options.balance.rawValue) },
                    set: { value in
                        var new = options
                        new.balance = LiveSettings.Balance(rawValue: Int(value.rounded())) ?? .balanced
                        app.live.set(new, for: id)
                    }
                ), in: 0...2, step: 1) {
                    Text("Delay")
                } minimumValueLabel: {
                    Text("Faster")
                } maximumValueLabel: {
                    Text("Clearer")
                }
                .labelsHidden()
                .controlSize(.mini)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Text(Self.delay(options.balance))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            OptionRow("Reduce Background Noise", isOn: options.choices.reduceNoise) { on in
                var new = options
                new.choices.reduceNoise = on
                app.live.set(new, for: id)
            }
            OptionRow("Leave Clear Sound As Is", isOn: options.choices.leaveClearSoundAlone) { on in
                var new = options
                new.choices.leaveClearSoundAlone = on
                app.live.set(new, for: id)
            }
            .help("Sound that already has its full range plays untouched. Music always does.")
        }
    }

    private static func delay(_ balance: LiveSettings.Balance) -> String {
        switch balance {
        case .faster: String(localized: "About 0.13 s behind, best for lip sync")
        case .balanced: String(localized: "About 0.19 s behind")
        case .clearer: String(localized: "About 0.26 s behind, clearest voices")
        }
    }
}

/// A label and a small switch, as in Control Center's own options.
private struct OptionRow: View {
    let title: LocalizedStringKey
    let isOn: Bool
    let set: (Bool) -> Void

    init(_ title: LocalizedStringKey, isOn: Bool, set: @escaping (Bool) -> Void) {
        self.title = title
        self.isOn = isOn
        self.set = set
    }

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            Text(title).font(.callout)
        }
        .toggleStyle(TrailingSwitch())
    }
}

/// Label on the left, switch on the right edge.
private struct TrailingSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }
}

/// The one thing holding every app back, with what to do about it.
private struct LiveNotice: View {
    @Environment(AppModel.self) private var app
    let notice: LiveController.Notice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    switch notice {
                    case .speakers:
                        Button("Use Speakers Anyway") { app.live.useSpeakersAnyway() }
                    case .permission:
                        Button("Open Privacy Settings") {
                            app.menuBar.close()
                            app.live.openPrivacySettings()
                        }
                        Button("Try Again") { app.live.retry() }
                    case .failed:
                        Button("Try Again") { app.live.retry() }
                    case .narrowOutput:
                        EmptyView()
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
    }

    private var text: String {
        switch notice {
        case .speakers:
            String(
                localized: "Paused while sound plays on speakers, so the others on the call don't hear an echo. Put on headphones."
            )
        case .permission:
            String(localized: "SoundOwl needs permission to hear other apps. Turn it on under System Audio Recording Only.")
        case .narrowOutput:
            String(
                localized: "Your headset is in call mode, which can't play the restored voice. Use the Mac's microphone to switch it back."
            )
        case .failed(let app, let message):
            String(localized: "\(app): \(message)")
        }
    }

    private var symbol: String {
        switch notice {
        case .speakers, .narrowOutput: "headphones"
        case .permission: "lock"
        case .failed: "exclamationmark.triangle"
        }
    }
}

// MARK: - Recordings

private struct RecordingsSection: View {
    @Environment(AppModel.self) private var app

    private var jobs: [RestoreService.Job] { app.service.jobs.filter { $0.previewID == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Recordings")
            if !jobs.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(jobs) { JobRow(job: $0) }
                    }
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
            }
            MenuRow("Make Clear Copies…", detail: "Or drop recordings here or on the owl") {
                app.chooseRecordingsToRestore()
            }
            MenuRow("Listen to a Recording…") { app.chooseRecordingToListen() }
        }
    }
}

/// One copy being made: what, how far, and where it went.
struct JobRow: View {
    @Environment(AppModel.self) private var app
    let job: RestoreService.Job

    var body: some View {
        HStack(spacing: PanelMetrics.iconGap) {
            icon
                .frame(width: 18, height: 18)
                .frame(width: PanelMetrics.iconSize)
            VStack(alignment: .leading, spacing: 0) {
                Text(job.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if case .done(let url) = job.state {
                Button {
                    app.menuBar.close()
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            } else if !job.isFinished {
                Button {
                    app.service.cancel(job)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Stop restoring this file")
            }
        }
        .padding(.horizontal, PanelMetrics.inset)
        .frame(minHeight: 38)
        .help(job.isFinished ? "" : subtitle)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch job.state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .queued:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        default:
            ProgressRing(fraction: job.fraction, tint: .accentColor)
        }
    }

    private var subtitle: String {
        switch job.state {
        case .queued: String(localized: "Waiting")
        case .reading: String(localized: "Reading…")
        case .restoring(let fraction):
            String(localized: "Restoring… \(fraction.formatted(.percent.precision(.fractionLength(0))))")
        case .saving: String(localized: "Saving…")
        case .done(let url):
            if url.deletingLastPathComponent() == job.source.deletingLastPathComponent() {
                String(localized: "Saved next to the original")
            } else {
                String(localized: "Saved in \(url.deletingLastPathComponent().lastPathComponent)")
            }
        case .failed(let message): message
        case .cancelled: String(localized: "Stopped")
        }
    }
}

extension RestoreService.Job {
    /// How far along the whole job is, for one progress ring.
    var fraction: Double {
        switch state {
        case .queued: 0
        case .reading(let f): f * 0.1
        case .restoring(let f): 0.1 + f * 0.8
        case .saving(let f): 0.9 + f * 0.1
        case .done, .failed, .cancelled: 1
        }
    }
}

// MARK: - Pieces

/// A group's name, as in the system's menus: small, semibold, quiet.
private struct SectionHeader: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, PanelMetrics.inset)
            .padding(.top, 2)
            .padding(.bottom, 2)
    }
}

/// Between groups: inset like a menu's separator.
private struct PanelSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, PanelMetrics.inset)
            .padding(.vertical, 5)
    }
}

/// A menu item: full width, a gray highlight under the pointer, text where all text starts.
struct MenuRow: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    var shortcut: String?
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, shortcut: String? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                    if let detail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, PanelMetrics.inset - PanelMetrics.highlightInset)
            .padding(.vertical, 3)
            .frame(minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(.horizontal, PanelMetrics.highlightInset)
        .onHover { isHovered = $0 }
    }
}

struct ProgressRing: View {
    var fraction: Double
    var tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.5)
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

/// App icons by bundle ID, for apps that aren't running too.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let icon = cache[bundleID] { return icon }
        let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
        cache[bundleID] = icon
        return icon
    }
}
