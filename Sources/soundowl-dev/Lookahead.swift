import Foundation
import SoundOwlCore

/// `lookahead`: how good can live restoring be when it may only wait a few tens of milliseconds
/// for the future? Streams each clip through `StreamRestorer` one hop at a time, as live restoring
/// would, and compares the result with today's offline restore (30 s chunks, 1 s context).
///
///   swift run -c release soundowl-dev lookahead clips/*.wav --out build/lookahead
///     [--core-ms 32,64] [--right-ms 0,32,64,96,128,256] [--left-ms 512] [--crossfade-ms 0,16]
///     [--denoise-modes off,on] [--threads 2] [--cutoff-seconds 3] [--load N] [--no-audio]
///
/// Writes, per clip, original48.wav, reference.wav and one WAV per setting, plus results.csv for
/// all of them, and prints which settings meet the bar for live restoring (docs/engine.md).
@MainActor
enum Lookahead {
    struct Setting: Hashable {
        var coreMs: Int, rightMs: Int, leftMs: Int, crossfadeMs: Int
        var denoise: Bool
        var threads: Int

        var name: String { "C\(coreMs)-R\(rightMs)-L\(leftMs)-x\(crossfadeMs)-dn\(denoise ? 1 : 0)-t\(threads)" }
        /// Waiting for the hop to fill plus the look-ahead, before any compute.
        var bufferMs: Int { coreMs + rightMs }
    }

    struct Result {
        var clip: String
        var setting: Setting
        var highBand: Quality.HighBand
        var seam: Double
        var hopP50: Double, hopP99: Double, hopMax: Double, coldFirstHop: Double
        var cpuCores: Double
        var cutoffOnline: Double, cutoffOffline: Double
        var fullBandLevel: Double

        var hopMs: Double { Double(setting.coreMs) }
        var headroom: Double { hopMs / max(hopP99, 1e-6) }
        /// Buffering, the slowest typical hop, and ~25 ms of device I/O.
        var totalMs: Double { Double(setting.bufferMs) + hopP99 + 25 }
    }

    /// The bar from the plan; denoise is judged on speed alone.
    static func failures(_ r: Result) -> [String] {
        var out = [String]()
        if r.totalMs > 180 { out.append(String(format: "latency %.0f ms", r.totalMs)) }
        if r.headroom < 2 { out.append(String(format: "headroom %.1fx", r.headroom)) }
        if r.cpuCores > 1 { out.append(String(format: "CPU %.2f cores", r.cpuCores)) }
        if r.coldFirstHop > 1000 { out.append(String(format: "cold start %.0f ms", r.coldFirstHop)) }
        if !r.setting.denoise {
            if r.highBand.lsd > 2 { out.append(String(format: "LSD %.2f dB", r.highBand.lsd)) }
            if r.seam > 3 { out.append(String(format: "seams %.1f dB", r.seam)) }
            if abs(r.cutoffOnline - r.cutoffOffline) > 500 {
                out.append(String(format: "cutoff %.0f vs %.0f Hz", r.cutoffOnline, r.cutoffOffline))
            }
        }
        return out
    }

    static func run() throws {
        let outDir = URL(fileURLWithPath: option("--out") ?? "build/lookahead")
        let cores = milliseconds(option("--core-ms") ?? "32,64", grid: true)
        let rights = milliseconds(option("--right-ms") ?? "0,32,64,96,128,256", grid: true)
        let lefts = milliseconds(option("--left-ms") ?? "512", grid: true)
        let fades = milliseconds(option("--crossfade-ms") ?? "0,16", grid: false)
        let denoises = (option("--denoise-modes") ?? "off").split(separator: ",").map { $0 == "on" }
        let threads = (option("--threads") ?? "2").split(separator: ",").compactMap { Int($0) }
        let cutoffSeconds = Double(option("--cutoff-seconds") ?? "3") ?? 3
        let load = Int(option("--load") ?? "0") ?? 0
        let writeAudio = !flag("--no-audio")
        let clips = arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        guard !clips.isEmpty else { fail("usage: soundowl-dev lookahead <clips…> [--out dir] [options]; see Lookahead.swift") }

        var settings = [Setting]()
        for c in cores { for r in rights { for l in lefts { for x in fades where x <= r {
            for d in denoises { for t in threads {
                settings.append(Setting(coreMs: c, rightMs: r, leftMs: l, crossfadeMs: x, denoise: d, threads: t))
            } }
        } } } }

        // Competing CPU load runs in other processes, so it does not count towards our CPU time.
        let burners = (0..<load).map { _ in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
            p.standardOutput = FileHandle.nullDevice
            try? p.run()
            return p
        }
        defer { burners.forEach { $0.terminate() } }

        let reference = loadModel()
        var results = [Result]()
        for clipURL in clips {
            let clip = clipURL.deletingPathExtension().lastPathComponent
            let clipDir = outDir.appending(path: clip)
            try FileManager.default.createDirectory(at: clipDir, withIntermediateDirectories: true)

            let decoded = try AudioIO.read(clipURL)
            let mono = mix(decoded.channels)
            let x16 = try AudioIO.resample(mono, from: decoded.sampleRate, to: Double(LavaSR.inputSampleRate))
            let fullBandLevel = Quality.highBandLevel(mono, sampleRate: decoded.sampleRate)
            let offlineCutoff = Bandwidth.cutoff(for: Array(x16.prefix(120 * LavaSR.inputSampleRate)))
            let onlineCutoff = Bandwidth.cutoff(for: Array(x16.prefix(Int(cutoffSeconds * Double(LavaSR.inputSampleRate)))))
            // Compare only where both restorations generate the band.
            let metricCutoff = max(offlineCutoff, onlineCutoff) + 85
            print(String(format: "%@: %.1f s at %.0f Hz, cutoff %.0f Hz offline / %.0f Hz online, 8.5–11 kHz at %.1f dB",
                         clip, Double(x16.count) / 16_000, decoded.sampleRate, offlineCutoff, onlineCutoff, fullBandLevel))

            if writeAudio {
                let original48 = try AudioIO.resample(mono, from: decoded.sampleRate, to: Double(LavaSR.outputSampleRate))
                try AudioIO.writeWAV([original48], sampleRate: 48_000, to: clipDir.appending(path: "original48.wav"))
            }
            var references = [Bool: [Float]]()
            for denoise in Set(denoises) {
                var restorer = Restorer(model: reference)
                restorer.cutoff = offlineCutoff
                restorer.denoise = denoise
                let ref = try restorer.restore(x16)
                references[denoise] = ref
                if writeAudio {
                    try AudioIO.writeWAV([ref], sampleRate: 48_000,
                                         to: clipDir.appending(path: denoise ? "reference-dn1.wav" : "reference.wav"))
                }
            }

            for setting in settings {
                // A fresh engine each time, so the first hop is as cold as when Live switches on.
                let model = try LavaSR(package: ModelPackage(directory: modelDirectory),
                                       intraOpThreads: setting.threads == 0 ? nil : setting.threads)
                let stream = StreamRestorer(model: model, core: setting.coreMs * 16, before: setting.leftMs * 16,
                                            after: setting.rightMs * 16, crossfade: setting.crossfadeMs * 16,
                                            cutoff: onlineCutoff, denoise: setting.denoise)
                var out = [Float]()
                out.reserveCapacity(x16.count * 3)
                var hops = [Double]()
                let clock = ContinuousClock()
                let cpuBefore = cpuSeconds()
                var position = 0
                while position < x16.count {
                    let next = min(position + stream.plan.core, x16.count)
                    let chunk = Array(x16[position..<next])
                    let start = clock.now
                    let y = try stream.push(chunk)
                    let elapsed = clock.now - start
                    if !y
                        .isEmpty {
                        hops.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
                    }
                    out += y
                    position = next
                }
                let cpu = cpuSeconds() - cpuBefore
                out += try stream.finish()
                guard let ref = references[setting.denoise], out.count == ref.count else {
                    fail("\(setting.name): stream produced \(out.count) samples, expected \(x16.count * 3)")
                }

                let sorted = hops.sorted()
                func percentile(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(
                    sorted.count - 1,
                    Int(p * Double(sorted.count))
                )] }
                let result = Result(
                    clip: clip, setting: setting,
                    highBand: Quality.highBand(got: out, ref: ref, above: metricCutoff),
                    seam: Quality.seamRatio(got: out, ref: ref, hop: stream.plan.core * 3, above: metricCutoff),
                    hopP50: percentile(0.5), hopP99: percentile(0.99), hopMax: sorted.last ?? 0,
                    coldFirstHop: hops.first ?? 0,
                    cpuCores: cpu / (Double(x16.count) / 16_000),
                    cutoffOnline: onlineCutoff, cutoffOffline: offlineCutoff, fullBandLevel: fullBandLevel
                )
                results.append(result)
                if writeAudio {
                    try AudioIO.writeWAV([out], sampleRate: 48_000, to: clipDir.appending(path: "\(setting.name).wav"))
                }
                let failed = failures(result)
                print(String(
                    format: "  %-26@ %@  seams %+5.1f dB  hop p50 %5.1f p99 %5.1f ms  %4.1fx  CPU %.2f  total %3.0f ms  %@",
                    setting.name,
                    result.highBand.description,
                    result.seam,
                    result.hopP50,
                    result.hopP99,
                    result.headroom,
                    result.cpuCores,
                    result.totalMs,
                    failed.isEmpty ? "pass" : "fail: " + failed.joined(separator: ", ")
                ))
            }
        }

        try writeCSV(results, to: outDir.appending(path: "results.csv"))
        summarize(results, settings: settings)
        print("Results in \(outDir.path)")
    }

    private static func summarize(_ results: [Result], settings: [Setting]) {
        print("\nSettings that pass on every clip:")
        var any = false
        for setting in settings {
            let rows = results.filter { $0.setting == setting }
            guard rows.allSatisfy({ failures($0).isEmpty }) else { continue }
            any = true
            let worstLSD = rows.map(\.highBand.lsd).max() ?? 0
            let worstSeam = rows.map(\.seam).max() ?? 0
            let worstTotal = rows.map(\.totalMs).max() ?? 0
            print(String(format: "  %-26@ worst LSD %.2f dB, worst seams %+.1f dB, latency ≤ %.0f ms",
                         setting.name, worstLSD, worstSeam, worstTotal))
        }
        if !any { print("  none") }
    }

    private static func writeCSV(_ results: [Result], to url: URL) throws {
        var csv = "clip,setting,core_ms,right_ms,left_ms,crossfade_ms,denoise,threads,total_ms,hb_snr,hb_lsd,seam_db,"
            + "hop_p50_ms,hop_p99_ms,hop_max_ms,headroom,cpu_cores,cold_first_hop_ms,cutoff_online,cutoff_offline,"
            + "fullband_db,pass\n"
        for r in results {
            let s = r.setting
            let fields: [String] = [
                r.clip, s.name, "\(s.coreMs)", "\(s.rightMs)", "\(s.leftMs)", "\(s.crossfadeMs)", s.denoise ? "1" : "0",
                "\(s.threads)", f(r.totalMs), f(r.highBand.snr), f(r.highBand.lsd), f(r.seam), f(r.hopP50), f(r.hopP99),
                f(r.hopMax), f(r.headroom), f(r.cpuCores), f(r.coldFirstHop), f(r.cutoffOnline), f(r.cutoffOffline),
                f(r.fullBandLevel), failures(r).isEmpty ? "1" : "0"
            ]
            csv += fields.joined(separator: ",") + "\n"
        }
        try csv.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func f(_ x: Double) -> String { x.isFinite ? String(format: "%.3f", x) : "" }

    /// "32,64" in milliseconds, checked against the 32 ms frame grid where it matters.
    private static func milliseconds(_ list: String, grid: Bool) -> [Int] {
        list.split(separator: ",").map { item in
            guard let ms = Int(item), ms >= 0 else { fail("not a number of milliseconds: \(item)") }
            if grid, ms % 32 != 0 { fail("\(ms) ms is off the 32 ms frame grid; use a multiple of 32") }
            return ms
        }
    }

    private static func mix(_ channels: [[Float]]) -> [Float] {
        guard channels.count > 1 else { return channels.first ?? [] }
        let scale = 1 / Float(channels.count)
        return (0..<channels[0].count).map { i in channels.reduce(0) { $0 + $1[i] } * scale }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
