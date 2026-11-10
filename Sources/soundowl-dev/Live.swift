import AppKit
import Foundation
import SoundOwlCore
import SoundOwlLive

/// `soundowl-dev live --bundle ID | --pid N [--seconds S] [--right-ms 128]`
///
/// Restores one app's sound as it plays, headless, and prints what the session measures once a
/// second. With `afplay call.m4a &` and `--pid $!` it is a repeatable test of the whole live path.
/// The first run asks for Screen & System Audio Recording, on behalf of the terminal app.
enum LiveCommand {
    @MainActor static func run() throws {
        let seconds = Double(option("--seconds") ?? "30") ?? 30
        var settings = LiveSettings.standard
        if let right = option("--right-ms").flatMap(Int.init) { settings.after = LiveSettings.samples(milliseconds: right) }
        if let core = option("--core-ms").flatMap(Int.init) { settings.core = LiveSettings.samples(milliseconds: core) }

        let target: LiveSession.Target
        if let pid = option("--pid").flatMap(pid_t.init) {
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                ?? AudioProcesses.all().first { $0.pid == pid }?.bundleID ?? "pid.\(pid)"
            target = .init(bundleID: bundleID, pid: pid)
        } else if let bundle = option("--bundle") {
            target = .init(bundleID: bundle)
        } else {
            print("Processes with audio right now:")
            for p in AudioProcesses.all().sorted(by: { ($0.bundleID ?? "") < ($1.bundleID ?? "") }) {
                print("  \(p.isPlaying ? "▶" : " ") \(p.pid)\t\(p.bundleID ?? "?")")
            }
            fail("usage: soundowl-dev live --bundle ID | --pid N [--seconds S] [--core-ms 32] [--right-ms 128]")
        }

        let model = try LavaSR(package: ModelPackage(directory: modelDirectory), intraOpThreads: settings.threads)
        let session = LiveSession(model: model, target: target, settings: settings) { state in
            print("state: \(state)")
        }
        let started = Date.now
        let cpuStart = cpuSeconds()
        session.start()
        signal(SIGINT) { _ in exit(130) } // the private tap dies with the process
        print("If macOS asks, allow your terminal to record system audio. Starting…")
        while Date.now.timeIntervalSince(started) < seconds {
            Thread.sleep(forTimeInterval: 1)
            guard let s = session.stats() else { continue }
            let cpu = (cpuSeconds() - cpuStart) / Date.now.timeIntervalSince(started)
            print(String(
                format: "%5.0fs  %@ @ %.0f Hz  latency %.0f ms  %@  cutoff %d Hz  fallback %.1f%%  restarts %d  hop %.1f/%.1f ms  cpu %.2f cores",
                Date.now.timeIntervalSince(started),
                s.output,
                s.sampleRate,
                s.latency * 1000,
                s.isMusic ? "music, untouched" : s.isAlreadyClear ? "full-band, untouched" : s
                    .isListening ? "listening…" : "restoring",
                s.cutoff,
                s.fallbackFraction * 100,
                s.restarts,
                s.lastHopMs,
                s.worstHopMs,
                cpu
            ))
        }
        session.stopAndWait()
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
