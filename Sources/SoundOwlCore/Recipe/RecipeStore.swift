import Foundation

/// The app's preferences, wherever SoundOwl runs: inside the app, or as `soundowl` on the command
/// line (`swift run soundowl` has no bundle of its own). Both read and write the app's domain.
public enum SharedDefaults {
    public static let suiteName = "app.soundowl.SoundOwl"

    public static var defaults: UserDefaults {
        // A suite named after your own bundle id doesn't work; inside the app, standard is that domain.
        if Bundle.main.bundleIdentifier == suiteName { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }
}

/// The default recipe, as set in Settings › Restoring.
public enum RecipeStore {
    static let key = "Recipe.default"
    /// Keys from before recipes existed, read once to carry the user's choices over.
    static let legacyFormatKey = "ExportFormat"
    static let legacyDenoiseKey = "DenoiseNewRecordings"

    public static func load(from defaults: UserDefaults = SharedDefaults.defaults) -> Recipe {
        if let data = defaults.data(forKey: key), let recipe = try? JSONDecoder().decode(Recipe.self, from: data) {
            return recipe
        }
        var recipe = Recipe.standard
        if let format = defaults.string(forKey: legacyFormatKey).flatMap(ExportFormat.init(rawValue:)) {
            recipe.format = format
        }
        if defaults.object(forKey: legacyDenoiseKey) != nil {
            recipe.denoise = defaults.bool(forKey: legacyDenoiseKey)
        }
        return recipe
    }

    public static func save(_ recipe: Recipe, to defaults: UserDefaults = SharedDefaults.defaults) {
        guard let data = try? JSONEncoder().encode(recipe) else { return }
        defaults.set(data, forKey: key)
        defaults.removeObject(forKey: legacyFormatKey)
        defaults.removeObject(forKey: legacyDenoiseKey)
    }
}
