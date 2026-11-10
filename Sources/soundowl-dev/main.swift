// Developer harness for the restoration engine. Not part of the app.
//
//   swift run -c release soundowl-dev parity
//   swift run -c release soundowl-dev restore in.m4a out.wav [--denoise] [--cutoff 4000]
//   swift run -c release soundowl-dev bench in.m4a [--denoise]
//   swift run -c release soundowl-dev lookahead clips… [--out dir]   (live feasibility, see Lookahead.swift)
//   swift run -c release soundowl-dev live --pid N | --bundle ID [--seconds 30]   (see Live.swift)
//
// The model package comes from $SOUNDOWL_MODEL_DIR, or tools/model-export/build/lavasr-v2.

import Foundation
import SoundOwlCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
@MainActor func flag(_ name: String) -> Bool {
    guard let i = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: i)
    return true
}
@MainActor func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    let value = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
    return value
}

let modelDirectory = URL(fileURLWithPath: option("--model")
    ?? ProcessInfo.processInfo.environment["SOUNDOWL_MODEL_DIR"]
    ?? "tools/model-export/build/lavasr-v2")
let denoise = flag("--denoise")
let cutoff = option("--cutoff").flatMap(Double.init)

func loadModel() -> LavaSR {
    do {
        return try LavaSR(package: ModelPackage(directory: modelDirectory))
    } catch {
        fail("Could not load the model from \(modelDirectory.path): \(error)\nRun tools/model-export/export.py first.")
    }
}

/// Decodes a file to 16 kHz, one array per channel.
func modelInput(_ url: URL) throws -> (channels: [[Float]], duration: Double) {
    let decoded = try AudioIO.read(url)
    let channels = try decoded.channels.map {
        try AudioIO.resample($0, from: decoded.sampleRate, to: Double(LavaSR.inputSampleRate))
    }
    return (channels, decoded.duration)
}

switch arguments.first {
case "parity":
    let fixtures = URL(fileURLWithPath: option("--fixtures") ?? "Tests/Fixtures/lavasr-v2")
    let model = loadModel()
    let results = try Parity.run(model: model, fixtures: fixtures)
    for r in results { print(r) }
    exit(results.allSatisfy(\.passed) ? 0 : 1)

case "restore":
    guard arguments.count == 3 else { fail("usage: soundowl-dev restore <in> <out.wav> [--denoise] [--cutoff hz]") }
    var restorer = Restorer(model: loadModel())
    restorer.denoise = denoise
    restorer.cutoff = cutoff
    let input = try modelInput(URL(fileURLWithPath: arguments[1]))
    let start = Date()
    let output = try input.channels.map { try restorer.restore($0) }
    let elapsed = Date().timeIntervalSince(start)
    try AudioIO.writeWAV(output, sampleRate: Double(LavaSR.outputSampleRate), to: URL(fileURLWithPath: arguments[2]))
    print(String(format: "%.1f s of audio in %.2f s (%.0fx realtime)", input.duration, elapsed, input.duration / elapsed))

case "bench":
    guard arguments.count == 2 else { fail("usage: soundowl-dev bench <in> [--denoise]") }
    var restorer = Restorer(model: loadModel())
    restorer.denoise = denoise
    let input = try modelInput(URL(fileURLWithPath: arguments[1]))
    let mono = input.channels[0]
    let start = Date()
    _ = try restorer.restore(mono) { p in
        FileHandle.standardError.write(Data(String(format: "\r%3.0f%%", p * 100).utf8))
    }
    let elapsed = Date().timeIntervalSince(start)
    let seconds = Double(mono.count) / Double(LavaSR.inputSampleRate)
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print(String(format: "\r%.0f s of audio in %.1f s: %.0fx realtime, peak memory %.0f MB",
                 seconds, elapsed, seconds / elapsed, Double(usage.ru_maxrss) / 1_048_576))

case "lookahead":
    try Lookahead.run()

case "live":
    try LiveCommand.run()

case "fullband":
    // Whether each file already has the voice's own highs (Live plays those untouched).
    for path in arguments.dropFirst() {
        let decoded = try AudioIO.read(URL(fileURLWithPath: path))
        let mono = decoded.channels.count == 1 ? decoded.channels[0]
            : zip(decoded.channels[0], decoded.channels[1]).map { ($0 + $1) / 2 }
        let content = Quality.highBandContent(mono, sampleRate: decoded.sampleRate)
        let verdict = Quality.hasFullBandContent(mono, sampleRate: decoded.sampleRate) ? "already clear" : "restore"
        print(
            "\(URL(fileURLWithPath: path).lastPathComponent): \(content.map(String.init(describing:)) ?? "no high band") → \(verdict)"
        )
    }

default:
    fail(
        "usage: soundowl-dev parity | restore <in> <out.wav> | bench <in> | lookahead <clips…> | live --pid N  [--denoise] [--cutoff hz] [--model dir]"
    )
}
