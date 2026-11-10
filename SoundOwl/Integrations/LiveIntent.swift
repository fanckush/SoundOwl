import AppIntents

/// Switches Live on or off for an app, for Shortcuts, Focus filters and (on macOS 26) a Control
/// Center button made from a shortcut. Turning off without naming an app turns every app off.
struct SetLiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Live On or Off"
    static let description = IntentDescription("Restores the voices in an app, the other people on a call, as you hear them.")
    static let openAppWhenRun = false

    @Parameter(title: "Live", default: true)
    var on: Bool

    @Parameter(title: "App", description: "The app you call with, as its name appears in the menu bar panel.")
    var appName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Turn Live \(\.$on) for \(\.$appName)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.hasReceivedWork = true
        let live = AppModel.shared.live
        live.activate()
        guard let appName, !appName.isEmpty else {
            guard !on else { throw LiveIntentError.noApp }
            live.turnAllOff()
            return .result()
        }
        guard live.set(on, appNamed: appName) else { throw LiveIntentError.unknownApp(appName) }
        return .result()
    }
}

enum LiveIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noApp
    case unknownApp(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noApp: "Choose the app whose voices Live should restore."
        case .unknownApp(let name): "\(name) isn't open. Open it first, or switch it on in SoundOwl's menu."
        }
    }
}
