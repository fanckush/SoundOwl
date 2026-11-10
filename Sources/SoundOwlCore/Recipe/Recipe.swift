import Foundation

/// What "Restore" means: which model, that model's own settings, and the file it writes.
///
/// Every way into SoundOwl (Finder, Shortcuts, the command line, the window) restores with the
/// default recipe unless told otherwise. A model's settings travel with the model, so a recipe
/// can never pair one model with another's options; a second model adds a case with its own
/// settings type.
public struct Recipe: Codable, Sendable, Hashable {
    public enum Model: Codable, Sendable, Hashable {
        case lavaSRv2(LavaSRSettings)
    }

    public var model: Model
    public var format: ExportFormat

    public init(model: Model, format: ExportFormat) {
        self.model = model
        self.format = format
    }

    public static let standard = Recipe(model: .lavaSRv2(LavaSRSettings()), format: .aac)

    public var release: ModelRelease {
        switch model {
        case .lavaSRv2: .lavaSRv2
        }
    }

    /// The denoiser switch, for the one model there is today.
    public var denoise: Bool {
        get {
            switch model {
            case .lavaSRv2(let settings): settings.denoise
            }
        }
        set {
            switch model {
            case .lavaSRv2(var settings):
                settings.denoise = newValue
                model = .lavaSRv2(settings)
            }
        }
    }

    /// This recipe with any of its settings replaced; nil keeps the recipe's own.
    public func overriding(denoise: Bool? = nil, format: ExportFormat? = nil) -> Recipe {
        var recipe = self
        if let denoise { recipe.denoise = denoise }
        if let format { recipe.format = format }
        return recipe
    }
}

public struct LavaSRSettings: Codable, Sendable, Hashable {
    /// Runs the UL-UNAS denoiser before restoring.
    public var denoise: Bool

    public init(denoise: Bool = false) {
        self.denoise = denoise
    }
}
