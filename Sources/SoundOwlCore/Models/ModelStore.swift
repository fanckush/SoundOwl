import CryptoKit
import Foundation
import Observation

/// Gets the model onto this Mac once, and hands out the installed package after that.
///
/// The package is downloaded, checked against the pinned hash, unpacked into a staging folder,
/// checked file by file, and only then moved into place. An interrupted or damaged download never
/// leaves a half-installed model behind.
@MainActor @Observable
public final class ModelStore {
    public enum Phase: Equatable, Sendable {
        case checking
        case missing
        /// `fraction` is nil until the server reports a size.
        case downloading(fraction: Double?)
        case installing
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .checking
    public private(set) var package: ModelPackage?
    /// The last failure was about connectivity, so it is worth retrying once the network returns.
    public private(set) var failedOffline = false
    public let release: ModelRelease
    public let root: URL

    private var work: Task<Void, Never>?

    /// `~/Library/Application Support/SoundOwl/Models`, shared by the app and the command line.
    /// `SOUNDOWL_MODEL_ROOT` points it elsewhere (tests, a clean-machine check).
    public nonisolated static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["SOUNDOWL_MODEL_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL.applicationSupportDirectory.appending(path: "SoundOwl/Models")
    }

    public init(release: ModelRelease = .lavaSRv2, root: URL = ModelStore.defaultRoot) {
        self.release = release
        self.root = root
    }

    public var installDirectory: URL {
        Self.installDirectory(for: release, root: root)
    }

    public nonisolated static func installDirectory(for release: ModelRelease, root: URL = defaultRoot) -> URL {
        root.appending(path: "\(release.id)/\(release.packageVersion)")
    }

    /// The installed package, downloading and installing it first if it isn't there. For callers
    /// without a store of their own, like the command line.
    public nonisolated static func ensureInstalled(_ release: ModelRelease, root: URL = defaultRoot,
                                                   progress: @escaping @Sendable (Double?) -> Void = { _ in })
        async throws -> ModelPackage {
        let destination = installDirectory(for: release, root: root)
        if let package = try? installed(at: destination) { return package }
        return try await install(release, root: root, into: destination, progress: progress, verifying: {})
    }

    /// Uses the installed model, or starts downloading it.
    public func prepare() {
        if let installed = try? Self.installed(at: installDirectory) {
            package = installed
            phase = .ready
        } else {
            download()
        }
    }

    public func download() {
        guard work == nil else { return }
        package = nil
        phase = .downloading(fraction: nil)
        let release = release, root = root, destination = installDirectory
        work = Task {
            defer { work = nil }
            do {
                let installed = try await Self.install(release, root: root, into: destination) { fraction in
                    Task { @MainActor in
                        if case .downloading = self.phase { self.phase = .downloading(fraction: fraction) }
                    }
                } verifying: {
                    Task { @MainActor in self.phase = .installing }
                }
                package = installed
                phase = .ready
            } catch is CancellationError {
                phase = .missing
            } catch {
                failedOffline = Self.isConnectivity(error)
                phase = .failed(Self.describe(error))
            }
        }
    }

    public func cancel() {
        work?.cancel()
    }

    /// Deletes the installed model. SoundOwl downloads it again when it next needs it.
    public func remove() throws {
        cancel()
        package = nil
        phase = .missing
        let folder = root.appending(path: release.id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Work off the main actor

    /// A package counts as installed when its manifest loads and every file has the right size.
    /// Hashes were checked when it was installed.
    public nonisolated static func installed(at directory: URL) throws -> ModelPackage {
        let package = try ModelPackage(directory: directory)
        for (name, file) in package.manifest.files {
            let size = try FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)[.size] as? Int
            guard size == file.bytes else { throw EngineError.invalidModel("\(name) has the wrong size") }
        }
        return package
    }

    public nonisolated static func install(_ release: ModelRelease, root: URL, into destination: URL,
                                           progress: @escaping @Sendable (Double?) -> Void,
                                           verifying: @escaping @Sendable () -> Void) async throws -> ModelPackage {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appending(path: ".download-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        try await Downloader.download(release.downloadURL, to: archive, progress: progress)
        verifying()
        return try await install(release, root: root, into: destination, from: archive)
    }

    /// Checks a downloaded archive against `release` and moves its contents into `destination`.
    nonisolated static func install(_ release: ModelRelease, root: URL, into destination: URL,
                                    from archive: URL) async throws -> ModelPackage {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appending(path: ".staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        guard try sha256(of: archive) == release.sha256 else { throw InstallError.damaged }
        try unzip(archive, into: staging)
        let unpacked = staging.appending(path: release.id)
        let package = try ModelPackage(directory: unpacked)
        for (name, file) in package.manifest.files {
            guard try sha256(of: unpacked.appending(path: name)) == file.sha256 else { throw InstallError.damaged }
        }
        guard package.manifest.id == release.id, package.manifest.packageVersion == release.packageVersion else {
            throw InstallError.damaged
        }

        // The app and the command line can both be installing; the second to get here keeps the first's.
        let lock = try InstallLock(root: root)
        defer { lock.release() }
        if let existing = try? installed(at: destination) { return existing }

        // Swap in the new version, and drop any other version of this model.
        let modelFolder = destination.deletingLastPathComponent()
        if fm.fileExists(atPath: modelFolder.path) { try fm.removeItem(at: modelFolder) }
        try fm.createDirectory(at: modelFolder, withIntermediateDirectories: true)
        try fm.moveItem(at: unpacked, to: destination)
        return try ModelPackage(directory: destination)
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func unzip(_ archive: URL, into folder: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw InstallError.damaged }
    }

    /// An exclusive `flock` on `<root>/.install.lock`, held while a package is moved into place.
    private final class InstallLock {
        private let descriptor: Int32

        init(root: URL) throws {
            descriptor = open(root.appending(path: ".install.lock").path, O_RDWR | O_CREAT, 0o644)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            guard flock(descriptor, LOCK_EX) == 0 else {
                close(descriptor)
                throw CocoaError(.fileWriteUnknown)
            }
        }

        func release() {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    enum InstallError: LocalizedError {
        case damaged

        var errorDescription: String? {
            String(localized: "The download was damaged.")
        }
    }

    nonisolated static func isConnectivity(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .timedOut,
                .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code)
    }

    public nonisolated static func describe(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return String(localized: "You're offline. SoundOwl will try again when you're back online.")
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return String(localized: "The download server can't be reached right now.")
            case .badServerResponse:
                return String(localized: "The model isn't available for download right now.")
            default:
                break
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
