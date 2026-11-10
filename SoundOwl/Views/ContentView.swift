import SoundOwlCore
import SwiftUI

/// The player window: one recording, restored as it plays. It exists only while something is
/// being listened to. Dropping another recording on it plays that one instead.
struct ContentView: View {
    @Environment(AppModel.self) private var app
    @State private var isDropTarget = false
    @State private var keyMonitor: Any?

    var body: some View {
        Group {
            if let preview = app.preview {
                ListenView(recording: preview)
                    .id(preview.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = AudioFiles.expand(urls).first else { return false }
            app.listen(to: url)
            return true
        } isTargeted: { isDropTarget = $0 }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: app.preview?.url, initial: true) { _, url in app.windows.show(recording: url) }
        .onAppear {
            installSpaceKey()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// Space plays and pauses; held down, it plays the original until released. A key monitor
    /// sees the release, which SwiftUI's shortcuts don't.
    private func installSpaceKey() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // Only in the main window, and never while typing.
            guard event.keyCode == 49, event.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask),
                  let window = event.window, window.isKeyWindow, !(window.firstResponder is NSText),
                  window.identifier?.rawValue == "main"
            else { return event }
            MainActor.assumeIsolated {
                guard AppModel.shared.preview != nil else { return }
                if event.type == .keyDown {
                    if !event.isARepeat { AppModel.shared.player.spacePressed() }
                } else {
                    AppModel.shared.player.spaceReleased()
                }
            }
            return nil
        }
    }
}
