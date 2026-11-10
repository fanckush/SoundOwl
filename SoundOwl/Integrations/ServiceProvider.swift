import AppKit

/// Finder's "Restore with SoundOwl" (declared under NSServices in Info.plist). macOS launches
/// SoundOwl if needed and hands over the selected files; each is restored next to its original,
/// with progress in the owl's panel and no window.
final class ServiceProvider: NSObject {
    @objc func restoreFiles(_ pasteboard: NSPasteboard, userData _: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = String(localized: "Select one or more recordings in Finder first.") as NSString
            return
        }
        MainActor.assumeIsolated { AppModel.shared.restore(urls) }
    }
}
