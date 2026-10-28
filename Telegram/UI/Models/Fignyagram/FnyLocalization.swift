import Combine
import Foundation

/// Centralized string manager, modelled after Swiftgram's `SgLocalization`.
///
/// Every custom screen (macros, cache, quick replies, terminal, performance)
/// resolves its strings through this object. Base values come from the system
/// localizations (`ru.lproj`, `en.lproj`, `es.lproj`, `de.lproj`, `zh.lproj`),
/// so switching the app language in iOS Settings changes the whole UI at once.
/// Optional user overrides are stored separately and never affect iOS' choice of
/// the app language.
@MainActor
final class FnyLocalization: ObservableObject {
    static let shared = FnyLocalization()

    private static let overridesKey = "fnyLocalizationOverrides"

    @Published private(set) var overrides: [String: String] = [:]

    private init() {
        overrides = UserDefaults.standard.dictionary(forKey: Self.overridesKey) as? [String: String] ?? [:]
    }

    /// Resolves a key for the language currently selected by iOS.
    func string(_ key: String) -> String {
        if let override = overrides[key], !override.isEmpty { return override }
        return NSLocalizedString(key, comment: "")
    }

    /// Optional per-key override (used by the terminal for experiments).
    func setOverride(_ value: String?, for key: String) {
        if let value, !value.isEmpty {
            overrides[key] = value
        } else {
            overrides.removeValue(forKey: key)
        }
        UserDefaults.standard.set(overrides, forKey: Self.overridesKey)
        objectWillChange.send()
    }

    /// Debug helper: all keys we ship for the custom screens.
    static let customKeys: [String] = [
        "Settings.BlockScreenshots", "Settings.QuickReplies", "Settings.ProfilesAndPin",
        "Settings.EnterGuestMode", "Settings.MusicTab", "Settings.NewsTab",
        "Settings.AutoTranslate", "Settings.TranslationLanguage", "Settings.GhostStories",
        "Settings.IgnoreCopy", "Settings.Cache.NewsFeed", "Settings.Cache.AutoClear",
        "Settings.Automation.Macros", "Settings.Developer.Terminal", "Settings.Performance.Profile",
        "Settings.ActivateTranslator", "Settings.SendTextAsFile", "Settings.Never",
        "Translation.Mode", "Translation.Mode.Auto", "Translation.Mode.Manual", "Translation.Mode.Disabled"
    ]
}
