import Foundation

/// Where a restored copy goes.
public enum RestoreDestination: Sendable, Hashable {
    /// Next to the original, as `Name (Restored).m4a`: the default everywhere.
    case nextToOriginal
    case folder(URL)

    /// The folder a copy of `source` is written to. When the original's folder can't be written
    /// to (a read-only volume, a shared folder), the copy goes to Downloads, and the returned URL
    /// says so.
    public func folder(for source: URL) -> URL {
        switch self {
        case .folder(let folder):
            return folder
        case .nextToOriginal:
            let folder = source.deletingLastPathComponent()
            if FileManager.default.isWritableFile(atPath: folder.path) { return folder }
            return URL.downloadsDirectory
        }
    }
}

/// Restores one file start to finish, with no UI: decode, restore every chunk, write the copy.
/// The command line runs this; the app runs the same steps through its queue so it can put the
/// file you're listening to first.
public enum FileRestore {
    public enum Stage: Sendable {
        case decoding
        case restoring
        case saving
    }

    /// Returns the restored file. `progress` gets the stage and how far into it (0...1).
    public static func run(_ url: URL, recipe: Recipe, to destination: RestoreDestination = .nextToOriginal,
                           model: LavaSR,
                           progress: @escaping @Sendable (Stage, Double) -> Void = { _, _ in }) async throws -> URL {
        let source = try await AudioSource(url: url)
        let session = try RestorationSession(source: source)
        session.denoise = recipe.denoise
        try session.prepare { progress(.decoding, $0) }
        progress(.restoring, 0)
        while let chunk = session.nextChunk() {
            try Task.checkCancellation()
            try session.restore(chunk: chunk, with: model)
            progress(.restoring, session.restoredFraction)
        }
        guard let store = session.completedOutput() else { throw CocoaError(.fileWriteUnknown) }
        progress(.saving, 0)
        return try await Exporter.export(store, source: url, to: destination.folder(for: url), format: recipe.format) {
            progress(.saving, $0)
        }
    }
}
