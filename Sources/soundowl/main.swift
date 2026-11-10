// `swift run soundowl …` during development. The shipped tool is SoundOwl.app/Contents/Resources/soundowl,
// which runs the same code inside the app's executable.
import SoundOwlCLI

await SoundOwlCLI.run(Array(CommandLine.arguments.dropFirst()))
