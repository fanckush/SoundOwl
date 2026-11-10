import Foundation
import UniformTypeIdentifiers

/// Turns whatever was dropped or opened into the list of files to restore.
public enum AudioFiles {
    /// Expands folders (recursively, audio files only) and keeps files that were named directly,
    /// even ones that turn out to be unreadable, so each gets its own explanation. Files inside a
    /// folder come in Finder order: "Part 2" before "Part 10".
    public static func expand(_ urls: [URL]) -> [URL] {
        var out = [URL]()
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                out += contents(of: url)
            } else {
                out.append(url)
            }
        }
        var seen = Set<URL>()
        return out.filter { seen.insert($0.standardizedFileURL).inserted }
    }

    public static func isAudio(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
    }

    private static func contents(of folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && isAudio($0) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
