#if DEBUG
    import AppKit
    import SwiftUI

    /// Development aid: with SOUNDOWL_SNAPSHOT_DIR set, the app writes a PNG of each of its windows
    /// every second. Lets a script or CI see the UI without screen-recording permission.
    @MainActor
    enum DebugSnapshots {
        static func startIfRequested() {
            // SOUNDOWL_DEBUG_ACTION=settings:<tab> opens that tab (general, live, recordings, …).
            if let action = ProcessInfo.processInfo.environment["SOUNDOWL_DEBUG_ACTION"], action.hasPrefix("settings") {
                let name = action.split(separator: ":").dropFirst().first.map(String.init) ?? "live"
                let tab = SettingsTab.allCases.first { name == "\($0)" } ?? .live
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    AppModel.shared.showSettings(tab)
                }
            }
            let action = ProcessInfo.processInfo.environment["SOUNDOWL_DEBUG_ACTION"] ?? ""
            // SOUNDOWL_DEBUG_ACTION=sample opens the sample in the player; SOUNDOWL_SEEK=<seconds>
            // then moves the playhead there (for screenshots).
            if action == "sample" {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    AppModel.shared.trySample()
                    guard let seek = ProcessInfo.processInfo.environment["SOUNDOWL_SEEK"].flatMap(Double.init) else { return }
                    try? await Task.sleep(for: .seconds(2))
                    AppModel.shared.player.seek(to: seek)
                }
            }
            // SOUNDOWL_DEBUG_ACTION=options:<bundle ID> opens that app's options in the panel.
            if action.hasPrefix("options:") {
                AppModel.shared.live.expanded = String(action.dropFirst("options:".count))
            }
            guard let path = ProcessInfo.processInfo.environment["SOUNDOWL_SNAPSHOT_DIR"] else { return }
            let folder = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // SOUNDOWL_DEBUG_ACTION=animate:<bundle ID> opens and closes that app's options and
            // films the panel every 30 ms, for judging the animation frame by frame.
            if action.hasPrefix("animate:") {
                film(String(action.dropFirst("animate:".count)), into: folder)
                return
            }
            Task {
                while true {
                    try? await Task.sleep(for: .seconds(1))
                    for window in NSApp.windows where window.isVisible {
                        guard let view = window.contentView?.superview ?? window.contentView,
                              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                        view.cacheDisplay(in: view.bounds, to: rep)
                        let name = (window.identifier?.rawValue ?? window.title).replacingOccurrences(of: "/", with: "-")
                        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name).png"))
                        // Some views (glass sidebars) don't draw into a cached bitmap; list what tables hold.
                        let tables = tables(in: view).map { "\(type(of: $0)) rows=\($0.numberOfRows) frame=\($0.frame)" }
                            + (window.toolbar?.items ?? [])
                            .map { "toolbar \($0.itemIdentifier.rawValue) '\($0.label)' enabled=\($0.isEnabled)" }
                            + ["key=\(window.isKeyWindow)"]
                        try? tables.joined(separator: "\n").write(
                            to: folder.appending(path: "\(name).txt"),
                            atomically: true,
                            encoding: .utf8
                        )
                    }
                }
            }
        }

        private static func film(_ id: String, into folder: URL) {
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                var log: [String] = []
                for (name, value) in [("open", Optional(id)), ("close", nil)] {
                    withAnimation(PanelMetrics.resize) { AppModel.shared.live.expanded = value }
                    let start = Date.now
                    for frame in 0..<12 {
                        guard let panel = NSApp.windows.first(where: { $0 is MenuPanel }),
                              let view = panel.contentView else { continue }
                        // The card: what's on screen.
                        let shown = view.subviews.first ?? view
                        if ProcessInfo.processInfo.environment["SOUNDOWL_FILM_PNG"] != nil,
                           let rep = shown.bitmapImageRepForCachingDisplay(in: shown.bounds) {
                            shown.cacheDisplay(in: shown.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?
                                .write(to: folder.appending(path: "\(name)-\(String(format: "%02d", frame)).png"))
                        }
                        let card = view.subviews.first
                        let hosted = card?.subviews.last?.frame ?? .zero
                        log.append(String(format: "%@ %02d t=%3.0f ms window h=%.0f card h=%.0f hosting y=%.0f h=%.0f", name,
                                          frame, Date.now.timeIntervalSince(start) * 1000, panel.frame.height,
                                          card?.frame.height ?? 0, hosted.minY, hosted.height))
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                try? log.joined(separator: "\n").write(to: folder.appending(path: "film.txt"), atomically: true, encoding: .utf8)
            }
        }

        private static func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
    }
#endif
