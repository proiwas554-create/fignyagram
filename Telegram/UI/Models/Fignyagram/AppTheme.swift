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

    /// System localization only: the .lproj table for the iPhone language is
    /// chosen by iOS. No manual language override can create a mixed UI.
    static func t(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func keyed(_ key: String, ru: String, en: String) -> String {
        let value = t(key)
        if value != key { return value }
        return isEnglish ? en : ru
    }
}
