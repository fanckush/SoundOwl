import ArgumentParser
import Foundation
import SoundOwlCore

/// `soundowl`: restore recordings from the command line, with the same engine, model and default
/// settings as the app.
public enum SoundOwlCLI {
    /// Runs the command line with `arguments` (without the program name), then exits the process.
    public static func run(_ arguments: [String]) async -> Never {
        do {
            var command = try Root.parseAsRoot(arguments)
            if var command = command as? AsyncParsableCommand {
                try await command.run()
            } else {
                try command.run()
            }
            exit(0)
        } catch {
            Root.exit(withError: error)
        }
    }
}

struct Root: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "soundowl",
        abstract: "Make voices in recordings clearer, on this Mac.",
        discussion: """
        Restored copies are saved next to the originals as "Name (Restored).m4a"; originals are \
        never changed. Settings left out come from SoundOwl › Settings › Restoring.
        """,
        version: Root.version,
        subcommands: [Restore.self, ModelCommand.self],
        defaultSubcommand: Restore.self
    )

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
    }
}

extension ExportFormat: ExpressibleByArgument {}

// MARK: - restore

struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restore recordings (the default command).",
        discussion: "Prints the path of each restored copy on its own line, so the output can be piped."
    )

    @Argument(help: "Audio files, or folders of them.", completion: .file())
    var inputs: [String]

    @Flag(inversion: .prefixedNo, help: "Reduce steady background noise. (default: as set in SoundOwl)")
    var denoise: Bool?

    @Option(help: "Format of the restored copies: aac, alac or wav. (default: as set in SoundOwl)")
    var format: ExportFormat?

    @Option(name: .customLong("output-dir"), help: "Save the copies here instead of next to the originals.",
            completion: .directory)
    var outputDirectory: String?

    @Flag(name: .customLong("no-download"), help: "Fail instead of downloading the voice model if it's missing.")
    var noDownload = false

    @Flag(name: .shortAndLong, help: "Print only the restored files.")
    var quiet = false

    func run() async throws {
        let terminal = Terminal(quiet: quiet)
        let missing = inputs.filter { !FileManager.default.fileExists(atPath: $0) }
        for path in missing { terminal.error("\(path): No such file or folder.") }
        let urls = AudioFiles.expand(inputs.filter { !missing.contains($0) }.map { URL(fileURLWithPath: $0) })
        guard !urls.isEmpty else {
            if !missing.isEmpty { throw ExitCode.failure }
            throw ValidationError("No audio files in \(inputs.joined(separator: ", ")).")
        }

        let recipe = RecipeStore.load().overriding(denoise: denoise, format: format)
        var destination = RestoreDestination.nextToOriginal
        if let outputDirectory {
            let folder = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            destination = .folder(folder)
        }

        let package = try await ModelCommand.package(download: !noDownload, terminal: terminal)
        let model = try LavaSR(package: package)

        var failures = missing.count
        let total = urls.count + missing.count
        for (index, url) in urls.enumerated() {
            let label = urls.count > 1 ? "[\(index + 1)/\(urls.count)] \(url.lastPathComponent)" : url.lastPathComponent
            do {
                let output = try await FileRestore.run(url, recipe: recipe, to: destination, model: model) { stage, fraction in
                    terminal.progress(label, stage: stage, fraction: fraction)
                }
                terminal.clearProgress()
                print(output.path)
                fflush(stdout)
            } catch {
                terminal.clearProgress()
                failures += 1
                terminal.error("\(url.path): \(describe(error))")
            }
        }
        if failures > 0 {
            if total > 1 { terminal.error("\(failures) of \(total) files could not be restored.") }
            throw ExitCode.failure
        }
    }
}

// MARK: - model

struct ModelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model",
        abstract: "The voice model SoundOwl restores with.",
        subcommands: [Status.self, Download.self, Remove.self, Path.self],
        defaultSubcommand: Status.self
    )

    static var release: ModelRelease { RecipeStore.load().release }
    static var directory: URL { ModelStore.installDirectory(for: release) }
    static var size: String { ByteCountFormatter.string(fromByteCount: release.bytes, countStyle: .file) }

    /// The installed package, downloading it first when allowed.
    static func package(download: Bool, terminal: Terminal) async throws -> ModelPackage {
        if let package = try? ModelStore.installed(at: directory) { return package }
        guard download else {
            throw ValidationError("The voice model isn't downloaded yet. Run `soundowl model download`, or open SoundOwl once.")
        }
        terminal.note("Downloading the voice model, \(release.name) (\(size)). This only happens once.")
        do {
            let package = try await ModelStore.ensureInstalled(release) { fraction in
                terminal.progress("Downloading \(release.name)", fraction: fraction)
            }
            terminal.clearProgress()
            return package
        } catch {
            terminal.clearProgress()
            throw ValidationError(ModelStore.describe(error))
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show whether the model is installed.")

        func run() throws {
            if (try? ModelStore.installed(at: ModelCommand.directory)) != nil {
                print(
                    "\(ModelCommand.release.name), package \(ModelCommand.release.packageVersion) (\(ModelCommand.size)): installed"
                )
            } else {
                print("\(ModelCommand.release.name) (\(ModelCommand.size)): not downloaded")
            }
        }
    }

    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download the model now.")

        func run() async throws {
            _ = try await ModelCommand.package(download: true, terminal: Terminal(quiet: false))
            print(ModelCommand.directory.path)
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete the model; it downloads again when needed.")

        func run() throws {
            let folder = ModelCommand.directory.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        }
    }

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print where the model is installed.")

        func run() {
            print(ModelCommand.directory.path)
        }
    }
}

// MARK: - Output

/// Progress and messages on stderr, so stdout carries only results. Progress is drawn only on a
/// terminal, never into a pipe or a log.
struct Terminal: Sendable {
    let quiet: Bool
    private var interactive: Bool { !quiet && isatty(STDERR_FILENO) != 0 }

    func progress(_ label: String, stage: FileRestore.Stage, fraction: Double) {
        let verb = switch stage {
        case .decoding: "reading"
        case .restoring: "restoring"
        case .saving: "saving"
        }
        progress("\(label)  \(verb)", fraction: fraction)
    }

    func progress(_ label: String, fraction: Double?) {
        guard interactive else { return }
        let percent = fraction.map { String(format: " %3.0f%%", $0 * 100) } ?? ""
        write("\r\u{1B}[K\(label)\(percent)")
    }

    func clearProgress() {
        if interactive { write("\r\u{1B}[K") }
    }

    func note(_ message: String) {
        if !quiet { write(message + "\n") }
    }

    func error(_ message: String) {
        write("soundowl: \(message)\n")
    }

    private func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

func describe(_ error: Error) -> String {
    if let error = error as? LocalizedError, let description = error.errorDescription { return description }
    return error.localizedDescription
}
