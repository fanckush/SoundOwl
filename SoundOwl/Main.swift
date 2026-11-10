import Foundation
import SoundOwlCLI

/// One executable, two faces. `Contents/Resources/soundowl` runs it with `--cli` as the command
/// line tool; anything else starts the app.
@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--cli" {
            Task { await SoundOwlCLI.run(Array(arguments.dropFirst())) }
            dispatchMain()
        }
        SoundOwlApp.main()
    }
}
