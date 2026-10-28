import SwiftUI

/// Centralized visual style. When the "iOS 18 classic" mode is on, every screen,
/// panel and menu uses flat grouped surfaces; toggling animates without flicker.
struct AppThemeModifier: ViewModifier {
    @ObservedObject private var classic = ClassicDesignMode.shared

    func body(content: Content) -> some View {
        content
            .background(
                (classic.isEnabled ? Color(.systemGroupedBackground) : Color(.systemBackground))
                    .ignoresSafeArea()
            )
            .animation(.easeInOut(duration: 0.25), value: classic.isEnabled)
    }
}

extension View {
    /// Applies the classic/new design chrome consistently.
    func appTheme() -> some View { modifier(AppThemeModifier()) }
}

/// Tiny runtime localizer for the newer screens: keeps Russian as the default
/// and switches to English when the system language is English.
nonisolated enum L10n {
    static var isEnglish: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("en") ?? false
    }

    static func string(_ ru: String, _ en: String) -> String {
        isEnglish ? en : ru
    }
}

extension String {
    /// `L("Русский текст", "English text")`
    func localizedPair(_ en: String) -> String {
        L10n.string(self, en)
    }
}

extension L10n {
    static let supported: Set<String> = ["ru", "en", "es", "de", "zh"]

    /// Explicit-locale localization: reads the bundled `.lproj` for the language
    /// selected in AppSettings, so the UI can change language without a restart.
    static func t(_ key: String) -> String {
        let language = MainActor.assumeIsolated { AppSettings.shared.resolvedLanguage }
        if let path = Bundle.main.path(forResource: language, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let value = NSLocalizedString(key, tableName: "Localizable", bundle: bundle,
                                          value: key, comment: "")
            if value != key { return value }
        }
        return NSLocalizedString(key, comment: "")
    }

    /// Backward-compatible helper for call sites with explicit literals.
    static func keyed(_ key: String, ru: String, en: String) -> String {
        let value = t(key)
        if value != key { return value }
        return isEnglish ? en : ru
    }
}
